#!/usr/bin/env python3
"""Keeps the Mac -> pods pipeline running and says where it stalls.

  nohup caffeinate -i python3 harvester/supervisor.py >> harvester/supervisor.log 2>&1 &

Every minute it checks each link (Mac feeder, the backup watcher of every pod, and on every pod the collector,
the feature workers and the inbox), restarts whatever has died, and rewrites harvester/supervisor_status.txt.
Every QUALITY_EVERY seconds it rebuilds harvester/channel_quality.json from the pulled collector output and prunes
channels (channel_quality.py), then runs one step of the course-correction loop (checkpoint_loop.py: stage budget,
checkpoint training every stage, hold until a decision). While the loop holds, nothing is restarted.
Actions and alerts go to the log. Stop: touch harvester/SUPERVISOR_STOP; pause: touch harvester/SUPERVISOR_PAUSE.
"""
import json
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
STATUS = HERE / "supervisor_status.txt"
STOP = HERE / "SUPERVISOR_STOP"
PAUSE = HERE / "SUPERVISOR_PAUSE"
FEED_LOG = HERE / "mac_feeder.log"
FEED_STOP = HERE / "MAC_FEEDER_STOP"
EVERY = 60
# shard of the manual queue each pod owns (newdata/start.sh)
SHARDS = {"p1": "0/5", "p2": "1/5", "p3": "2/5", "p5": "3/5", "p6": "4/5", "p7": "4/5"}
GPU_SERVERS = 3
# the pilot: the MuAViC exam sections first, then 9 videos from each of 6 deep talking-head channels (the narrow arm
# of pilot_train.py needs 5 channels with many clips), then the channel queue. Left out: VoxCeleb2 (VoxLingua107 takes
# short Russian clips for Belarusian or Polish, so every section was rejected), MuAViC train (the exam's TEDx domain),
# MultiVSR (the base model was trained on it, RULES.md error 3).
FEED_CMD = ("harvester/mac_feeder.py --forward --parallel 3 --max-parallel 6 --max-total 24 --follow --scout "
            "--first data/ext/first_queue.txt --queue newdata/queue_diverse.txt")
FEED_SILENT_MIN = 10
FEATURE_LAG_ALERT = 300
# frozen-VTP features (.npy) only serve train.py; train_e2e.py and the pilot read the mp4s, and the workers took
# 5-10 of a collector's 31 cores, which the collector is short of
FEATURES = False
MIN_MAC_FREE_GB = 15
CLIP_SEC = 6.5  # mean clip length in the collector logs, for the hours-per-hour estimate

QUALITY_EVERY = 300
SEG_RESTART_EVERY = 900

sys.path.insert(0, str(HERE))
import channel_quality  # noqa: E402
import checkpoint_loop  # noqa: E402
import deploy_collector  # noqa: E402
import reaper  # noqa: E402
import harvest  # noqa: E402

# the brackets keep pgrep from matching the shell that runs this very probe
PROBE = r"""cd /root/newdata
P=/root/lr/data/public
echo collector=$(pgrep -fc '[r]v_collect.py run')
echo ready=$(grep -c SETUP_OK /root/newdata/logs/setup.log 2>/dev/null)
echo features=$(pgrep -fc '[f]eature_worker.py')
echo gpu_hog=$(pgrep -fc '[e]valuate.py|[t]rain.py|[d]ataset.py' )
echo inbox=$(ls inbox | grep -c 'mp4$')
echo seg_inbox=$(ls inbox_seg 2>/dev/null | grep -c 'mp4$')
echo segments=$(pgrep -fc '[p]od_segments.py')
echo ext_clips=$(find /root/lr/data/ext -mindepth 3 -maxdepth 3 -name 'yt_*.json' 2>/dev/null | wc -l)
echo work=$(ls inbox/.work 2>/dev/null | grep -c 'mp4$')
echo clips=$(ls $P | grep -cE '^(yt|rt|vk)_.*json$')
echo npy=$(ls $P | grep -cE '^(yt|rt|vk)_.*npy$')
echo new5=$(find $P -maxdepth 1 -name '*_*.json' -newermt '-5 minutes' | grep -cE '/(yt|rt|vk)_')
echo gpu=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits)
echo disk=$(df -BG --output=avail /root | tail -1 | tr -dc 0-9)
"""
START_FEATURES = ("cd /root/lr && for k in 1 2; do setsid nohup python3 fetch/feature_worker.py --min-free 0 "
                  "--shard $k/2 >> fetch/features.out 2>&1 < /dev/null & done")


def log(msg):
    print(time.strftime("%F %T ") + msg, flush=True)


