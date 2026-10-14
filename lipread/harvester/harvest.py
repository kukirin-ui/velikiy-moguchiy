#!/usr/bin/env python3
"""Lip-reading data harvester on a RunPod GPU pod, with continuous backups to this Mac.

  harvest.py pack [--max-clips-per-video 30]
                                        build dist/harvester.tar.gz (code + pod selection, no cookies, no weights)
  harvest.py launch [--max-hours 8] [--workers 48] [--crop 24] [--gpu ...] [--spot] [--account NAME] [--dry-run]
                                        create the pod, upload the bundle and cookies, start it, then watch
  harvest.py watch                      (re)attach: backup every --every seconds until the pod is gone
  harvest.py pull                       one backup + merge now
  harvest.py status                     pod heartbeat and local totals
  harvest.py stop                       graceful stop, final backup, wipe cookies, terminate the pod
  harvest.py accounts                   the account pool (name, profile, pod, burned), never any cookie contents

The pod walks the Mac's selection from the end while the Mac walks it from the start, so the two never
download the same video until they meet. Backups land in data/public_pod/ (mirror of the pod); finished clips
(.json + .npy) are hard-linked into data/public/, where training and the Mac fetcher see them.
The pod terminates itself at the deadline even if this Mac is asleep (pod/deadline.sh).
A --spot pod is interruptible: if it vanishes before the deadline the watcher pulls what it can and relaunches it
(same name, part, account, bundle; at most 3 times per hour, never past the deadline).
Pool accounts with a "profile" get their cookies exported from the zgnspaces antidetect browser when picked.
"""
import argparse
import contextlib
import importlib.util
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tarfile
import time
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))
import preflight  # noqa: E402
DIST = HERE / "dist"
# one bundle and one state file per pod, so several pods can share the work
NAME = "a"
PART = (0, 1)
REVERSE = False


def bundle():
    return DIST / f"harvester-{NAME}.tar.gz"


def state_file():
    return HERE / "state" / f"{NAME}.json"
LOG = HERE / "harvest.log"
PUB = ROOT / "data" / "public"
MIRROR = ROOT / "data" / "public_pod"
COOKIES = ROOT / "fetch" / "cookies.txt"
REMOTE = "/root/lr"  # local disk: the /workspace network volume stalls dozens of parallel ffmpeg readers
MAC_MIN_FREE_GB = 15
EXT = ROOT / "data" / "ext"
EXT_TRAIN_SPLITS = ("train", "train_major", "dev")  # valid/test/val_major are exams and held-out speakers

BUNDLE_PATHS = ["fetch/run.py", "fetch/asr_service.py", "newdata/textnorm.py", "fetch/feature_worker.py", "mvsr.py", "memguard.py", "facecrop.py", "multivsr",
                "harvester/pod"]
BUNDLE_SKIP = {"__pycache__", "samples", ".git"}

_spec = importlib.util.spec_from_file_location("rp", os.path.expanduser("~/.claude/runpod/rp.py"))
rp = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(rp)


def ssh_opts(port):
    # a vanished spot pod must not hang the watcher in connect()
    return rp.ssh_opts(port) + ["-o", "ConnectTimeout=20"]


def log(msg):
    line = time.strftime("%F %T ") + msg
    print(line, flush=True)
    with open(LOG, "a") as f:
        f.write(line + "\n")


def gpu_offer(gpu, secure=True):
    """(on-demand $/h, min vCPU, spot $/h) RunPod quotes for one GPU of this type.
    The spot price is lowestPrice.minimumBidPrice, None when there is no spot capacity right now."""
    q = ('{ gpuTypes(input: {id: "%s"}) { lowestPrice(input: {gpuCount: 1, secureCloud: %s}) '
         '{ uninterruptablePrice minVcpu minimumBidPrice } } }') % (gpu, "true" if secure else "false")
    r = urllib.request.Request("https://api.runpod.io/graphql", data=json.dumps({"query": q}).encode(), headers={
        "Authorization": "Bearer " + rp.api_key(), "Content-Type": "application/json", "User-Agent": "rp-cli/1.0"})
    with urllib.request.urlopen(r, timeout=30) as resp:
        lp = json.load(resp)["data"]["gpuTypes"][0]["lowestPrice"]
    return lp["uninterruptablePrice"], lp["minVcpu"], lp.get("minimumBidPrice")


def balance():
    """RunPod balance and total spend per hour, or (None, None) if the API does not answer."""
    q = "{ myself { clientBalance currentSpendPerHr } }"
    r = urllib.request.Request("https://api.runpod.io/graphql", data=json.dumps({"query": q}).encode(), headers={
        "Authorization": "Bearer " + rp.api_key(), "Content-Type": "application/json", "User-Agent": "rp-cli/1.0"})
    try:
        with urllib.request.urlopen(r, timeout=30) as resp:
            me = json.load(resp)["data"]["myself"]
        return me["clientBalance"], me["currentSpendPerHr"]
    except Exception:
        return None, None


def load_state():
    return json.loads(state_file().read_text()) if state_file().exists() else None


def save_state(st):
    state_file().parent.mkdir(exist_ok=True)
    state_file().write_text(json.dumps(st, indent=1))


# ---------------------------------------------------------------- pack
def done_ids():
    return {p.stem for p in PUB.glob("*.json") if not p.name.endswith(".tmp.json")}


