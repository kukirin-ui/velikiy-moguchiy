#!/usr/bin/env python3
"""Turns a freshly launched harvest pod into an inbox-only collector for the videos the Mac feeder ships.

  python3 harvester/deploy_collector.py p10 [--shard 4/5] [--gpu-servers 3]

Waits for the pod's bootstrap, stops the MultiVSR fetcher it starts, uploads newdata/ with the SyncNet weights,
installs the collector's packages (newdata/setup_pod.sh) and starts the collector on 26 processes, then the
external-dataset segment cutter (extdata/pod_start.sh) with the selection lists of data/ext.
"""
import argparse
import glob
import json
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
# datasets whose sections the pilot ships (harvester/supervisor.py FEED_CMD); MultiVSR's list alone is 199 MB
EXT_DATASETS = ("muavic_ru", "voxceleb2_ru")
ROOT = HERE.parent
sys.path.insert(0, str(HERE))
import harvest  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("name")
    ap.add_argument("--shard", default="4/5")
    ap.add_argument("--gpu-servers", type=int, default=3)
    a = ap.parse_args()
    state = HERE / "state" / f"{a.name}.json"
    for _ in range(120):
        if not state.exists():  # the launch gave the pod up (R5 core check, errors)
            sys.exit(f"{a.name}: launch removed the pod")
        st = json.loads(state.read_text())
        # the log keeps every launch ever made under this name: only this pod's line counts
        if st.get("host") and f"bootstrap started on pod {st['pod_id']}" in (HERE / f"harvest-{a.name}.log").read_text():
            break
        time.sleep(10)
    else:
        sys.exit(f"{a.name}: pod never finished launching")
    # the pod's watcher stops a pod whose MultiVSR fetcher is stopped, unless the fetcher is marked as retired
    st["fetch_retired"] = True
    state.write_text(json.dumps(st, indent=1))
    run = lambda cmd, t=600: harvest.remote(st, cmd, check=False)  # noqa: E731
    host, port = harvest.target(st)
    scp = ["scp", "-q"] + ["-P" if o == "-p" else o for o in harvest.ssh_opts(port)]
    run("mkdir -p /root/lr/fetch && touch /root/lr/fetch/STOP; mkdir -p /root/newdata/weights /root/newdata/work/tmp /root/newdata/logs "
        "/root/newdata/inbox")
    nd = ROOT / "newdata"
    files = (glob.glob(str(nd / "*.py")) + glob.glob(str(nd / "*.sh")) +
             [str(nd / "calib.json"), str(nd / "rv_thresholds.json"), str(ROOT / "facecrop.py"),
              str(ROOT / "multivsr" / "preprocess" / "SyncNetModel.py")])
    subprocess.run(scp + [str(nd / "weights" / "syncnet_v2.model"), f"root@{host}:/root/newdata/weights/"], check=True)
    subprocess.run(scp + files + [f"root@{host}:/root/newdata/"], check=True)
    print(f"{a.name}: code uploaded, installing packages", flush=True)
    r = run("cd /root/newdata && chmod +x *.sh && ./setup_pod.sh > logs/setup.log 2>&1; tail -1 logs/setup.log")
    if "SETUP_OK" not in r.stdout:
        sys.exit(f"{a.name}: setup failed: {r.stdout[-300:]}")
    # some community hosts report a GPU whose driver can't run CUDA: give such a pod back at once
    r = run("cd /root/newdata && venv/bin/python -c 'import torch; torch.zeros(1).cuda(); print(\"CUDA_OK\")' 2>&1 | tail -1")
    if "CUDA_OK" not in r.stdout:
        sys.exit(f"{a.name}: CUDA does not work on this host: {r.stdout.strip()[-200:]}")
    run(f"cd /root/newdata && GPUN={a.gpu_servers} INBOX_ONLY=1 RT=0 ./start.sh 26 {a.shard} > /dev/null 2>&1 < /dev/null")
    time.sleep(60)
    r = run("echo collectors $(pgrep -fc '[r]v_collect.py run') gpu_servers $(pgrep -fc '[g]pu_server.py') "
            "cores $(awk '{printf \"%.0f\", $1/$2}' /sys/fs/cgroup/cpu.max 2>/dev/null)")
    print(f"{a.name}: {r.stdout.strip()}", flush=True)
    try:  # the collector already works; a failed dataset cutter is restarted by the supervisor, not a lost pod
        print(f"{a.name}: {start_segments(st, a.gpu_servers)}", flush=True)
    except Exception as e:  # noqa: BLE001
        print(f"{a.name}: segments not started: {type(e).__name__}: {e}", flush=True)


def start_segments(st, gpu_servers=3):
    """Uploads extdata/ and data/ext/*/selection.jsonl, starts extdata/pod_segments.py; returns its last status line."""
    run = lambda cmd: harvest.remote(st, cmd, check=False)  # noqa: E731
    host, port = harvest.target(st)
    scp = ["scp", "-q"] + ["-P" if o == "-p" else o for o in harvest.ssh_opts(port)]
    sels = [ROOT / "data" / "ext" / d / "selection.jsonl" for d in EXT_DATASETS]
    run("mkdir -p /root/extdata /root/newdata/inbox_seg " +
        " ".join(f"/root/lr/data/ext/{p.parent.name}" for p in sels))
    ed = ROOT / "extdata"
    subprocess.run(scp + [str(ed / f) for f in ("pod_segments.py", "report.py", "pod_requirements.txt", "pod_start.sh")]
                   + [f"root@{host}:/root/extdata/"], check=True)
    for p in sels:
        subprocess.run(scp + [str(p), f"root@{host}:/root/lr/data/ext/{p.parent.name}/"], check=True)
    # detached: the first run installs speechbrain for minutes; the supervisor's probe reports whether it came up
    run(f"chmod +x /root/extdata/pod_start.sh; (GPUN={gpu_servers} setsid nohup /root/extdata/pod_start.sh 6 "
        f"> /root/newdata/logs/pod_start.log 2>&1 < /dev/null &)")
    return "segments starting (newdata/logs/pod_start.log on the pod)"


if __name__ == "__main__":
    main()