def mac_procs():
    """Command lines of the interpreters and caffeinate wrappers only: a shell whose command text merely mentions
    mac_feeder.py (an agent's grep, a commit message) must not pass for a running feeder."""
    out = subprocess.run(["ps", "-axo", "args"], capture_output=True, text=True).stdout
    return "\n".join(l for l in out.splitlines()
                     if l.split() and Path(l.split()[0]).name.lower().startswith(("python", "caffeinate")))


def live_pods():
    out = {}
    for f in sorted((HERE / "state").glob("p*.json")):
        st = json.loads(f.read_text())
        if "host" in st and time.time() < st["deadline"]:
            out[f.stem] = st
    return out


def probe(st):
    try:
        r = harvest.remote(st, PROBE, check=False)
    except Exception as e:  # noqa
        return {"error": str(e)[:80]}
    d = {}
    for line in r.stdout.splitlines():
        k, _, v = line.partition("=")
        d[k] = int(v) if v.strip().isdigit() else v.strip()
    return d if d else {"error": (r.stderr or "no answer")[-80:]}


def start_mac(cmd, log_file):
    subprocess.Popen(f"nohup caffeinate -i python3 {cmd} >> {log_file} 2>&1 < /dev/null &", shell=True, cwd=ROOT)


def feeder_minutes_silent():
    try:
        lines = FEED_LOG.read_text().splitlines()[-400:]
    except OSError:
        return None
    for line in reversed(lines):
        if " MB -> " in line:
            t = time.mktime(time.strptime(line[:19], "%Y-%m-%d %H:%M:%S"))
            return (time.time() - t) / 60
    return None


def stop_collection():
    """Loop hold: the feeder stops, every collector pod gets a graceful stop with a final backup."""
    FEED_STOP.touch()
    for name in live_pods():
        start_mac(f"harvester/harvest.py --name {name} stop", f"harvester/harvest-{name}.log")


def start_train(k):
    start_mac(f"harvester/checkpoint_loop.py train --stage {k} --execute", f"harvester/train-stage{k}.log")


def loop_step(state, alerts):
    """channel_quality every QUALITY_EVERY s, then the loop; returns (status line, holding)."""
    if time.time() - state.get("quality_at", 0) >= QUALITY_EVERY:
        state["quality_at"] = time.time()
        try:
            alerts += channel_quality.update()
        except Exception as e:  # noqa
            alerts.append(f"channel_quality failed: {type(e).__name__}: {e}")
        missing = [x for x in ("muavic", "heldout") if not (ROOT / "data" / "exams" / x / "manifest.json").exists()]
        if missing:  # these exams wait for clips the pods cut; freezing is a copy, no model runs
            r = subprocess.run([str(ROOT / ".venv" / "bin" / "python"), "exams.py", "freeze", "--only",
                                ",".join(missing)], cwd=ROOT, capture_output=True, text=True)
            alerts += [f"exam {x.strip()}" for x in r.stdout.splitlines() if " frozen " in x or "Error" in x]
    try:
        line, more, holding = checkpoint_loop.tick(checkpoint_loop.pods_rate(), start_train, stop_collection)
    except Exception as e:  # noqa
        return f"loop: tick failed: {type(e).__name__}: {e}", False
    alerts += more
    return line, holding