def eligible_clips():
    """Same filter as fetch/extend_selection.py, but every clip of a video, not 60: a download costs the same."""
    rows = [json.loads(line) for line in open(ROOT / "data" / "public_meta" / "ru.jsonl")]
    est = {}
    for r in rows:
        est[r["video_id"]] = max(est.get(r["video_id"], 0), (r["track_frame0"] + r["track_n"]) / 25)
    byv = {}
    for r in rows:
        if r["split"] == "train_major" and est[r["video_id"]] <= 3600 and 50 <= r["length"] <= 250 \
                and len(r["transcript"].split()) >= 3:
            byv.setdefault(r["video_id"], []).append(r)
    return byv


def spread(clips, n):
    """At most n clips, evenly spread over the video's timeline (the same np.linspace pick as
    fetch/extend_selection.py). n <= 0 means no cap."""
    if n <= 0 or len(clips) <= n:
        return clips
    if n == 1:
        return clips[:1]
    idx = sorted({round(i * (len(clips) - 1) / (n - 1)) for i in range(n)})
    return [clips[i] for i in idx]


def anon(ti):
    ti.uid = ti.gid = 0
    ti.uname = ti.gname = "root"
    return ti


def cmd_pack(a=None):
    cap = getattr(a, "max_clips_per_video", 30)
    mac_order = list(dict.fromkeys(json.loads(line)["video_id"] for line in open(ROOT / "fetch" / "selection_ru.jsonl")))
    byv = eligible_clips()
    done = done_ids()
    order = [v for v in reversed(mac_order) if v in byv] + [v for v in byv if v not in set(mac_order)]
    i, n_parts = PART
    order = order[i::n_parts]
    if REVERSE:  # a second pod on the same part walks it from the other end
        order.reverse()
    DIST.mkdir(exist_ok=True)
    pod_sel = DIST / f"selection_pod-{NAME}.jsonl"
    n = hours = capped = 0
    with open(pod_sel, "w") as f:
        for v in order:
            # cap first, then drop finished clips: a repack keeps choosing the same clips of a video
            allc = sorted(byv[v], key=lambda r: r["t_start"])
            clips = spread(allc, cap)
            capped += len(clips) < len(allc)
            for r in clips:
                if f"{v}__{r['track']}_{r['start']:06d}" not in done:
                    f.write(json.dumps(r, ensure_ascii=False) + "\n")
                    n += 1
                    hours += r["length"] / 90000
    tmp = bundle().with_suffix(".tmp")
    with tarfile.open(tmp, "w:gz") as t:
        for rel in BUNDLE_PATHS:
            t.add(ROOT / rel, arcname=rel,
                  filter=lambda ti: None if set(Path(ti.name).parts) & BUNDLE_SKIP else anon(ti))
        t.add(pod_sel, arcname="fetch/selection_pod.jsonl")
        for v in order:  # face tracks: the crop needs the dataset's boxes for every video
            tr = ROOT / "data" / "public_meta" / "tracks" / f"{v}.npz"
            if tr.exists():
                t.add(tr, arcname=f"data/public_meta/tracks/{v}.npz", filter=anon)
    tmp.replace(bundle())
    log(f"pack: {bundle().name} {bundle().stat().st_size / 1e6:.0f} MB, part {i + 1}/{n_parts}, pod selection {len(order)} videos, {n} clips, "
        f"{hours:.0f} h (Mac order reversed, <= {cap or 'all'} clips per video, {capped} videos capped), "
        f"{len(done)} done clips excluded")


# ---------------------------------------------------------------- pod access
def target(st):
    return st["host"], st["port"]


def remote(st, cmd, check=True):
    host, port = target(st)
    r = subprocess.run(["ssh"] + ssh_opts(port) + ["root@" + host, cmd], capture_output=True, text=True)
    if check and r.returncode:
        raise RuntimeError(f"pod command failed ({r.returncode}): {cmd[:120]}\n{(r.stderr or r.stdout)[-1500:]}")
    return r


def pod_alive(st):
    try:
        p = rp.req("GET", "/pods/" + st["pod_id"])
    except SystemExit:
        return False
    except OSError:  # network blip or Mac waking up: unknown is not gone, keep watching
        return True
    return p.get("desiredStatus") == "RUNNING"


# ---------------------------------------------------------------- backup
def merge():
    n = 0
    for j in MIRROR.glob("*.json"):
        if j.name.endswith(".tmp.json"):
            continue
        s = j.stem
        if (PUB / f"{s}.json").exists() or not (MIRROR / f"{s}.mp4").exists():
            continue
        for ext in ("mp4", "txt", "npy", "json"):  # json last: it marks the clip complete
            src, dst = MIRROR / f"{s}.{ext}", PUB / f"{s}.{ext}"
            if src.exists() and not dst.exists():
                try:
                    os.link(src, dst)
                except FileExistsError:  # another pod's watcher merged the same clip a moment ago
                    pass
        n += 1
    return n


RV_DUMP = "/root/newdata/rv_videos.jsonl"
# the collector's outcome per video for harvester/channel_quality.py. Only a read: in WAL mode it does not block the
# collector. Not mode=ro: that cannot open a WAL database whose -shm file is gone (collector stopped).
DUMP_RV = f"""[ -f /root/newdata/rv_state.db ] && python3 - <<'EOF'
import json, os, sqlite3
c = sqlite3.connect("/root/newdata/rv_state.db", timeout=30)
rows = c.execute("SELECT video_id, status, stage, reason, dur, clips, clip_sec, probe, updated FROM videos "
                 "WHERE status IN ('done', 'rej', 'failed')").fetchall()
keys = ("video_id", "status", "stage", "reason", "dur", "clips", "clip_sec", "probe", "updated")
with open("{RV_DUMP}.tmp", "w") as f:
    for r in rows:
        f.write(json.dumps(dict(zip(keys, r)), ensure_ascii=False) + "\\n")
os.replace("{RV_DUMP}.tmp", "{RV_DUMP}")
EOF"""


