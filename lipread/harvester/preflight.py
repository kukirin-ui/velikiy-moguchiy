"""Checks that refuse to spend money when a rule from RULES.md is broken. Imported by harvest.py and mac_feeder.py.

Every check raises SystemExit with the rule number; there is no override flag on purpose.
"""
import json
import os
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
LOCK = HERE / "OPERATOR.lock"
CHANNELS = HERE / "video_channels.tsv"
BALANCE_FLOOR = 0.50
LOCK_STALE_H = 12


def require_budget(planned_usd: float, what: str):
    """R6: the planned cost must leave BALANCE_FLOOR on the account."""
    import harvest
    bal, spend = harvest.balance()
    # every running pod bills until its deadline plus the backstop grace (pod/backstop.sh), not just for a while
    committed = 0.0
    for f in (HERE / "state").glob("*.json"):
        st = json.loads(f.read_text())
        committed += st.get("rate", 0) * max(0.0, st.get("deadline", 0) - time.time() + 1800) / 3600
    left = bal - planned_usd - max(committed, spend * 0.25)
    if left < BALANCE_FLOOR:
        raise SystemExit(f"[R6] {what}: planned ${planned_usd:.2f} with balance ${bal:.2f} and ${committed:.2f} "
                         f"committed to running pods leaves ${left:.2f} < ${BALANCE_FLOOR:.2f}. Lower --max-hours "
                         f"or top up.")


def require_no_hold():
    """A stage hold stops the collection; no pod may start until checkpoint_loop.py decide/budget clears it."""
    hold = HERE / "STAGE_HOLD"
    if hold.exists():
        raise SystemExit(f"[R18] collection is on hold: {hold.read_text().strip()}")


def acquire_lock():
    """R7: one operator (one agent session) drives the pods; the name comes from env LIPREAD_OPERATOR."""
    me = os.environ.get("LIPREAD_OPERATOR")
    if not me:
        raise SystemExit("[R7] set LIPREAD_OPERATOR=<your session name> before launching pods")
    if LOCK.exists():
        owner = LOCK.read_text().strip()
        fresh = time.time() - LOCK.stat().st_mtime < LOCK_STALE_H * 3600
        if owner and owner != me and fresh:
            raise SystemExit(f"[R7] pods are driven by '{owner}' (harvester/OPERATOR.lock). Ask that session or the "
                             f"user; delete the lock only when that session is stopped.")
    tmp = LOCK.with_suffix(f".{os.getpid()}.tmp")  # parallel launches must never read a half-written lock
    tmp.write_text(me + "\n")
    os.replace(tmp, LOCK)


def require_vcpu(cores: float, wanted: int):
    """R5: a pod with fewer cores than ordered is refused (a 5-core 3090 cost as much as a 31-core one)."""
    if wanted and cores < wanted - 1:
        raise SystemExit(f"[R5] pod has {cores:.1f} cores, {wanted} were ordered")


def channel_map() -> dict:
    out = {}
    if CHANNELS.exists():
        for line in CHANNELS.read_text().splitlines():
            vid, _, ch = line.partition("\t")
            if vid and ch:
                out[vid] = ch
    return out


def remember_channel(vid: str, info_json: Path):
    """Records which channel (speaker) a downloaded video belongs to; train_e2e.py balances and splits by it."""
    try:
        info = json.loads(info_json.read_text())
    except (OSError, ValueError):
        return None
    ch = info.get("channel_id") or info.get("uploader_id") or info.get("channel") or info.get("uploader")
    if ch:
        with open(CHANNELS, "a") as f:
            f.write(f"{vid}\t{ch}\n")
    return ch, float(info.get("duration") or 0)
