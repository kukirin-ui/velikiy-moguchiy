#!/usr/bin/env python3
"""The course-correction loop of the collection: stages of STAGE_HOURS of new clips, each with a cost cap
(collection + its checkpoint), an incremental checkpoint on a cheap GPU and the fixed exams (exams.py).

  checkpoint_loop.py init --budget-usd 3 [--stage-hours 50] [--init-ckpt PATH|base]
  checkpoint_loop.py status
  checkpoint_loop.py train --stage K [--execute]     plan (default) or run it on the trainer pod
  checkpoint_loop.py decide --stage K continue|stop [--note ...]
  checkpoint_loop.py budget --stage K --add-usd N [--note ...]

A checkpoint continues from the best one so far (train_e2e.py --init) for TRAIN_MINUTES on the clips that arrived
since the previous checkpoint plus a channel-balanced replay of older clips, then runs every frozen exam in full.
exams.py record compares it with the previous checkpoint (paired bootstrap per clip) and gives the verdict.
"continue" verdicts are recorded as the stage's decision automatically; "stop collecting" waits for a person.
The trainer pod ("tc", RTX 4090/5090/3090 at <= MAX_PRICE $/h) stays up when the next checkpoint is due within
KEEP_GAP_MIN minutes at the current collection speed, otherwise it is deleted.

harvester/supervisor.py calls tick() every minute: collector pods' $/h go to the stage being collected, the trainer
pod's to the stage it trains; it starts `train --execute` when a stage is complete and holds the collection
(feeder stopped, collector pods stopped after a final backup) when
  - a stage's spend (collection + checkpoint) reaches its budget,
  - a checkpoint's verdict is "stop collecting" and no decision is recorded,
  - a stage is complete while the stage two back has no decision (its checkpoint failed or lags),
  - the last recorded decision is "stop".
The hold stays until `decide` or `budget` clears its reason. Relaunching collector pods is the operator's step (R7).
No model runs on the Mac: it selects clips, ships them and reads the pod's exam results.
State: harvester/stage.json; clip lists: harvester/stages/<K>/.
"""
from __future__ import annotations

import argparse
import contextlib
import fcntl
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
STATE = HERE / "stage.json"
STAGES = HERE / "stages"
QUALITY = HERE / "channel_quality.json"
FEED_STOP = HERE / "MAC_FEEDER_STOP"
HOLD_FILE = HERE / "STAGE_HOLD"
PUBLIC = ROOT / "data" / "public_pod"
EXAMS_DIR = ROOT / "data" / "exams"
STATE_DIR = HERE / "state"
RUNS = ROOT / "results" / "pod_runs"
TRAINER = "tc"
# GPU type -> (VRAM GB, s/step guess for batch 4 x accum 8 until a run measures it); an H100 did 5.2 s/step
GPUS = {"NVIDIA GeForce RTX 4090": (24, 10.0), "NVIDIA GeForce RTX 5090": (32, 8.0),
        "NVIDIA GeForce RTX 3090": (24, 14.0)}
MAX_PRICE = 0.9
MIN_VCPU = 8  # video decoding workers feed the GPU
TRAIN_MINUTES = 20
CLIPS_PER_STEP = 32  # batch 4 x accum 8
NEW_SHARE = 0.7  # of the clips one checkpoint sees; the rest is replay of older clips
DEV_CLIPS = 300  # for train_e2e.py's best.pt choice; never exam clips
MAX_SHARE = 0.25  # R1
POD_HOURS = 2.0  # self-destruct of a fresh trainer pod: setup + smoke + training + full exams with margin
KEEP_GAP_MIN = 40
MAX_ATTEMPTS = 2
CODE = ["train_e2e.py", "train.py", "mvsr.py", "lora.py", "metrics.py", "dataset.py", "split.py", "memguard.py",
        "exams.py", "preprocess.py", "facecrop.py", "multivsr", "harvester/pod/train_stage.sh",
        "harvester/pod/deadline.sh", "harvester/pod/rearm.sh", "harvester/pod/requirements.txt",
        "harvester/video_channels.tsv"]