def create_pod_or_clean_up(body):
    """POST /pods; on a timeout or error, delete any pod that was created under this body's name anyway."""
    try:
        return rp.req("POST", "/pods", body)
    except (Exception, SystemExit):
        time.sleep(20)
        try:
            pods = rp.req("GET", "/pods")
            for p in pods if isinstance(pods, list) else pods.get("pods", []):
                if p.get("name") == body["name"]:
                    rp.req("DELETE", "/pods/" + p["id"])
                    log(f"launch: deleted pod {p['id']} created by a failed request")
        except (Exception, SystemExit) as e:
            log(f"launch: could not check for a half-created pod ({e}); harvester/reaper.py removes it in 30 min")
        raise


def arm_backstop(st, grace=1800):
    """Pod-side timer that terminates the pod <grace> s after its deadline, armed before any upload (pod/backstop.sh)."""
    host, port = target(st)
    left = int(st["deadline"] - time.time()) + grace
    subprocess.run(["ssh"] + ssh_opts(port) + ["root@" + host,
                    f"cat > /root/backstop.sh && (setsid nohup bash /root/backstop.sh {left} > /root/backstop.log 2>&1 "
                    f"< /dev/null &)"], input=(ROOT / "harvester" / "pod" / "backstop.sh").read_text(), text=True,
                   capture_output=True, check=True, timeout=120)


def pull(st):
    host, port = target(st)
    MIRROR.mkdir(parents=True, exist_ok=True)
    free = shutil.disk_usage(ROOT).free / 1e9
    if free < MAC_MIN_FREE_GB:
        log(f"backup: skipped, Mac has {free:.0f} GB free (< {MAC_MIN_FREE_GB})")
        return False
    e = "ssh " + " ".join(shlex.quote(x) for x in ssh_opts(port))
    # .npy (~2x the mp4) is recomputable from the mp4 and stays on the pod unless asked for
    skip_npy = [] if st.get("with_npy") else ["--exclude", "*.npy"]
    r = subprocess.run(["rsync", "-a", "--partial", "--timeout=120", "-e", e,
                        "--exclude", "*.tmp.*", "--exclude", "*.tmp", "--exclude", "*.err"] + skip_npy + [
                        f"root@{host}:{st.get('remote', REMOTE)}/data/public/", str(MIRROR) + "/"],
                       capture_output=True, text=True)
    for f in ("fetch/progress.log", "fetch/failures.jsonl", "fetch/run.out", "fetch/features.out"):
        subprocess.run(["rsync", "-a", "--timeout=60", "-e", e, f"root@{host}:{st.get('remote', REMOTE)}/{f}",
                        str(MIRROR / f"_pod_{NAME}_{Path(f).name}")], capture_output=True)
    remote(st, DUMP_RV, check=False)
    subprocess.run(["rsync", "-a", "--timeout=60", "-e", e, f"root@{host}:{RV_DUMP}",
                    str(MIRROR / f"_pod_{NAME}_rv_videos.jsonl")], capture_output=True)
    if r.returncode not in (0, 24):
        log(f"backup: rsync exit {r.returncode}: {r.stderr.strip()[-200:]}")
        return False
    pull_ext(st, e)
    merged = merge()
    remote(st, "touch /workspace/mac_pulled", check=False)  # lets pod/deadline.sh terminate after the last pull
    log(f"backup: mirror {sum(1 for _ in MIRROR.glob('*.json'))} clips, merged {merged} new into data/public")
    return True


def pull_ext(st, e):
    """Dataset segments cut on the pod (extdata/pod_segments.py) go to data/ext/<dataset>/<split>/; train-split clips
    are also hard-linked into the mirror, so the stages and checkpoints count and train on them like collector clips."""
    host, _ = target(st)
    remote_ext = f"root@{host}:{st.get('remote', REMOTE)}/data/ext/"
    subprocess.run(["rsync", "-am", "--timeout=120", "-e", e, "--exclude", "*.tmp*", "--include", "*/",
                    "--include", "*/*/yt_*", "--exclude", "*", remote_ext, str(EXT) + "/"], capture_output=True)
    for ds in EXT.glob("*/selection.jsonl"):
        subprocess.run(["rsync", "-a", "--timeout=60", "-e", e, f"{remote_ext}{ds.parent.name}/rejects.jsonl",
                        str(ds.parent / f"rejects_{NAME}.jsonl")], capture_output=True)
    n = 0
    for split in EXT_TRAIN_SPLITS:
        for js in EXT.glob(f"*/{split}/yt_*.json"):
            if (MIRROR / js.name).exists() or not js.with_suffix(".mp4").exists():
                continue
            for ext in ("mp4", "txt", "json"):  # json last: it marks the clip complete
                with contextlib.suppress(FileExistsError, FileNotFoundError):
                    os.link(js.with_suffix(f".{ext}"), MIRROR / f"{js.stem}.{ext}")
            n += 1
    if n:
        log(f"backup: {n} new dataset clips linked into the mirror")


def heartbeat(st):
    r = remote(st, "cat /workspace/status.json 2>/dev/null; echo; tail -3 /workspace/bootstrap.log", check=False)
    return r.stdout.strip()


