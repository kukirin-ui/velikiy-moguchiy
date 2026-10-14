#!/usr/bin/env python3
"""Deletes this project's pods that outlived their deadline or that no state file knows about.

  python3 harvester/reaper.py [--dry-run]     one sweep; harvester/supervisor.py calls sweep() every minute
  nohup caffeinate -i python3 harvester/reaper.py --loop &    on its own, so it outlives a dead supervisor

The pod-side timers (pod/deadline.sh, pod/backstop.sh) are the first line; this is the Mac-side second one, for a timer
that never started or a terminate call that never landed. Only pods named claude-harvest-* or claude-ckpt-* are touched.
"""
import json
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import harvest  # noqa: E402

PREFIXES = ("claude-harvest-", "claude-ckpt-")
GRACE_S = 25 * 60  # deadline.sh waits up to 15 min for the last pull; then it is ours to delete
ORPHAN_S = 30 * 60  # a launch writes its state file before the pod exists, so an unknown pod is a leftover
SEEN = HERE / "reaper_seen.json"


def sweep(dry_run=False) -> list:
    pods = harvest.rp.req("GET", "/pods")
    pods = pods if isinstance(pods, list) else pods.get("pods", [])
    known = {}
    for f in (HERE / "state").glob("*.json"):
        st = json.loads(f.read_text())
        if st.get("pod_id"):
            known[st["pod_id"]] = (f.stem, st)
    seen = json.loads(SEEN.read_text()) if SEEN.exists() else {}
    now, out = time.time(), []
    for p in pods:
        if not str(p.get("name", "")).startswith(PREFIXES) or p.get("desiredStatus") == "TERMINATED":
            continue
        pid = p["id"]
        seen.setdefault(pid, now)
        if pid in known:
            name, st = known[pid]
            why = f"{name}: {(now - st['deadline']) / 60:.0f} min past its deadline" \
                if now > st.get("deadline", now) + GRACE_S else None
        else:
            why = f"{p.get('name')}: no state file for {(now - seen[pid]) / 60:.0f} min" \
                if now - seen[pid] > ORPHAN_S else None
        if why:
            if not dry_run:
                harvest.rp.req("DELETE", "/pods/" + pid)
            out.append(f"reaper: {'would delete' if dry_run else 'deleted'} pod {pid} ({why}, "
                       f"${p.get('costPerHr')}/h)")
    live = {p["id"] for p in pods}
    SEEN.write_text(json.dumps({k: v for k, v in seen.items() if k in live}))
    return out


if __name__ == "__main__":
    while True:
        try:
            lines = sweep(dry_run="--dry-run" in sys.argv)
        except (Exception, SystemExit) as e:  # noqa  rp.req turns HTTP errors into SystemExit
            lines = [f"reaper: sweep failed: {type(e).__name__}: {str(e)[:160]}"]
        for line in lines or ([] if "--loop" in sys.argv else ["reaper: nothing to delete"]):
            print(time.strftime("%F %T ") + line, flush=True)
        if "--loop" not in sys.argv:
            break
        time.sleep(60)