def log(msg):
    print(time.strftime("%F %T ") + msg, flush=True)


@contextlib.contextmanager
def locked():
    """The supervisor and a running trainer both update the state file."""
    with open(STATE.with_suffix(".lock"), "w") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        yield


def load():
    return json.loads(STATE.read_text()) if STATE.exists() else None


def save(st):
    tmp = STATE.with_suffix(".tmp")
    tmp.write_text(json.dumps(st, ensure_ascii=False, indent=1))
    tmp.replace(STATE)


def clip_hours():
    try:
        return json.loads(QUALITY.read_text())["total_clip_hours"]
    except (OSError, ValueError, KeyError):
        return None


def stage_of(st, hours) -> int:
    return 1 + int(max(0.0, hours - st["hours0"]) // st["stage_hours"])


def stage(st, k: int) -> dict:
    return st["stages"].setdefault(str(k), dict(spent=0.0, budget=st["budget_usd"], decision=None, decisions=[],
                                                train=None, verdict=None))


def training_stage(st):
    for j, s in st["stages"].items():
        if s.get("train") and not s["train"].get("ended"):
            return int(j)
    return None


def accrue(st, collect_rate: float, train_rate: float, hours, now=None):
    """Adds the pods' cost since the last tick: collectors to the stage being collected, the trainer pod to the stage
    it trains (to the current one while it waits for the next checkpoint). Also tracks clip hours per hour."""
    now = now or time.time()
    dt = min(now - st.get("last_tick", now), 3600)
    k = stage_of(st, hours)
    for j, rate in ((k, collect_rate), (training_stage(st) or k, train_rate)):
        s = stage(st, j)
        s["spent"] = round(s["spent"] + rate * dt / 3600, 4)
    prev = st.get("last_hours")
    if prev is not None and dt > 0 and hours >= prev:
        speed = (hours - prev) / (dt / 3600)
        st["clip_hph"] = round(0.9 * st.get("clip_hph", speed) + 0.1 * speed, 3)  # ~10-minute moving average
    st["last_tick"], st["last_hours"] = now, hours


def gate(st, hours):
    """Why the collection must hold now, or None."""
    k = stage_of(st, hours)
    decided = [(int(j), s["decision"]) for j, s in st["stages"].items() if s.get("decision")]
    if decided and max(decided)[1] == "stop":
        return f"stage {max(decided)[0]}: decision 'stop collecting' is recorded"
    for j in sorted({k, training_stage(st) or k}):
        s = stage(st, j)
        if s["spent"] >= s["budget"]:
            return f"stage {j}: budget ${s['budget']:g} spent (${s['spent']:.2f}, collection + checkpoint)"
    for j, s in sorted(st["stages"].items(), key=lambda kv: int(kv[0])):
        if (s.get("verdict") or {}).get("verdict") == "stop collecting" and not s.get("decision"):
            return f"stage {j}: the exams say stop collecting; record a decision"
    for j in range(1, k - 1):
        if not stage(st, j).get("decision"):
            return f"stage {k - 1} is complete but stage {j} has no decision (its checkpoint failed or lags)"
    return None


def pods_rate():
    """($/h of collector pods, $/h of the trainer pod) from the state files of the pods this Mac runs."""
    collect = train = 0.0
    for f in STATE_DIR.glob("*.json"):
        try:
            p = json.loads(f.read_text())
        except ValueError:
            continue
        if "host" in p and time.time() < p.get("deadline", 0) + 600:
            if f.stem == TRAINER:
                train += p.get("rate") or 0
            else:
                collect += p.get("rate") or 0
    return collect, train


def tick(rates, start_train, stop_collection):
    """One supervisor step. rates: pods_rate(). Returns (status line, alerts, holding)."""
    with locked():
        return _tick(rates, start_train, stop_collection)


def _tick(rates, start_train, stop_collection):
    st = load()
    hours = clip_hours()
    if st is None or hours is None:
        return ("loop: not initialised (checkpoint_loop.py init)" if st is None else "loop: no channel_quality.json"
                ), [], False
    alerts = []
    accrue(st, rates[0], rates[1], hours)
    k = stage_of(st, hours)
    if training_stage(st) is None:
        for j in range(1, k):
            t = stage(st, j)["train"]
            if t is None or (t.get("error") and t.get("attempts", 1) < MAX_ATTEMPTS and not stage(st, j)["verdict"]):
                stage(st, j)["train"] = dict(started=time.strftime("%F %T"), attempts=(t or {}).get("attempts", 0) + 1)
                start_train(j)
                alerts.append(f"stage {j} complete ({hours:.0f} h of clips): checkpoint started")
                break
    why = gate(st, hours)
    if why and st.get("hold") != why:
        st["hold"] = why
        HOLD_FILE.write_text(why + "\n")
        stop_collection()
        alerts.append(f"HOLD: {why}. Collection stopped until checkpoint_loop.py decide/budget")
    elif not why and st.get("hold"):
        st["hold"] = None
        HOLD_FILE.unlink(missing_ok=True)
    save(st)
    s = stage(st, k)
    done = hours - st["hours0"] - (k - 1) * st["stage_hours"]
    line = (f"loop: stage {k}, {done:.1f}/{st['stage_hours']:g} h of new clips, ${s['spent']:.2f} of "
            f"${s['budget']:g}" + (f", HOLD: {st['hold']}" if st.get("hold") else ""))
    return line, alerts, bool(st.get("hold"))


def release(st):
    """After a decision: drop the hold if nothing else keeps it, so the supervisor and the feeder may run again."""
    hours = clip_hours()
    why = gate(st, hours) if hours is not None else st.get("hold")
    st["hold"] = why
    save(st)
    if why:
        print(f"still holding: {why}")
        return
    HOLD_FILE.unlink(missing_ok=True)
    FEED_STOP.unlink(missing_ok=True)
    print("hold released: the supervisor restarts the feeder; relaunch collector pods yourself (R7: harvest.py launch)")


# ---------------------------------------------------------------- clip selection
def clip_index():
    """[(stem, channel, mtime, frames, split)] of the collector clips train_e2e.py would read (yt_*.json)."""
    sys.path.insert(0, str(ROOT))
    import exams
    import split
    chans = exams.channel_map()
    out = []
    with os.scandir(PUBLIC) as it:
        for e in it:
            n = e.name
            if not (n.startswith("yt_") and n.endswith(".json")) or n.endswith(".tmp.json"):
                continue
            try:
                meta = json.loads(Path(e.path).read_text())
            except (OSError, ValueError):
                continue
            stem = n[:-5]
            vid = str(meta.get("video_id") or stem.rsplit("__", 1)[0])
            ch = chans.get(vid[3:] if vid.startswith("yt_") else vid)
            key = f"ch:{ch}" if ch else f"yt:{vid}"
            out.append((stem, ch, e.stat().st_mtime, int(meta.get("frames") or 0), split.split_for(key, 3)))
    return out


def balance(clips: list, total: int, max_share: float = MAX_SHARE) -> list:
    """Clips from as many channels as possible, newest first in each: one cap per channel, the largest that keeps
    the sum within total and no channel above max_share of the sum (R1). clips: [(stem, channel, mtime)]."""
    by = {}
    for stem, ch, mt in sorted(clips, key=lambda c: -c[2]):
        by.setdefault(ch, []).append(stem)
    if not by or total <= 0:
        return []
    sizes = [len(v) for v in by.values()]

    def ok(cap):
        got = sum(min(n, cap) for n in sizes)
        return got <= total and min(max(sizes), cap) <= max_share * got

    cap = max(sizes)
    while cap > 0 and not ok(cap):
        cap = min(cap - 1, int(cap * 0.98))
    return [s for v in by.values() for s in v[:cap]]


def select(k: int, since: float, need: int):
    """Clips for checkpoint k: up to NEW_SHARE of `need` from clips newer than `since`, the rest a replay of older
    clips, both balanced by channel and R1 over the union; plus DEV_CLIPS held-out clips for best.pt.
    Writes harvester/stages/<k>/clips.txt; returns (train stems, dev stems, largest channel's clips, channels, new)."""
    banned = set()
    for m in EXAMS_DIR.glob("*/manifest.json"):
        banned |= {r["id"] for r in json.loads(m.read_text())["items"]}
    idx = [c for c in clip_index() if c[0] not in banned and 10 <= c[3] <= 200]
    pool = [(s, ch, mt) for s, ch, mt, _, sp in idx if sp == "train" and ch]
    new = balance([c for c in pool if c[2] > since], int(need * NEW_SHARE))
    old = balance([c for c in pool if c[2] <= since], need - len(new))
    meta = {c[0]: c for c in pool}
    train = balance([meta[s] for s in new + old], len(new) + len(old))
    exam_ch = set()
    hm = EXAMS_DIR / "heldout" / "manifest.json"
    if hm.exists():
        exam_ch = {r["speaker"] for r in json.loads(hm.read_text())["items"]}
    dev_pool = [(s, ch, mt) for s, ch, mt, _, sp in idx if sp == "dev"]
    dev = balance([c for c in dev_pool if c[1] not in exam_ch], DEV_CLIPS, 1.0)
    if len(dev) < DEV_CLIPS:  # not enough held-out channels outside the exam yet: other clips of exam channels
        taken = set(dev)
        dev += balance([c for c in dev_pool if c[0] not in taken], DEV_CLIPS - len(dev), 1.0)
    d = STAGES / str(k)
    d.mkdir(parents=True, exist_ok=True)
    (d / "clips.txt").write_text("".join(f"{s}.{e}\n" for s in train + dev for e in ("mp4", "txt", "json")))
    cnt = {}
    for s in train:
        cnt[meta[s][1]] = cnt.get(meta[s][1], 0) + 1
    n_new = len(set(train) & set(new))
    return train, dev, max(cnt.values(), default=0), len(cnt), n_new


# ---------------------------------------------------------------- the trainer pod
class Pod:
    """The trainer pod over the harvester's RunPod helpers; state in harvester/state/tc.json, kept between
    checkpoints when the next one is near."""

    def __init__(self, name):
        sys.path.insert(0, str(HERE))
        import harvest
        import preflight
        self.h, self.pf, self.name = harvest, preflight, name
        harvest.NAME = name
        self.st = harvest.load_state()
        self.fresh = False

    def attach(self, hours):
        """Reuses a live trainer pod (re-armed for `hours`) or creates one on the cheapest allowed GPU.
        Returns the GPU type; self.since is when this checkpoint starts paying for the pod."""
        h = self.h
        if self.st and "host" in self.st and h.pod_alive(self.st):
            self.since = self.st.get("idle_since") or time.time()
            self.ssh(f"bash /root/lr/harvester/pod/rearm.sh {int(hours * 3600)}")
            self.st["deadline"] = time.time() + hours * 3600
            h.save_state(self.st)
            log(f"{self.name}: reusing pod {self.st['pod_id']} ({self.st['gpu']}, ${self.st['rate']}/h)")
            return self.st["gpu"]
        h.state_file().unlink(missing_ok=True)
        offers = []
        for gpu in GPUS:
            for secure in (True, False):
                try:
                    price = h.gpu_offer(gpu, secure)[0]
                except Exception:  # noqa
                    price = None
                if price is not None and price <= MAX_PRICE:
                    offers.append((price, gpu, secure))
        if not offers:
            raise SystemExit(f"no {'/'.join(GPUS)} offer at <= ${MAX_PRICE}/h right now")
        price, gpu, secure = min(offers)
        self.pf.acquire_lock()
        self.pf.require_budget(hours * price, f"trainer pod {self.name} ({gpu}, {hours} h)")
        body = h.rp.make_body(argparse.Namespace(image=h.rp.IMAGE, gpu=gpu, volume_id=None), time.strftime("%Y%m%d-%H%M%S"),
                              prefix=f"claude-ckpt-{self.name}-")
        body.update(ports=["22/tcp"], containerDiskInGb=150, volumeInGb=20, minVCPUPerGPU=MIN_VCPU)
        if not secure:
            body["cloudType"] = "COMMUNITY"
        body["env"]["PUBLIC_KEY"] = h.rp.pubkey()
        pod = h.create_pod_or_clean_up(body)
        self.since = t0 = time.time()
        self.st = dict(pod_id=pod["id"], created=t0, deadline=t0 + hours * 3600, gpu=gpu,
                       rate=pod.get("costPerHr") or price, role="checkpoint")
        h.save_state(self.st)
        try:
            pod = h.rp.wait_pod(self.st["pod_id"])
            self.st.update(host=pod["publicIp"], port=pod["portMappings"]["22"],
                           rate=pod.get("costPerHr") or self.st["rate"])
            h.save_state(self.st)
            h.rp.wait_ssh(self.st["host"], self.st["port"])
            h.arm_backstop(self.st)
            # push/pull are rsync; a bare image has none until a setup script installs it
            h.remote(self.st, "command -v rsync >/dev/null || (apt-get -qq update && "
                              "DEBIAN_FRONTEND=noninteractive apt-get -qq install -y rsync >/dev/null)")
        except BaseException:
            self.delete()
            raise
        self.fresh = True
        log(f"{self.name}: pod {self.st['pod_id']} up ({gpu}, ${self.st['rate']}/h)")
        return gpu

    def cost(self):
        return round((time.time() - self.since) * (self.st or {}).get("rate", 0) / 3600, 3)

    def ssh(self, cmd, check=True):
        return self.h.remote(self.st, cmd, check=check)

    def _e(self):
        import shlex
        return "ssh " + " ".join(shlex.quote(x) for x in self.h.ssh_opts(self.st["port"]))

    def push(self, src, dst, files_from=None, only=None):
        extra = ["--files-from", str(files_from)] if files_from else []
        extra += ["--include", only, "--exclude", "*"] if only else []
        subprocess.run(["rsync", "-a", "--timeout=300", "-e", self._e()] + extra +
                       [str(src), f"root@{self.st['host']}:{dst}"], check=True)

    def pull(self, src, dst):
        Path(dst).mkdir(parents=True, exist_ok=True)
        subprocess.run(["rsync", "-a", "--timeout=300", "-e", self._e(), f"root@{self.st['host']}:{src}", str(dst)])

    def keep(self, minutes):
        """Stay up for the next checkpoint; the pod's own timer still deletes it if that never comes."""
        self.ssh(f"bash /root/lr/harvester/pod/rearm.sh {int(minutes * 60)}", check=False)
        self.st.update(deadline=time.time() + minutes * 60, idle_since=time.time())
        self.h.save_state(self.st)

    def delete(self, tries=3, wait=10):
        """The state file goes only once RunPod confirms the pod is gone; otherwise it stays, and harvester/reaper.py
        deletes the pod after its deadline."""
        if self.st:
            for i in range(tries):
                try:
                    self.h.rp.req("DELETE", "/pods/" + self.st["pod_id"])
                    break
                except (Exception, SystemExit) as e:
                    log(f"{self.name}: delete {i + 1}/{tries}: {e}")
                    if self.gone():
                        break
                    time.sleep(wait * (i + 1))
            else:
                log(f"{self.name}: pod {self.st['pod_id']} not deleted; its state file stays for harvester/reaper.py")
                return
        self.h.state_file().unlink(missing_ok=True)
        self.st = None

    def gone(self):
        try:
            p = self.h.rp.req("GET", "/pods/" + self.st["pod_id"])
        except SystemExit as e:  # rp.req exits with the HTTP status on an error
            return "-> 404" in str(e)
        except Exception:  # noqa
            return False
        return (p or {}).get("desiredStatus") == "TERMINATED"


def steps_for(st, gpu):
    sps = st.get("sec_per_step", {}).get(gpu) or GPUS.get(gpu, (24, 14.0))[1]
    return max(20, int(TRAIN_MINUTES * 60 / sps)), sps


def plan(st, k, hours):
    return dict(stage=k, run=f"stage{k}", init=st.get("best") or "base", minutes=TRAIN_MINUTES,
                baseline=not exams_module().LEDGER_JSONL.exists(), clip_hours=hours, since=st.get("last_selected")
                or st.get("created_ts", 0))


def train(k, execute=False, pod_factory=Pod, poll=60):
    st = load()
    if st is None:
        raise SystemExit("checkpoint_loop.py init first")
    p = plan(st, k, clip_hours())
    gpu = min(GPUS, key=lambda g: GPUS[g][1])
    steps, sps = steps_for(st, gpu)
    sel_at = time.time()
    tr, dev, cap, n_ch, n_new = select(k, p["since"], steps * CLIPS_PER_STEP)
    lst = STAGES / str(k) / "clips.txt"
    if n_ch < 5 or len(dev) < 10:  # train_e2e.py would refuse on the pod (R1, dev split) after the pod is paid for
        raise SystemExit(f"stage {k}: {n_ch} channels, {len(dev)} held-out dev clips; train_e2e.py needs >= 5 channels "
                         f"and >= 10 dev clips")
    print(f"stage {k}: {len(tr)} train clips ({n_new} new, {len(tr) - n_new} replay; <= {cap} per channel, "
          f"{n_ch} channels), {len(dev)} dev clips -> {lst}\n"
          f"trainer pod {TRAINER} (RTX 4090/5090/3090 <= ${MAX_PRICE}/h): {TRAIN_MINUTES} min from {p['init']} "
          f"(~{steps} steps at {sps:g} s/step), smoke run only when the pod has none (R4), then all exams"
          f"{' (also of the start checkpoint)' if p['baseline'] else ''}")
    if not execute:
        return p
    with locked():
        st = load()
        s = stage(st, k)
        old = {x: v for x, v in (s.get("train") or {}).items() if x not in ("ended", "error", "cost")}
        s["train"] = dict(old, started=time.strftime("%F %T"), plan=p)
        save(st)
    out = RUNS / TRAINER
    try:
        ok, cost, gpu, measured = run_pod(p, cap, lst, out, pod_factory, poll, st)
    except BaseException as e:
        ok, cost, gpu, measured = f"{type(e).__name__}: {e}", None, None, None
    with locked():
        st = load()
        s = stage(st, k)
        s["train"].update(ended=time.strftime("%F %T"), cost=cost, gpu=gpu)
        if measured:
            st.setdefault("sec_per_step", {})[gpu] = measured
        if ok is not True:
            s["train"]["error"] = f"{ok}; pod log {out / 'stage.log'}"
            save(st)
            raise SystemExit(f"stage {k} checkpoint failed: {s['train']['error']}")
        st["last_selected"] = sel_at
        d = record(st, k, p, out, cost)
        save(st)
    return d


def run_pod(p, cap, lst, out, pod_factory, poll, st):
    """(True | error, this checkpoint's pod cost, GPU, measured s/step). The pod is kept for the next checkpoint
    when it is near, deleted otherwise and on any failure."""
    pod = pod_factory(TRAINER)
    keep = False
    try:
        gpu = pod.attach(POD_HOURS)
        steps, _ = steps_for(st, gpu)
        vram = GPUS.get(gpu, (24, 0))[0]
        chunk = 2 if vram < 32 else 4  # 50-frame pieces per VTP call: 8 needs ~45 GB
        pod.ssh("mkdir -p /root/lr/data/pool /root/lr/data/exams /root/lr/results/exams /root/lr/checkpoints/init "
                "/root/lr/harvester/pod /root/lr/lists && rm -f /root/lr/STAGE_DONE /root/lr/STAGE_FAILED")
        for c in CODE:
            pod.push(ROOT / c, "/root/lr/" + str(Path(c).parent) + "/")
        pod.push(str(PUBLIC) + "/", "/root/lr/data/pool/", files_from=lst)  # rsync skips clips the pod already has
        pod.push(lst, f"/root/lr/lists/{p['run']}.txt")
        pod.push(str(EXAMS_DIR) + "/", "/root/lr/data/exams/")
        pod.push(str(ROOT / "clips") + "/", "/root/lr/clips/", only="*.txt")
        init = "base"
        if p["init"] != "base":
            ck = ROOT / p["init"]
            pod.push(ck, f"/root/lr/checkpoints/init/{p['run']}.pt")
            init = f"checkpoints/init/{p['run']}.pt"
        pod.ssh(f"cd /root/lr || exit 1; setsid nohup bash harvester/pod/train_stage.sh {int(POD_HOURS * 3600)} {p['run']} "
                f"{init} {steps} {p['minutes']} {int(p['baseline'])} {cap} {chunk} lists/{p['run']}.txt "
                f"> /root/lr/stage.log 2>&1 < /dev/null &")
        end, lost = time.time() + POD_HOURS * 3600, 0
        while True:
            time.sleep(poll)
            r = pod.ssh("cd /root/lr && ls STAGE_DONE STAGE_FAILED 2>/dev/null; tail -2 stage.log", check=False)
            if "STAGE_FAILED" in r.stdout or "STAGE_DONE" in r.stdout:
                break
            lost = lost + 1 if r.returncode == 255 else 0
            if lost >= 10 or time.time() > end:
                return ("the pod stopped answering" if lost >= 10 else f"no result within {POD_HOURS} h"), \
                    pod.cost(), gpu, None
        pod.pull("/root/lr/results/exams/", out / "results" / "exams")
        pod.pull(f"/root/lr/checkpoints/{p['run']}/", out / "checkpoints" / p["run"])
        pod.pull(f"/root/lr/logs/{p['run']}.log", out / "logs")
        pod.pull("/root/lr/stage.log", out)
        measured = None
        lg = out / "logs" / f"{p['run']}.log"
        if lg.exists():
            m = re.findall(r"([\d.]+) s/step", lg.read_text(errors="replace"))
            measured = float(m[-1]) if m else None
        ok = True if "STAGE_DONE" in r.stdout else "the pod reported STAGE_FAILED"
        cost = pod.cost()
        keep = ok is True and next_checkpoint_min() <= KEEP_GAP_MIN
        if keep:
            pod.keep(KEEP_GAP_MIN + 20)
            log(f"{TRAINER}: kept for the next checkpoint (due in ~{next_checkpoint_min():.0f} min)")
        return ok, cost, gpu, measured
    finally:
        if not keep:
            pod.delete()


def next_checkpoint_min():
    """Minutes until the next stage completes at the current collection speed (inf when unknown)."""
    st, hours = load(), clip_hours()
    if not st or hours is None or not st.get("clip_hph"):
        return float("inf")
    left = st["hours0"] + stage_of(st, hours) * st["stage_hours"] - hours
    return 60 * left / st["clip_hph"]


def exams_module():
    sys.path.insert(0, str(ROOT))
    import exams
    return exams


def record(st, k, p, out, cost):
    exams = exams_module()
    res = out / "results" / "exams"
    if p["baseline"]:
        exams.cmd_record(argparse.Namespace(result=str(res / f"{p['run']}_start.json"), label=f"start ({p['init']})",
                                            stage=0, clip_hours=st["hours0"], ckpt_cost=None, stage_cost=None))
    s = stage(st, k)
    d = exams.cmd_record(argparse.Namespace(result=str(res / f"{p['run']}.json"), label=p["run"], stage=k,
                                            clip_hours=p["clip_hours"], ckpt_cost=cost, stage_cost=s["spent"]))
    s["verdict"] = d
    if d["verdict"].startswith("continue"):
        s["decision"] = "continue"
        s["decisions"].append(dict(time=time.strftime("%F %T"), decision="continue", note=f"auto: {d['verdict']}"))
    best = out / "checkpoints" / p["run"] / "best.pt"
    if d.get("best") and best.exists():
        st["best"] = str(best.relative_to(ROOT)) if ROOT in best.parents else str(best)
    print(f"stage {k} checkpoint: {d['verdict']}" + "".join(f"; {f}" for f in d["flags"]))
    if not s.get("decision"):
        print(f"the collection holds until: harvester/checkpoint_loop.py decide --stage {k} stop|continue --note '...'")
    return d


# ---------------------------------------------------------------- CLI
def cmd_init(a):
    if STATE.exists():
        raise SystemExit(f"{STATE} exists; the loop is already running")
    hours = clip_hours()
    if hours is None:
        raise SystemExit("no harvester/channel_quality.json: run harvester/channel_quality.py first")
    save(dict(hours0=hours, stage_hours=a.stage_hours, budget_usd=a.budget_usd, best=None if a.init_ckpt == "base"
              else a.init_ckpt, stages={}, hold=None, created=time.strftime("%F %T"), created_ts=time.time()))
    print(f"loop started at {hours} h of clips; stages of {a.stage_hours:g} h, ${a.budget_usd:g} each "
          f"(collection + checkpoint)")


def cmd_status(_a):
    st = load()
    if st is None:
        raise SystemExit("not initialised")
    hours = clip_hours()
    print(f"clips {hours} h, loop started at {st['hours0']} h, stage {stage_of(st, hours)}, "
          f"{st.get('clip_hph', '?')} h of clips per hour, best {st.get('best') or 'base'}")
    for j, s in sorted(st["stages"].items(), key=lambda kv: int(kv[0])):
        t = s.get("train") or {}
        print(f"  stage {j}: ${s['spent']:.2f}/${s['budget']:g}, checkpoint "
              f"{'-' if not t else 'running' if not t.get('ended') else 'failed' if t.get('error') else 'done'}"
              f"{' $' + str(t['cost']) if t.get('cost') is not None else ''}, verdict "
              f"{(s.get('verdict') or {}).get('verdict')}, decision {s.get('decision')}")
    print(f"hold: {st.get('hold')}")


def cmd_decide(a):
    with locked():
        st = load()
        s = stage(st, a.stage)
        if not s.get("verdict"):
            print(f"note: stage {a.stage} has no exam verdict yet")
        s["decision"] = a.decision
        s["decisions"].append(dict(time=time.strftime("%F %T"), decision=a.decision, note=a.note))
        release(st)


def cmd_budget(a):
    with locked():
        st = load()
        s = stage(st, a.stage)
        s["budget"] = round(s["budget"] + a.add_usd, 2)
        s["decisions"].append(dict(time=time.strftime("%F %T"), budget_add=a.add_usd, note=a.note))
        release(st)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    i = sub.add_parser("init")
    i.add_argument("--budget-usd", type=float, required=True, help="cost cap per stage: collection + its checkpoint")
    i.add_argument("--stage-hours", type=float, default=50)
    i.add_argument("--init-ckpt", default="results/pod_runs/t1/checkpoints/e2e_full/best.pt",
                   help="train_e2e.py best.pt the first checkpoint starts from (path from the repo root), or base")
    sub.add_parser("status")
    t = sub.add_parser("train")
    t.add_argument("--stage", type=int, required=True)
    t.add_argument("--execute", action="store_true", help="use the trainer pod (costs money); without it only the plan")
    d = sub.add_parser("decide")
    d.add_argument("--stage", type=int, required=True)
    d.add_argument("decision", choices=["continue", "stop"])
    d.add_argument("--note", default="")
    b = sub.add_parser("budget")
    b.add_argument("--stage", type=int, required=True)
    b.add_argument("--add-usd", type=float, required=True)
    b.add_argument("--note", default="")
    a = ap.parse_args()
    if a.cmd == "train":
        return train(a.stage, a.execute)
    dict(init=cmd_init, status=cmd_status, decide=cmd_decide, budget=cmd_budget)[a.cmd](a)


if __name__ == "__main__":
    main()