# ---------------------------------------------------------------- commands
LAUNCH_KEYS = ("gpu", "min_vcpu", "cpu", "cpu_flavor", "dc", "volume_gb", "max_hours", "workers", "crop", "community",
               "with_npy", "spot", "max_clips_per_video", "every")
RELAUNCH_MAX = 3  # spot relaunches per RELAUNCH_WINDOW
RELAUNCH_WINDOW = 3600
RELAUNCH_MIN_LEFT = 1800  # a new pod needs at least this much life to be worth its setup


def pod_body(a):
    stamp = time.strftime("%Y%m%d-%H%M%S")
    body = rp.make_body(argparse.Namespace(image=rp.IMAGE, gpu=a.gpu, volume_id=None), stamp,
                        prefix=f"claude-harvest-{NAME}-")
    body["ports"] = ["22/tcp"]
    if a.community:
        body["cloudType"] = "COMMUNITY"
    if getattr(a, "min_vcpu", 0):
        body["minVCPUPerGPU"] = a.min_vcpu
    if a.spot:
        # REST POST /pods: "interruptible: true creates an interruptible (spot) pod"; there is no bid field
        body["interruptible"] = True
    # all work happens on the local container disk; the volume only receives the bundle and logs
    body["containerDiskInGb"] = a.volume_gb
    body["volumeInGb"] = 20
    if a.cpu:
        # download + crop are CPU work; features are computed later on the training GPU
        for k in ("gpuCount", "gpuTypeIds", "volumeInGb", "volumeMountPath"):
            body.pop(k, None)
        body.update(computeType="CPU", cpuFlavorIds=[a.cpu_flavor], vcpuCount=a.cpu,
                    containerDiskInGb=min(a.volume_gb, a.cpu * 15))
        if a.dc:
            body["dataCenterIds"] = [a.dc]
    return body


def create_pod(a, cookies, deadline=None, account=None, prev=None):
    """Creates the pod, uploads the bundle and cookies, starts bootstrap. Returns the new state (also saved).
    deadline: absolute self-destruct time (a relaunch keeps the original one). prev: state to restore on failure."""
    body = pod_body(a)
    body["env"]["PUBLIC_KEY"] = rp.pubkey()
    t0 = time.time()
    life = int(deadline - t0) if deadline else int(a.max_hours * 3600)
    pod = create_pod_or_clean_up(body)
    st = {"pod_id": pod["id"], "created": t0, "deadline": t0 + life, "gpu": a.gpu,
          "rate": pod.get("costPerHr") or 0, "with_npy": a.with_npy, "spot": bool(a.spot),
          "launch": {k: getattr(a, k) for k in LAUNCH_KEYS if hasattr(a, k)}, "cookies": str(cookies)}
    if account:
        st["account"] = account
    if prev:  # relaunch: carry the history over
        st.update({k: prev[k] for k in ("relaunches", "spent_prev", "workers", "crop") if k in prev})
    save_state(st)
    log(f"launch: pod {st['pod_id']} ({f'{a.cpu} vCPU {a.cpu_flavor}' if a.cpu else a.gpu}"
        f"{', spot' if a.spot else ''}), ${st['rate']}/h, self-destruct in {life / 3600:.2f} h")
    try:
        pod = rp.wait_pod(st["pod_id"])
        st.update(host=pod["publicIp"], port=pod["portMappings"]["22"], rate=pod.get("costPerHr") or st["rate"])
        save_state(st)
        rp.wait_ssh(*target(st))
        arm_backstop(st)
        host, port = target(st)
        if getattr(a, "min_vcpu", 0):
            q = remote(st, "cat /sys/fs/cgroup/cpu.max 2>/dev/null || echo \"$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us) "
                           "$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)\"", check=False).stdout.split()
            cores = int(q[0]) / int(q[1]) if len(q) == 2 and q[0].lstrip("-").isdigit() and int(q[0]) > 0 else 999
            preflight.require_vcpu(cores, a.min_vcpu)
        remote(st, f"mkdir -p {REMOTE}")
        # scp, not rsync: the image has no rsync until bootstrap installs it
        scp = ["scp", "-q"] + ["-P" if o == "-p" else o for o in ssh_opts(port)]
        subprocess.run(scp + [str(bundle()), f"root@{host}:/workspace/"], check=True)
        remote(st, f"tar --no-same-owner --no-same-permissions -xzf /workspace/{bundle().name} -C {REMOTE} && umask 077 && mkdir -p {REMOTE}/fetch")
        subprocess.run(scp + [str(cookies), f"root@{host}:{REMOTE}/fetch/cookies.txt"], check=True)
        remote(st, f"chmod 600 {REMOTE}/fetch/cookies.txt")
        left = int(st["deadline"] - time.time())
        remote(st, f"cd {REMOTE} || exit 1; setsid nohup bash harvester/pod/bootstrap.sh {left} {a.workers} {a.crop} {1 if a.cpu else 0} "
                   f"> /workspace/bootstrap.log 2>&1 < /dev/null &")
        log(f"launch: bootstrap started on pod {st['pod_id']}")
    except BaseException as ex:
        log(f"launch failed: {ex}; terminating pod")
        try:
            rp.req("DELETE", "/pods/" + st["pod_id"])
        except SystemExit:
            pass
        if prev:
            save_state(prev)
        else:
            state_file().unlink(missing_ok=True)
        raise
    return st