def tick(prev):
    ps = mac_procs()
    pods = live_pods()
    rows, alerts = [], []
    try:
        alerts += reaper.sweep()
    except (Exception, SystemExit) as e:  # noqa  rp.req turns HTTP errors into SystemExit
        alerts.append(f"reaper failed: {type(e).__name__}: {str(e)[:120]}")
    # past its deadline a pod still waits for the final backup: keep its watcher, but restart nothing on it
    for f in sorted((HERE / "state").glob("p*.json")):
        st = json.loads(f.read_text())
        if f.stem not in pods and "host" in st and time.time() < st["deadline"] + reaper.GRACE_S \
                and f"--name {f.stem} " not in ps:
            start_mac(f"harvester/harvest.py --name {f.stem} watch --every 300", f"harvester/harvest-{f.stem}.log")
            alerts.append(f"{f.stem}: past its deadline, watcher restarted for the final backup")
    loop_line, holding = loop_step(prev.setdefault("_loop", {}), alerts)
    if holding:
        STATUS.write_text("\n".join([time.strftime("%F %T"), loop_line, "nothing is restarted while the loop holds",
                                     ""] + [f"! {a}" for a in alerts]) + "\n")
        for a in alerts:
            log(a)
        return prev

    if FEED_STOP.exists():
        alerts.append("harvester/MAC_FEEDER_STOP exists without a loop hold: the feeder ships nothing until it is "
                      "removed")
    if "mac_feeder.py" not in ps:
        start_mac(FEED_CMD, "harvester/mac_feeder.log")
        alerts.append("Mac feeder was dead: restarted")
    silent = feeder_minutes_silent()
    if silent is not None and silent > FEED_SILENT_MIN:
        alerts.append(f"Mac feeder shipped nothing for {silent:.0f} min: accounts blocked or queue empty")

    for name in pods:
        if f"--name {name} " not in ps:
            start_mac(f"harvester/harvest.py --name {name} watch --every 300", f"harvester/harvest-{name}.log")
            alerts.append(f"{name}: backup watcher was dead: restarted")

    with ThreadPoolExecutor(8) as ex:
        res = dict(zip(pods, ex.map(probe, pods.values())))

    for name, d in res.items():
        st = pods[name]
        if "error" in d:
            rows.append(f"{name}  unreachable: {d['error']}")
            alerts.append(f"{name}: ssh failed")
            continue
        if d.get("collector", 0) == 0 and d.get("ready", 0):
            harvest.remote(st, f"cd /root/newdata && pkill -f '[g]pu_server.py'; GPUN={GPU_SERVERS} INBOX_ONLY=1 RT=0 "
                               f"./restart.sh 26 {SHARDS.get(name, '4/5')} "
                               "> /dev/null 2>&1 < /dev/null &", check=False)
            alerts.append(f"{name}: collector was dead: restarted")
        seg_at = prev.setdefault("_seg_restart", {})
        if d.get("segments", 0) == 0 and d.get("ready", 0) and d.get("collector", 0) \
                and time.time() - seg_at.get(name, 0) > SEG_RESTART_EVERY:
            seg_at[name] = time.time()  # a failing install must not re-upload the lists every minute
            try:
                alerts.append(f"{name}: dataset segment cutter was dead: "
                              f"{deploy_collector.start_segments(st, GPU_SERVERS)}")
            except Exception as e:  # noqa
                alerts.append(f"{name}: dataset segment cutter restart failed: {type(e).__name__}: {str(e)[:100]}")
        if FEATURES and d.get("features", 0) == 0:
            harvest.remote(st, START_FEATURES, check=False)
            alerts.append(f"{name}: feature workers were dead: started 2")
        lag = d.get("clips", 0) - d.get("npy", 0)
        if FEATURES and lag > FEATURE_LAG_ALERT:
            why = " (a GPU job is holding the feature workers)" if d.get("gpu_hog") else ""
            alerts.append(f"{name}: {lag} new clips without features{why}")
        p = prev.get(name, {})
        npy_rate = (d.get("npy", 0) - p.get("npy", d.get("npy", 0))) * 60 / EVERY
        left_min = (st["deadline"] - time.time()) / 60
        rows.append(f"{name}  inbox {d.get('inbox', '?'):>3}  in work {d.get('work', '?'):>2}/26  "
                    f"clips +{d.get('new5', 0):>3}/5min  total {d.get('clips', 0):>5}  "
                    f"datasets: inbox {d.get('seg_inbox', '?')} clips {d.get('ext_clips', '?')}  "
                    f"no features {lag:>4} (+{npy_rate:.0f}/min)  gpu {d.get('gpu', '?')}%  "
                    f"disk {d.get('disk', '?')} GB  ends in {left_min:.0f} min")
        if d.get("inbox", 0) == 0 and d.get("work", 0) < 13:
            alerts.append(f"{name}: starving, {d.get('work')} of 26 workers busy")

    free_gb = __import__("shutil").disk_usage(ROOT).free / 1e9
    if free_gb < MIN_MAC_FREE_GB:
        alerts.append(f"Mac disk: only {free_gb:.0f} GB free, backups will stop when it fills")
    clips5 = sum(d.get("new5", 0) for d in res.values() if "error" not in d)
    head = [time.strftime("%F %T"),
            f"feeder: {'last ship ' + format(silent, '.0f') + ' min ago' if silent is not None else 'no ships yet'}",
            f"all pods: {clips5} clips in 5 min (~{clips5 * 12 * CLIP_SEC / 3600:.1f} h of data per hour)", loop_line, ""]
    STATUS.write_text("\n".join(head + rows + [""] + [f"! {a}" for a in alerts]) + "\n")
    for a in alerts:
        log(a)
    return dict({n: d for n, d in res.items() if "error" not in d}, _loop=prev["_loop"],
                _seg_restart=prev.get("_seg_restart", {}))


def main():
    STOP.unlink(missing_ok=True)
    log("supervisor started")
    prev = {}
    while not STOP.exists():
        if PAUSE.exists():  # a manual rollout keeps the collector down for a few seconds; don't race it
            time.sleep(10)
            continue
        try:
            prev = tick(prev)
        except (Exception, SystemExit) as e:  # noqa  rp.req turns HTTP errors into SystemExit
            log(f"tick failed: {type(e).__name__}: {e}")
        time.sleep(EVERY)
    log("supervisor stopped")


if __name__ == "__main__":
    main()