def cmd_launch(a):
    cookies = Path(a.cookies)
    if a.dry_run:
        print(json.dumps(pod_body(a), indent=2))
        if a.account:
            print(f"account {a.account}: cookies come from its pool entry (a profile is exported at launch)")
        if a.cpu:
            print(f"CPU pod {a.cpu_flavor} x {a.cpu} vCPU; price is reported by RunPod on creation (costPerHr); "
                  f"cap {a.max_hours} h; workers {a.workers}, crop {a.crop}"
                  f"{'; spot (interruptible)' if a.spot else ''}")
            return
        price, vcpu, bid = gpu_offer(a.gpu, secure=not a.community)
        if a.spot:
            if bid is None:
                print(f"{a.gpu}: spot, RunPod quotes no minimumBidPrice right now (no spot capacity?); "
                      f"on-demand is ${price}/h")
            else:
                print(f"{a.gpu}: spot (interruptible) minimumBidPrice ${bid}/h vs ${price}/h on-demand, >= {vcpu} vCPU; "
                      f"cost cap {a.max_hours} h = ~${a.max_hours * bid:.2f} (REST has no bid field: RunPod bills the "
                      f"current spot price, shown as costPerHr on creation); workers {a.workers}, crop {a.crop}")
            return
        if price is None:
            sys.exit(f"{a.gpu}: no on-demand offer right now")
        print(f"{a.gpu}: from ${price}/h, >= {vcpu} vCPU; cost cap {a.max_hours} h = ~${a.max_hours * price:.2f}; "
              f"workers {a.workers}, crop {a.crop}")
        return
    if not a.account and not cookies.exists():
        sys.exit(f"{cookies} not found")
    preflight.require_no_hold()
    preflight.acquire_lock()
    if a.cpu:
        planned = a.max_hours * 0.06 * a.cpu  # CPU pods are priced on creation; ~$0.06 per vCPU-hour is the ceiling
    else:
        price, _, _ = gpu_offer(a.gpu, secure=not a.community)
        if price is None:
            sys.exit(f"{a.gpu}: no on-demand offer right now")
        planned = a.max_hours * price
    preflight.require_budget(planned, f"launch {NAME} ({a.gpu if not a.cpu else f'{a.cpu} vCPU'}, {a.max_hours} h)")
    if not bundle().exists() or a.repack:
        cmd_pack(a)
    st = load_state()
    if st and pod_alive(st):
        sys.exit(f"pod {st['pod_id']} is already running; use watch/stop")
    account = None
    if a.account:
        with pool_edit() as pool:
            if a.account not in pool or pool[a.account].get("burned") or pool[a.account].get("pod"):
                sys.exit(f"account {a.account}: not in the pool, burned or in use")
            pool[a.account]["pod"] = NAME
            entry = dict(pool[a.account])
        try:
            cookies = account_cookies(a.account, entry)
        except (ZgnError, NotLoggedIn) as ex:
            release_account(a.account, burn="logged out (cookie export)" if isinstance(ex, NotLoggedIn) else None)
            sys.exit(f"account {a.account}: {ex}")
        account = a.account
    try:
        create_pod(a, cookies, account=account)
    except BaseException:
        if account:
            release_account(account)
        raise
    cmd_watch(a)


POOL = HERE / "accounts.json"
EXPORT_CMD = ["node", str(ROOT / "fetch" / "tools" / "export_cookies.mjs")]


class ZgnError(Exception):
    """zgnspaces (antidetect browser) is unreachable or answered with an error; the account itself is fine."""


class NotLoggedIn(Exception):
    """The profile's browser is not logged in to YouTube/Google."""


def zgn_call(port, method, path, body=None, timeout=30):
    token = os.environ.get("ZGN_TOKEN", "").strip()
    if not token:
        raise ZgnError("ZGN_TOKEN is not set")
    r = urllib.request.Request(f"http://127.0.0.1:{port}{path}", method=method,
                               data=json.dumps(body).encode() if body is not None else None,
                               headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(r, timeout=timeout) as resp:
            raw = resp.read()
        return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raise ZgnError(f"{method} {path} -> HTTP {e.code}")
    except (OSError, ValueError) as e:  # URLError, timeouts, bad JSON; never echoes the request headers
        raise ZgnError(f"{method} {path} failed: {type(e).__name__}")


def listening_ports():
    """Loopback TCP ports somebody listens on, as [(port, command)]; processes named like zgnspaces first."""
    r = subprocess.run(["lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-Fcn"], capture_output=True, text=True)
    found, cmd = {}, ""
    for line in r.stdout.splitlines():
        if line.startswith("c"):
            cmd = line[1:]
        elif line.startswith("n"):
            m = re.fullmatch(r"(127\.0\.0\.1|localhost|\*|\[::1\]):(\d+)", line[1:])
            if m:
                found.setdefault(int(m.group(2)), cmd)
    return sorted(found.items(), key=lambda kv: ("zgn" not in kv[1].lower(), kv[0]))


_zgn = {}


def zgn_port():
    """Port of the zgnspaces REST API: the first listening port where GET /v1/profiles answers 200.
    Ports of processes named like zgnspaces are tried first, so the token reaches other local services
    only when the app is not found by name."""
    from concurrent.futures import ThreadPoolExecutor
    if "port" in _zgn:
        return _zgn["port"]

    def probe(port):
        try:
            zgn_call(port, "GET", "/v1/profiles", timeout=2)
            return True
        except ZgnError as e:
            if "ZGN_TOKEN" in str(e):
                raise
            return False

    ports = listening_ports()
    tiers = [[p for p, c in ports if "zgn" in c.lower()], [p for p, c in ports if "zgn" not in c.lower()]]
    if os.environ.get("ZGN_PORT", "").isdigit():  # optional hint, still verified
        tiers.insert(0, [int(os.environ["ZGN_PORT"])])
    for tier in tiers:
        if not tier:
            continue
        with ThreadPoolExecutor(max_workers=16) as ex:
            for port, ok in zip(tier, ex.map(probe, tier)):
                if ok:
                    _zgn["port"] = port
                    return port
    raise ZgnError("zgnspaces API not found on any listening port (is the app running?)")


def zgn_profile(name):
    """(port, profile id) of the antidetect profile called `name`; re-probes the port once if the app restarted."""
    for attempt in (0, 1):
        port = zgn_port()
        try:
            data = zgn_call(port, "GET", "/v1/profiles")
            break
        except ZgnError:
            if attempt:
                raise
            _zgn.clear()
    items = data if isinstance(data, list) else next(
        (data[k] for k in ("profiles", "data", "items", "results") if isinstance(data.get(k), list)), [])
    for p in items:
        if name in (p.get("name"), str(p.get("id"))):
            return port, str(p["id"])
    raise ZgnError(f"antidetect profile '{name}' not found")


def export_profile_cookies(name, profile):
    """Starts the antidetect profile, exports its YouTube/Google cookies to fetch/cookies_<name>.txt (600) and
    kills the profile at once: an open browser keeps rotating the cookies. Raises NotLoggedIn / ZgnError."""
    out = ROOT / "fetch" / f"cookies_{name}.txt"
    tmp = out.with_name(out.name + ".new")
    port, pid = zgn_profile(profile)
    try:
        try:
            info = zgn_call(port, "POST", f"/v1/profiles/{pid}/run", {"headless": False}, timeout=120)
            dev = info.get("remote_debugging_port") or (info.get("data") or {}).get("remote_debugging_port")
            if not dev:
                raise ZgnError("run returned no remote_debugging_port")
            res = None
            for _ in range(4):  # the browser needs a moment before its DevTools port answers
                res = subprocess.run(EXPORT_CMD + [str(dev), str(tmp)], capture_output=True, text=True,
                                     preexec_fn=lambda: os.umask(0o077))
                if res.returncode == 0:
                    break
                time.sleep(2)
            if res.returncode:
                raise ZgnError("cookie export failed: " + (res.stderr or res.stdout).strip()[-150:])
        finally:
            try:
                zgn_call(port, "POST", f"/v1/profiles/{pid}/kill", {})
            except ZgnError as e:
                log(f"accounts: could not kill profile {profile}: {e}")
        m = re.search(r"logged in:\s*(true|false)", res.stdout)
        if not m:
            raise ZgnError("cookie export printed no 'logged in' verdict")
        if m.group(1) != "true":
            raise NotLoggedIn(f"profile '{profile}' is not logged in")
        os.chmod(tmp, 0o600)
        os.replace(tmp, out)
        return out
    finally:
        tmp.unlink(missing_ok=True)


def account_cookies(name, entry):
    """Cookie file of a pool entry: its ready "file", or a fresh export from its antidetect "profile"."""
    if entry.get("profile"):
        return export_profile_cookies(name, entry["profile"])
    return ROOT / entry["file"]


@contextlib.contextmanager
def pool_edit():
    import fcntl
    with open(POOL, "r+") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        pool = json.load(f)
        yield pool
        f.seek(0), f.truncate(), json.dump(pool, f, indent=1)


def release_account(name, burn=None):
    with pool_edit() as pool:
        if name in pool:
            pool[name].update(pod=None)
            if burn:
                pool[name].update(burned=True, reason=burn)


def claim_account(st, why):
    """Burns the pod's current pool account and claims the next usable one: (name, cookie file) or None.
    A profile that is logged out is burned with a reason and the next account is tried; an unreachable
    antidetect browser only skips that account for now."""
    cur, skip = st.get("account"), set()
    while True:
        with pool_edit() as pool:
            if cur in pool:
                pool[cur].update(burned=True, pod=None, reason=why)
            cur = None
            fresh = next((k for k, v in pool.items()
                          if not v.get("burned") and not v.get("pod") and k not in skip), None)
            if fresh:
                pool[fresh]["pod"] = NAME
                entry = dict(pool[fresh])
        if not fresh:
            return None
        try:
            return fresh, account_cookies(fresh, entry)
        except NotLoggedIn as e:
            log(f"accounts: {fresh}: {e}; burned")
            release_account(fresh, burn="logged out (cookie export)")
        except ZgnError as e:
            log(f"accounts: {fresh} skipped: {e}")
            release_account(fresh)
            skip.add(fresh)


def rotate_account(st, why):
    """Moves the pod to a fresh account from the shared pool. False when the pool is empty."""
    got = claim_account(st, why)
    if not got:
        log(f"rotate: {why}, but no fresh account is left")
        return False
    fresh, path = got
    host, port = target(st)
    root = st.get("remote", REMOTE)
    scp = ["scp", "-q"] + ["-P" if o == "-p" else o for o in ssh_opts(port)]
    subprocess.run(scp + [str(path), f"root@{host}:{root}/fetch/cookies.new"], check=True)
    remote(st, f"cd {root}/fetch && chmod 600 cookies.new && shred -u cookies.txt; mv cookies.new cookies.txt && "
               f"bash {root}/harvester/pod/restart_fetch.sh {st.get('workers', 30)} {st.get('crop', 31)}")
    st["account"] = fresh
    st["cookies"] = str(path)
    save_state(st)
    log(f"rotate: {why}; pod {NAME} now uses account {fresh}")
    return True


def cmd_accounts(_a):
    pool = json.loads(POOL.read_text())
    print(f"{'name':<12}{'profile':<24}{'pod':<8}burned")
    for k, v in pool.items():
        b = f"yes ({v['reason']})" if v.get("burned") and v.get("reason") else "yes" if v.get("burned") else "no"
        print(f"{k:<12}{v.get('profile') or '-':<24}{v.get('pod') or '-':<8}{b}")


def relaunch_cookies(st):
    """Cookie file for a relaunched pod: the pod's account (re-exported if it is a profile), else the launch file."""
    acct = st.get("account")
    entry = json.loads(POOL.read_text()).get(acct) if acct else None
    if not entry:
        return Path(st["cookies"])
    try:
        return account_cookies(acct, entry)
    except NotLoggedIn as e:
        got = claim_account(st, "logged out (cookie export)")
        if not got:
            raise RuntimeError(f"{e}; no fresh account is left")
        st["account"] = got[0]
        return got[1]
    except ZgnError:
        old = ROOT / "fetch" / f"cookies_{acct}.txt"
        if old.exists():  # the antidetect app is down: the last export is the best we have
            return old
        raise


def relaunch(st):
    """The spot pod vanished before its deadline: last pull if still possible, then the same pod again
    (name, part, account, bundle) for the rest of the original life. None when it must not or cannot."""
    log(f"watch: spot pod {st['pod_id']} is gone before its deadline")
    try:
        pull(st)  # usually unreachable by now; whatever the last backup missed stays lost
    except Exception as e:
        log(f"watch: final pull impossible: {str(e)[:120]}")
    try:
        rp.req("DELETE", "/pods/" + st["pod_id"])  # a stopped (EXITED) spot pod still holds disk
    except SystemExit:
        pass
    now = time.time()
    st["spent_prev"] = st.get("spent_prev", 0) + max(0, now - st["created"]) / 3600 * st["rate"]
    if st["deadline"] - now < RELAUNCH_MIN_LEFT:
        log(f"watch: only {(st['deadline'] - now) / 60:.0f} min to the deadline, not relaunching")
        return None
    bal, spend = balance()
    if bal is not None and bal < max((spend or 0) * 0.4, st["rate"] * 0.5):
        log(f"watch: balance ${bal:.2f}, not relaunching")
        return None
    a = argparse.Namespace(**st["launch"])
    while True:
        recent = [t for t in st.get("relaunches", []) if time.time() - t < RELAUNCH_WINDOW]
        if len(recent) >= RELAUNCH_MAX:
            log(f"watch: {RELAUNCH_MAX} relaunches within an hour, giving up")
            return None
        st["relaunches"] = recent + [time.time()]  # an attempt counts even if RunPod has no spot capacity
        save_state(st)
        try:
            cmd_pack(a)  # finished clips drop out of the new pod's selection
            new = create_pod(a, relaunch_cookies(st), deadline=st["deadline"], account=st.get("account"), prev=st)
        except (Exception, SystemExit) as e:
            log(f"watch: relaunch failed: {str(e)[:200]}")
            time.sleep(60)
            continue
        log(f"watch: relaunched as pod {new['pod_id']} ({len(new['relaunches'])}/{RELAUNCH_MAX} in the last hour)")
        return new


def cmd_watch(a):
    st = load_state()
    if not st:
        sys.exit("no pod in state.json")
    stop = {"now": False}
    signal.signal(signal.SIGTERM, lambda *_: stop.update(now=True))
    progress = {"clips": -1, "since": time.time()}
    while not stop["now"]:
        st = load_state() or st  # extend may have moved the deadline
        if not pod_alive(st):
            # `stop` removes the state file; a spot pod only counts as lost while the file is still there
            if st.get("spot") and state_file().exists() and time.time() < st["deadline"]:
                new = relaunch(st)
                if new:
                    st = new
                    progress.update(clips=-1, since=time.time())
                    continue
            else:
                log("watch: pod is gone")
            break
        pull(st)
        hb = heartbeat(st)
        if hb:
            log("pod: " + hb.splitlines()[0][:400])
        bal, spend = balance()
        if bal is not None and spend and bal < spend * 0.4:
            # an empty balance stops pods without warning and their local disks are lost: leave while backups work
            log(f"watch: balance ${bal:.2f} at ${spend:.2f}/h, stopping before it runs out")
            cmd_stop(a)
            return
        settled = time.time() - st["created"] > 1800
        live = time.time() < st["deadline"]
        try:
            clips = json.loads(hb.splitlines()[0])["clips"]
        except (ValueError, IndexError, KeyError):
            clips = progress["clips"]
        if clips != progress["clips"]:
            progress.update(clips=clips, since=time.time())
        stalled = settled and time.time() - progress["since"] > 900
        # once the MultiVSR fetcher is retired on purpose, another collector feeds the pod: never rotate or stop on it
        retired = st.get("fetch_retired")
        blocked = not retired and ("cookies rejected" in hb or (settled and '"fetch":"stopped"' in hb) or stalled)
        if live and blocked and rotate_account(st, "cookies rejected" if "cookies rejected" in hb else
                                               "no new clips for 15 min" if stalled else "fetcher stopped"):
            progress.update(since=time.time())
        elif blocked or (settled and '"ts"' not in hb and not retired):
            log("watch: fetcher stopped or never started on the pod; stopping to save money")
            cmd_stop(a)
            return
        # past the deadline the pod waits for one more pull before it terminates itself: pull every minute
        wait = 60 if time.time() > st["deadline"] else int(a.every)
        for _ in range(wait):
            if stop["now"]:
                break
            time.sleep(1)
    h = (time.time() - st["created"]) / 3600
    log(f"watch: done, ~{h:.2f} h, ~${h * st['rate'] + st.get('spent_prev', 0):.2f}")


def cmd_extend(a):
    """Move the self-destruct to --hours from now; the running watcher must be restarted to see it."""
    st = load_state()
    if not st or not pod_alive(st):
        sys.exit("no running pod")
    life = int(a.hours * 3600)
    remote(st, f"bash {st.get('remote', REMOTE)}/harvester/pod/rearm.sh {life}")
    st["deadline"] = time.time() + life
    save_state(st)
    log(f"extend: pod {st['pod_id']} now self-destructs in {a.hours} h (~${a.hours * st['rate']:.2f} more)")


def cmd_pull(_a):
    st = load_state()
    if not st:
        sys.exit("no pod in state.json")
    pull(st)


def cmd_status(_a):
    st = load_state()
    if st and pod_alive(st):
        left = (st["deadline"] - time.time()) / 3600
        print(f"pod {st['pod_id']} running, {left:.1f} h left, ~${(time.time() - st['created']) / 3600 * st['rate']:.2f} so far")
        print(heartbeat(st))
    else:
        print("no running pod")
    print(f"local: data/public {len(done_ids())} clips, mirror {sum(1 for _ in MIRROR.glob('*.json')) if MIRROR.exists() else 0}")


def cmd_stop(_a):
    st = load_state()
    if not st:
        sys.exit("no pod in state.json")
    if pod_alive(st):
        root = st.get("remote", REMOTE)
        remote(st, f"touch {root}/fetch/STOP {root}/fetch/FEATURES_STOP; [ -d /root/newdata ] && touch /root/newdata/STOP",
               check=False)
        for _ in range(30):
            if "running" not in remote(st, "pgrep -f '[p]ython3 fetch/run.py|[r]v_collect.py run' > /dev/null && echo running",
                                       check=False).stdout:
                break
            time.sleep(10)
        pull(st)
        remote(st, f"shred -u {root}/fetch/cookies.txt", check=False)
        rp.req("DELETE", "/pods/" + st["pod_id"])
    h = (time.time() - st["created"]) / 3600
    log(f"stop: pod {st['pod_id']} terminated, {h:.2f} h, ~${h * st['rate'] + st.get('spent_prev', 0):.2f}")
    state_file().unlink(missing_ok=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", default="a", help="pod name; each pod has its own bundle and state")
    ap.add_argument("--part", default="1/1", help="this pod's share of the selection, e.g. 2/3")
    ap.add_argument("--reverse", action="store_true", help="walk the part from its other end")
    sub = ap.add_subparsers(dest="cmd", required=True)
    cap = dict(type=int, default=30, help="at most N clips per video, evenly spread in time (more speakers, "
               "fewer minutes of each); 0 = all")
    sub.add_parser("pack").add_argument("--max-clips-per-video", **cap)
    la = sub.add_parser("launch")
    la.add_argument("--max-hours", type=float, default=8)
    la.add_argument("--workers", default="auto", help="download threads; auto = 3 x crop processes")
    la.add_argument("--crop", default="auto", help="crop processes; auto = pod vCPUs")
    la.add_argument("--gpu", default=rp.GPU)
    la.add_argument("--cpu", type=int, default=0, help="vCPUs of a CPU-only pod instead of a GPU pod")
    la.add_argument("--min-vcpu", type=int, default=0, help="refuse GPU hosts with fewer vCPUs (some 3090 hosts give 5)")
    la.add_argument("--cpu-flavor", default="cpu5c")
    la.add_argument("--dc", default="EU-RO-1", help="data center of a CPU pod; Europe sits closest to the Mac's cookies")
    la.add_argument("--volume-gb", type=int, default=200, help="local container disk, GB")
    la.add_argument("--every", type=int, default=300, help="backup interval, seconds")
    la.add_argument("--repack", action="store_true")
    la.add_argument("--with-npy", action="store_true", help="also back up features to the Mac (~2x more data)")
    la.add_argument("--max-clips-per-video", **cap)
    la.add_argument("--spot", action="store_true", help="interruptible pod (cheaper); relaunched by the watcher if lost")
    la.add_argument("--account", help="take cookies from this pool account (an antidetect profile is exported now)")
    la.add_argument("--dry-run", action="store_true")
    la.add_argument("--cookies", default=str(COOKIES), help="cookie file sent to the pod (use a throwaway account)")
    la.add_argument("--community", action="store_true", help="community cloud: cheaper, hosted by third parties")
    w = sub.add_parser("watch")
    w.add_argument("--every", type=int, default=300)
    ex = sub.add_parser("extend")
    ex.add_argument("--hours", type=float, required=True)
    for name in ("pull", "status", "stop", "accounts"):
        sub.add_parser(name)
    a = ap.parse_args()
    global NAME, PART, REVERSE
    NAME = a.name
    REVERSE = a.reverse
    k, n = map(int, a.part.split("/"))
    PART = (k - 1, n)
    {"pack": cmd_pack, "launch": cmd_launch, "watch": cmd_watch, "pull": cmd_pull, "extend": cmd_extend,
     "status": cmd_status, "stop": cmd_stop, "accounts": cmd_accounts}[a.cmd](a)


if __name__ == "__main__":
    main()
