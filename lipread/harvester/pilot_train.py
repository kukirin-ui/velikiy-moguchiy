#!/usr/bin/env python3
"""The pilot's one training step: do clips from many channels help lip reading of people the model never saw, more
than the same hours from a few channels?

  pilot_train.py plan [--since EPOCH] [--max-clips N]   (Mac) pick the clips and print the plan; no pod
  caffeinate -i pilot_train.py run [--since ...]         one trainer pod: three runs, the exams, delete the pod, write
                                                         results/pilot.md. Under caffeinate: a sleeping Mac stops
                                                         polling and pulling, the pod then dies on its own timer
  pilot_train.py decide                                 (Mac) the verdict again from the pulled exam results

Only pilot clips (json arrived after the pilot start, --since or harvester/pilot_start.txt; 720p like the exams, R3),
10-200 frames (train_e2e.py trains clips of <= 8 s), train_e2e.py's train split (--dev-pct), no exam clip or MuAViC
valid/test video:
  NEW     every channel, at most 24% each (R1)
  NARROW  the same hours from the 5 channels with the most clips, ~20% each, clip lengths matched to NEW's
  dev     held-out pilot channels (train_e2e.py's channel split), the same for every run, for best.pt only
Three runs from e2e_full with the same steps (<= PASSES passes over NEW) and batch layout: new (seed 0), narrow0
(seed 0), narrow1 (seed 1: the seed noise). The exams grade each run's final step (last.pt); best.pt follows the dev
loss and would favour whichever data is closer to dev (harvester/pod/pilot_train.sh).
Verdict on MuAViC (main exam, 16 speakers; paired bootstrap over speakers): "diversity helps" only if new beats both
narrow runs with the 95% interval above 0 and by more than narrow0 and narrow1 differ; otherwise "no evidence". No
verdict when a run stopped on its time guard or the runs differ in steps.
No model runs on the Mac (R11): it selects clips, ships them and reads the pod's exam results.
"""
from __future__ import annotations

import argparse
import bisect
import contextlib
import json
import math
import os
import re
import subprocess
import sys
import time
from collections import Counter, namedtuple
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(ROOT))
import checkpoint_loop as cl  # noqa: E402
import exams  # noqa: E402
import metrics  # noqa: E402
import preflight  # noqa: E402
import split  # noqa: E402

TRAINER = "tp"
START_FILE = HERE / "pilot_start.txt"
LISTS = HERE / "pilot"
OUT = cl.RUNS / TRAINER
REPORT = ROOT / "results" / "pilot.md"
INIT = ROOT / "results" / "pod_runs" / "t1" / "checkpoints" / "e2e_full" / "best.pt"
CLIPS = ROOT / "clips"
MUAVIC_SELECTION = exams.MUAVIC / "selection.jsonl"
CODE = cl.CODE + ["harvester/pod/pilot_train.sh", "harvester/pilot_train.py", "harvester/checkpoint_loop.py",
                  "harvester/preflight.py"]
ARMS = ("new", "narrow0", "narrow1")
MIN_FRAMES, MAX_FRAMES = 10, 200
MIN_HEIGHT = 720  # R3
MIN_CHANNELS = 5
NARROW_CHANNELS = 5
NARROW_SLACK = 0.9  # NARROW's smallest channel keeps 10% spare clips for matching lengths and hours
HOURS_TOL = 0.05
MIN_HOURS = 1.5
SHARE = 0.24  # R1 allows 25%
PASSES = 3  # over NEW's clips; more would be 8-25 epochs on a few hours
CLIPS_PER_STEP = cl.CLIPS_PER_STEP
EVALS = 4  # dev-loss evaluations per run besides step 0: best.pt is information only
MIN_STEPS = 100  # the pod refuses when fewer fit in its time budget
BACKSTOP_H = 0.5  # harvest.arm_backstop's grace after the pod's deadline
DEADLINE_TAIL_S = 720  # deadline.sh: 120 s after the timer, then up to 600 s waiting for a Mac pull
PULL_S = 600
# the plan's guesses; the pod measures the speed, the overhead and the exam time itself
SETUP_MIN, OVERHEAD_S, EXAM_MIN = 15, 240, 15
GIVE_UP_S = 600  # the Mac's last pull happens this long before the pod's hour POD_HOURS, while it still answers
# the exams the verdict and the report read: owner_voiced crops 101 raw videos (~13 min), heldout asks something else
EXAMS = "muavic,owner_silent"
DEV_PCT = 10  # train_e2e.py --dev-pct: 3% of ~40-100 pilot channels may be no channel at all
ARMS_HOURS = 4.5  # the three pilot runs' share of the pod's life, counted from when it is up; FULL never shrinks it
FULL_MIN = 60  # FULL, the release model: its training run gets what is left after the arms, at most this
MIN_FULL_STEPS = 50
POD_HOURS = ARMS_HOURS + (FULL_MIN + EXAM_MIN) / 60  # the pod's self-destruct
USD_CAP = 5.0  # the whole pod with the backstop grace: a card dearer than ~$0.80/h gets fewer hours, FULL fewer steps


def log(msg):
    print(time.strftime("%F %T ") + msg, flush=True)


def pilot_start(since=None) -> float:
    if since is not None:
        return float(since)
    if not START_FILE.exists():
        raise SystemExit(f"no pilot start: pass --since EPOCH or write {START_FILE}")
    s = START_FILE.read_text().strip()
    try:
        return float(s.split()[0])
    except (ValueError, IndexError):
        pass
    for f in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M"):
        with contextlib.suppress(ValueError):
            return time.mktime(time.strptime(s, f))
    raise SystemExit(f"{START_FILE}: '{s}' is neither epoch seconds nor 'YYYY-MM-DD HH:MM[:SS]'")


# ---------------------------------------------------------------- clip selection
Clip = namedtuple("Clip", "stem vid ch mtime frames split height")


def clip_rows(dev_pct):
    """Collector clips train_e2e.py would read (yt_*.json), with the json's video id (a section's is
    <vid>__s<start ms>, its channel filed under that id) and the split train_e2e.py --dev-pct gives them
    (checkpoint_loop.clip_index)."""
    chans = exams.channel_map()
    out = []
    with os.scandir(cl.PUBLIC) as it:
        for e in it:
            n = e.name
            if not (n.startswith("yt_") and n.endswith(".json")) or n.endswith(".tmp.json"):
                continue
            try:
                meta = json.loads(Path(e.path).read_text())
            except (OSError, ValueError):
                continue
            stem = n[:-5]
            raw = str(meta.get("video_id") or stem.rsplit("__", 1)[0])
            vid = raw[3:] if raw.startswith("yt_") else raw
            ch = chans.get(vid)
            out.append(Clip(stem, vid, ch, e.stat().st_mtime, int(meta.get("frames") or 0),
                            split.split_for(f"ch:{ch}" if ch else f"yt:{raw}", dev_pct),
                            int(meta.get("src_height") or 0)))
    return out


def exam_clips():
    """(clip ids of every frozen exam, MuAViC valid/test video ids, heldout exam channels)."""
    ids, chans = set(), set()
    for m in cl.EXAMS_DIR.glob("*/manifest.json"):
        items = json.loads(m.read_text())["items"]
        ids |= {r["id"] for r in items}
        if m.parent.name == "heldout":
            chans |= {r["speaker"] for r in items}
    videos = set()
    if MUAVIC_SELECTION.exists():
        for x in MUAVIC_SELECTION.read_text().splitlines():
            if x.strip():
                r = json.loads(x)
                if r.get("split") in ("valid", "test"):
                    videos.add(r["video_id"])
    return ids, videos, chans


def candidates(since, dev_pct):
    """Pilot clips train_e2e.py would keep: after the start, mp4 + txt present, 10-200 frames, a 720p source when the
    json says, not an exam clip, not from a MuAViC valid/test video, not saying one of the owner's test phrases
    (R10). Returns (clips, how many were dropped for a low source)."""
    ids, videos, _ = exam_clips()
    test = {metrics.normalize(exams.read_text(t)) for t in CLIPS.glob("*.txt")}
    out, low = [], 0
    for c in clip_rows(dev_pct):
        if (c.mtime <= since or c.stem in ids or re.sub(r"__s\d+$", "", c.vid) in videos
                or not MIN_FRAMES <= c.frames <= MAX_FRAMES):
            continue
        if c.height and c.height < MIN_HEIGHT:
            low += 1
            continue
        txt = cl.PUBLIC / f"{c.stem}.txt"
        if not (txt.exists() and (cl.PUBLIC / f"{c.stem}.mp4").exists()):
            continue
        text = exams.read_text(txt)
        if text and metrics.normalize(text) not in test:
            out.append(c)
    return out, low


def hours(clips):
    return sum(c.frames for c in clips) / 25 / 3600


def narrow_like(new, pool):
    """NARROW: as many clips as NEW from the channels of `pool`, an equal share each. NEW's clips sorted by length are
    dealt to the channels in turn and each channel takes its unused clip nearest in length; then swaps within a channel
    bring the hours to within 1% of NEW's where spare clips allow."""
    by = {}
    for c in sorted(pool, key=lambda c: (c.frames, c.stem)):
        by.setdefault(c.ch, []).append(c)
    keys = sorted(by)
    spare = {k: (v, [c.frames for c in v]) for k, v in by.items()}
    sel = {k: [] for k in keys}
    for i, f in enumerate(sorted(c.frames for c in new)):
        k = keys[i % len(keys)]
        v, lens = spare[k]
        j = bisect.bisect_left(lens, f)
        if j == len(lens) or (j > 0 and f - lens[j - 1] <= lens[j] - f):
            j -= 1
        bisect.insort(sel[k], (lens.pop(j), v.pop(j).stem))
    target, got = sum(c.frames for c in new), sum(f for v in sel.values() for f, _ in v)
    clip = {c.stem: c for c in pool}
    while abs(got - target) > 0.01 * target:
        best = None
        for k in keys:  # longer clips in for a deficit, shorter ones for an excess
            v, lens = spare[k]
            if not lens or not sel[k]:
                continue
            out_i, in_i = (0, len(lens) - 1) if got < target else (len(sel[k]) - 1, 0)
            after = got - sel[k][out_i][0] + lens[in_i]
            if best is None or abs(after - target) < best[0]:
                best = (abs(after - target), k, out_i, in_i, after)
        if best is None or best[0] >= abs(got - target):
            break
        _, k, out_i, in_i, got = best
        v, lens = spare[k]
        f, stem = sel[k].pop(out_i)
        bisect.insort(sel[k], (lens.pop(in_i), v.pop(in_i).stem))
        j = bisect.bisect_left(lens, f)
        lens.insert(j, f)
        v.insert(j, clip[stem])
    return [clip[s] for k in keys for _, s in sel[k]]


def describe(clips):
    cnt = Counter(c.ch for c in clips)
    n = max(1, len(clips))
    return dict(clips=len(clips), hours=round(hours(clips), 3), channels=len(cnt),
                mean_s=round(sum(c.frames for c in clips) / n / 25, 2),
                top=[(ch, round(k / n, 3)) for ch, k in cnt.most_common(NARROW_CHANNELS)],
                max_share=max(cnt.values(), default=0) / n)


def select(since, max_clips=0, dev_pct=DEV_PCT):
    """NEW, NARROW and dev from the pilot clips. Refuses what train_e2e.py would refuse on the pod after the pod is
    paid for (R1, R2) and arms too small to answer the question."""
    rows, low = candidates(since, dev_pct)
    since_s = time.strftime("%F %T", time.localtime(since))
    train = [c for c in rows if c.split == "train" and c.ch]
    by = Counter(c.ch for c in train)
    if len(by) < MIN_CHANNELS:
        raise SystemExit(f"[pilot] {len(by)} channels of train clips since {since_s} ({len(train)} clips, "
                         f"{hours(train):.2f} h; {low} dropped for a source below {MIN_HEIGHT}p): NEW needs >= "
                         f"{MIN_CHANNELS}")
    top = [ch for ch, _ in by.most_common(NARROW_CHANNELS)]
    cap = int(NARROW_CHANNELS * by[top[-1]] * NARROW_SLACK)  # NARROW takes 1/5 of the clips from each channel
    stems = {c.stem: c for c in train}
    want = min(max_clips or len(train), cap)
    new = [stems[s] for s in cl.balance([(c.stem, c.ch, c.mtime) for c in train], want, SHARE)]
    d = describe(new)
    if d["channels"] < MIN_CHANNELS or d["hours"] < MIN_HOURS:
        why = (f"; NARROW's 5th channel {top[-1]} has {by[top[-1]]} clips, so both arms are cut to {cap}"
               if want == cap else "")
        raise SystemExit(f"[pilot] NEW since {since_s}: {d['clips']} clips, {d['hours']} h, {d['channels']} channels "
                         f"after the R1 balance{why}; the pilot needs >= {MIN_CHANNELS} channels and >= "
                         f"{MIN_HOURS} h")
    narrow = narrow_like(new, [c for c in train if c.ch in top])
    n = describe(narrow)
    if abs(n["hours"] - d["hours"]) > HOURS_TOL * d["hours"] or n["max_share"] > cl.MAX_SHARE:
        raise SystemExit(f"[pilot] NARROW from {', '.join(top)}: {n['hours']} h for NEW's {d['hours']} h "
                         f"(largest share {n['max_share']:.0%}): its channels lack clips of NEW's lengths; try "
                         f"--max-clips {int(len(new) * 0.8)}")
    dev, dev_ch = dev_clips(rows, dev_pct)
    full = [stems[s] for s in cl.balance([(c.stem, c.ch, c.mtime) for c in train], len(train), SHARE)]
    return dict(new=new, narrow=narrow, full=full), dev, low, dev_ch


def dev_clips(rows, dev_pct):
    """(dev stems, Counter of their channels): cl.DEV_CLIPS clips of held-out channels, outside the heldout exam
    where there are enough."""
    _, _, exam_ch = exam_clips()
    dev_pool = [(c.stem, c.ch, c.mtime) for c in rows if c.split == "dev"]
    dev = cl.balance([c for c in dev_pool if c[1] not in exam_ch], cl.DEV_CLIPS, 1.0)
    if len(dev) < cl.DEV_CLIPS:  # held-out channels outside the exam are few: other clips of exam channels
        taken = set(dev)
        dev += cl.balance([c for c in dev_pool if c[0] not in taken], cl.DEV_CLIPS - len(dev), 1.0)
    if len(dev) < 10:
        raise SystemExit(f"[R2] {len(dev)} held-out dev clips among the pilot clips at --dev-pct {dev_pct}; "
                         f"train_e2e.py needs >= 10")
    return dev, Counter(c.ch for c in rows if c.stem in set(dev))


def lines(stems):
    return "".join(f"{s}.{e}\n" for s in stems for e in ("mp4", "txt", "json"))


# ---------------------------------------------------------------- time budget
def budget(sps, overhead_s, exam_s, left_s, clips, runs=len(ARMS), max_run_s=None, min_steps=MIN_STEPS):
    """(steps, eval every, warmup, time guard in minutes) for each of `runs` runs: at most PASSES passes over the
    clips, and the runs plus one exam run each and the Mac's pull within left_s, a run at most max_run_s. sps:
    s/step without evaluations; overhead_s: one run's model load, data setup and two dev-loss evaluations (the smoke
    run's wall time minus its steps), so one evaluation takes at most half of it. Same numbers for every run."""
    dev_s = overhead_s / 2
    fixed = overhead_s + (EVALS + 1 - 2) * dev_s
    per_run = (left_s - runs * exam_s - PULL_S) / runs
    if max_run_s:
        per_run = min(per_run, max_run_s)
    by_time = int((per_run - fixed) / sps)
    if by_time < min_steps:
        raise SystemExit(f"{by_time} steps per run fit in {left_s:.0f} s left ({sps:.2f} s/step, exam run "
                         f"{exam_s:.0f} s, "
                         f"run overhead {overhead_s:.0f} s); at least {min_steps} needed")
    steps = min(int(PASSES * clips / CLIPS_PER_STEP), by_time)
    guard = math.ceil(1.25 * (steps * sps + (EVALS + 1) * dev_s) / 60) + 1  # a guard only: runs stop at `steps`
    return steps, -(-steps // EVALS), max(5, steps // 10), guard


def smoke_speed(text):
    """(s/step over steps 11-30, wall seconds of the 30 steps) from the R4 smoke run's log."""
    t = {int(s): float(v) for s, v in re.findall(r"step (\d+)/\d+ loss \S+ ([\d.]+) s/step", text)}
    sps = (30 * t[30] - 10 * t[10]) / 20  # without the data loaders' start-up in the first steps
    return (sps if sps > 0 else t[30]), 30 * t[30]


def cmd_steps(a):
    """pilot_train.sh: prints `steps eval_every warmup guard_min` from the pod's measurements; for --full `0 0 0 0`
    when FULL does not fit (it is skipped, the arms are never shortened for it)."""
    sps, train_s = smoke_speed(Path(a.smoke_log).read_text())
    overhead = max(0.0, a.smoke_s - train_s)
    what = "FULL" if a.full else "NEW"
    try:
        s = budget(sps, overhead, a.exam_s, a.left, a.clips, *((1, FULL_MIN * 60, MIN_FULL_STEPS) if a.full else ()))
    except SystemExit as e:
        if not a.full:
            raise
        print(f"FULL skipped: {e}", file=sys.stderr)
        print(0, 0, 0, 0)
        return
    print(f"{what}: {sps:.2f} s/step, run overhead {overhead:.0f} s, exam run {a.exam_s:.0f} s, {a.left:.0f} s left: "
          f"{s[0]} steps ({s[0] * CLIPS_PER_STEP / a.clips:.1f} passes over {a.clips} {what} clips)", file=sys.stderr)
    print(*s)


def pod_hours(rate):
    """The pod's life at its $/h: POD_HOURS, or less where that plus the backstop grace would pass USD_CAP."""
    return min(POD_HOURS, USD_CAP / rate - BACKSTOP_H)


def estimate(clips, full_clips, sps, rate=cl.MAX_PRICE):
    """(arm steps, FULL steps, pod hours, $) the plan expects at a guessed speed and price; the hours run from the
    pod being up to the last pull (it self-destructs later only if the Mac is gone)."""
    up = 10 * 60  # uploads before the pod script starts
    exam_s = EXAM_MIN * 60
    smoke_s = OVERHEAD_S + 30 * sps
    t = SETUP_MIN * 60 + smoke_s + exam_s
    try:
        steps = budget(sps, OVERHEAD_S, exam_s, ARMS_HOURS * 3600 - DEADLINE_TAIL_S - up - t, clips)[0]
    except SystemExit:
        return 0, 0, pod_hours(rate), round(pod_hours(rate) * rate, 2)
    t += len(ARMS) * (OVERHEAD_S * (EVALS + 1) / 2 + steps * sps + exam_s)
    try:
        full = budget(sps, OVERHEAD_S, exam_s, pod_hours(rate) * 3600 - DEADLINE_TAIL_S - up - t, full_clips, 1,
                      FULL_MIN * 60, MIN_FULL_STEPS)[0]
        t += OVERHEAD_S * (EVALS + 1) / 2 + full * sps + exam_s
    except SystemExit:
        full = 0
    h = round((up + t + PULL_S) / 3600, 2)
    return steps, full, h, round(h * rate, 2)


def plan(since=None, max_clips=0, dev_pct=DEV_PCT):
    """Selects, writes harvester/pilot/{new,narrow,pool}.txt and plan.json, prints the plan."""
    since = pilot_start(since)
    sets, dev, low, dev_ch = select(since, max_clips, dev_pct)
    LISTS.mkdir(parents=True, exist_ok=True)
    for name, s in sets.items():
        (LISTS / f"{name}.txt").write_text(lines([c.stem for c in s] + dev))
    (LISTS / "pool.txt").write_text(lines(sorted({c.stem for s in sets.values() for c in s} | set(dev))))
    n_new, n_full = len(sets["new"]), len(sets["full"])
    est = {g: estimate(n_new, n_full, sps) for g, (_, sps) in cl.GPUS.items()}
    worst_h = pod_hours(cl.MAX_PRICE)
    p = dict(created=time.strftime("%F %T"), since=since, since_str=time.strftime("%F %T", time.localtime(since)),
             sets={k: {x: v for x, v in describe(s).items() if x != "max_share"} for k, s in sets.items()},
             dev=len(dev), dev_pct=dev_pct, dev_channels=dict(dev_ch.most_common()), low_source=low, init=rel(INIT),
             new_clips=n_new, full_clips=n_full, estimate=est,
             est_usd=max(e[3] for e in est.values()), worst_usd=round(worst_h * cl.MAX_PRICE, 2),
             backstop_usd=round((worst_h + BACKSTOP_H) * cl.MAX_PRICE, 2))
    (LISTS / "plan.json").write_text(json.dumps(p, ensure_ascii=False, indent=1))
    print(f"pilot start {p['since_str']}; {low} pilot clips dropped for a source below {MIN_HEIGHT}p")
    for name, d in p["sets"].items():
        top = ", ".join(f"{c} {s:.0%}" for c, s in d["top"])
        print(f"  {name.upper():7s} {d['clips']:6d} clips {d['hours']:6.2f} h {d['channels']:4d} channels, "
              f"mean {d['mean_s']} s; top: {top}")
    print(f"  dev     {len(dev):6d} clips of {len(dev_ch)} held-out pilot channels (--dev-pct {dev_pct}), the same for "
          f"every run: " + ", ".join(f"{c or 'no channel'} {k}" for c, k in dev_ch.most_common()) + "\n"
          f"trainer pod {TRAINER}: the cheapest of {', '.join(g.split()[-1] for g in cl.GPUS)} at <= "
          f"${cl.MAX_PRICE}/h, self-destruct {POD_HOURS:g} h after it is up (fewer on a card dearer than "
          f"${USD_CAP / (POD_HOURS + BACKSTOP_H):.2f}/h: the pod stays <= ${USD_CAP:g} with the backstop)\n"
          f"  from {p['init']}: R4 smoke run, exams ({EXAMS}) of init, then new (seed 0), narrow0 (seed 0), "
          f"narrow1 (seed 1) with "
          f"the same steps (<= {PASSES} passes over NEW = {PASSES * n_new // CLIPS_PER_STEP}; the pod measures its "
          f"speed and fits them in {ARMS_HOURS:g} h), batch 4 x accum 8, each final step examined\n"
          f"  then FULL, the release model: every pilot clip (R1), <= {PASSES} passes and <= {FULL_MIN} min in what is "
          f"left, examined, last.pt + last_venc.pth pulled to {rel(OUT / 'checkpoints' / 'full')}/; "
          f"not in the verdict\n"
          f"  guess at ${cl.MAX_PRICE}/h: " + "; ".join(f"{g.split()[-1]} {s} steps per arm, FULL {f}, ~{h} h, ${u:.2f}"
                                                   for g, (s, f, h, u) in est.items()) + "\n"
          f"  expected <= ${p['est_usd']:.2f}; worst case {worst_h:.2f} h = ${p['worst_usd']:.2f} (self-destruct), "
          f"${p['backstop_usd']:.2f} if that fails too (backstop)\n"
          f"lists: {rel(LISTS)}/{{new,narrow,full,pool}}.txt; start `run` under `caffeinate -i`")
    if any(e[0] == 0 for e in est.values()):
        print("WARNING: on " + ", ".join(g for g, e in est.items() if e[0] == 0) + f" fewer than {MIN_STEPS} steps "
              f"fit at the guessed speed; the pod refuses after its smoke run if the measured speed agrees")
    if not (cl.EXAMS_DIR / exams.MAIN / "manifest.json").exists():
        print(f"WARNING: the MuAViC exam is not frozen ({rel(cl.EXAMS_DIR / exams.MAIN)}): `run` refuses until "
              f"exams.py freeze has frozen it")
    return p


def rel(p: Path) -> str:
    return str(p.relative_to(ROOT)) if ROOT in p.parents else str(p)


# ---------------------------------------------------------------- the pod
def run(since=None, max_clips=0, dev_pct=DEV_PCT, pod_factory=None, poll=60):
    p = plan(since, max_clips, dev_pct)
    if not (cl.EXAMS_DIR / exams.MAIN / "manifest.json").exists():
        raise SystemExit("[R16] the MuAViC exam is not frozen: the pilot's verdict needs it (exams.py freeze)")
    if not INIT.exists():
        raise SystemExit(f"no init checkpoint {INIT}")
    preflight.require_no_hold()
    preflight.acquire_lock()
    if OUT.exists():  # R13: results of an earlier pilot must not be read as this one's
        old = OUT.with_name(f"{TRAINER}.{time.strftime('%Y%m%d-%H%M%S', time.localtime(OUT.stat().st_mtime))}")
        while old.exists():
            old = old.with_name(old.name + "+")
        OUT.rename(old)
    res = dict(started=time.strftime("%F %T"), ok=None, cost=None, gpu=None, hours=None, full=None)
    try:
        res["ok"] = run_pod(p, pod_factory or PilotPod, poll, res)
    except BaseException as e:
        res["ok"] = f"{type(e).__name__}: {e}"
    res["ended"] = time.strftime("%F %T")
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "pilot_run.json").write_text(json.dumps(res, indent=1))
    if res["ok"] is not True:
        raise SystemExit(f"pilot failed: {res['ok']}; ${res['cost']} spent; pod log {rel(OUT / 'pilot.log')}")
    v = decide()
    files = [OUT / "checkpoints" / "full" / f for f in FULL_FILES]
    if all(f.exists() for f in files):
        print("FULL (release model; lips_service.py --run expects them as best.pt and best_venc.pth):\n"
              + "\n".join(f"  {f}" for f in files))
    else:
        print(f"FULL: {res['full'] or 'not run'}; " + ", ".join(f"{f} missing" for f in files if not f.exists()))
    return v


FULL_FILES = ("last.pt", "last_venc.pth")


class PilotPod(cl.Pod):
    def pull(self, src, dst):
        """Pod.pull with rsync's exit code returned and logged: a failed pull must not pass for a missing result."""
        Path(dst).mkdir(parents=True, exist_ok=True)
        r = subprocess.run(["rsync", "-a", "--timeout=300", "-e", self._e(), f"root@{self.st['host']}:{src}",
                            str(dst)], capture_output=True, text=True)
        if r.returncode:
            log(f"{self.name}: pull {src}: rsync exit {r.returncode}: {r.stderr.strip()[-300:]}")
        return r.returncode

    def rate(self):
        return self.st["rate"]

    def shorten(self, end):
        """The backstop timer (armed by attach for POD_HOURS) and the state file to the deadline `end`."""
        left = int(end - time.time() + BACKSTOP_H * 3600)
        self.ssh("ps -eo pid,args | awk '$2 == \"bash\" && $3 == \"/root/backstop.sh\" {print $1}' | xargs -r kill; "
                 f"setsid nohup bash /root/backstop.sh {left} >> /root/backstop.log 2>&1 < /dev/null &")
        self.st["deadline"] = end
        self.h.save_state(self.st)


POLL = ("cd /root/lr && ls PILOT_DONE PILOT_FAILED ARMS_DONE FULL_SKIPPED 2>/dev/null; "
        "echo \"@exams $(ls results/exams 2>/dev/null | tr '\\n' ' ')\"; tail -1 pilot.log")


def run_pod(p, pod_factory, poll, res):
    """True or the reason it failed. res gets the GPU, the pod's hours and cost and what became of FULL. Exam results
    are pulled as they appear and once more before the pod is deleted, which happens in any case. A FULL that fails
    after the three arms finished costs the pilot nothing: their results stand."""
    pod = pod_factory(TRAINER)
    up, want, full = False, set(), False
    try:
        res["gpu"] = gpu = pod.attach(POD_HOURS)
        up, t_up = True, time.time()
        res["hours"] = hours = pod_hours(pod.rate())
        end = t_up + hours * 3600
        if hours < POD_HOURS:
            pod.shorten(end)
            log(f"{TRAINER}: ${pod.rate()}/h: {hours:.2f} h of pod keep it within ${USD_CAP:g} with the backstop")
        chunk = 2 if cl.GPUS.get(gpu, (24, 0))[0] < 32 else 4  # 50-frame pieces per VTP call: 8 needs ~45 GB
        pod.ssh("mkdir -p /root/lr/data/pool /root/lr/data/exams /root/lr/results/exams /root/lr/checkpoints/init "
                "/root/lr/harvester/pod /root/lr/lists && rm -f /root/lr/PILOT_DONE /root/lr/PILOT_FAILED "
                "/root/lr/ARMS_DONE /root/lr/FULL_SKIPPED")
        for c in CODE:
            pod.push(ROOT / c, "/root/lr/" + str(Path(c).parent) + "/")
        pod.push(str(cl.PUBLIC) + "/", "/root/lr/data/pool/", files_from=LISTS / "pool.txt")
        for name in ("new", "narrow", "full"):
            pod.push(LISTS / f"{name}.txt", f"/root/lr/lists/pilot_{name}.txt")
        pod.push(str(cl.EXAMS_DIR) + "/", "/root/lr/data/exams/")
        pod.push(str(CLIPS) + "/", "/root/lr/clips/", only="*.txt")
        pod.push(INIT, "/root/lr/checkpoints/init/pilot.pt")
        # the pod's own timer ends its work so that deadline.sh's tail still falls before `end`; the arms get the
        # life they had before FULL existed
        life = int(end - DEADLINE_TAIL_S - time.time())
        arms = int(t_up + ARMS_HOURS * 3600 - DEADLINE_TAIL_S - time.time())
        pod.ssh(f"cd /root/lr || exit 1; setsid nohup bash harvester/pod/pilot_train.sh {life} {arms} "
                f"checkpoints/init/pilot.pt {chunk} {p['new_clips']} {p['full_clips']} {p['dev_pct']} {EXAMS} > /root/lr/pilot.log 2>&1 "
                f"< /dev/null &")
        lost, last, listed = 0, None, None
        while True:
            time.sleep(poll)
            r = pod.ssh(POLL, check=False)
            got = next((x[len("@exams "):].split() for x in r.stdout.splitlines() if x.startswith("@exams ")), None)
            if got is not None and got != listed:  # a new exam result: pulled now, the pod may not answer later
                listed = got
                want = {f for f in got if f.startswith("pilot_") and f.endswith(".json")}
                fetch(pod, want, tries=1)
            if "PILOT_FAILED" in r.stdout or "PILOT_DONE" in r.stdout:
                break
            lost = lost + 1 if r.returncode == 255 else 0
            if lost >= 10:
                return "the pod stopped answering"
            if time.time() > end - GIVE_UP_S:
                return f"no result within {hours:.2f} h"
            tail = r.stdout.strip().splitlines()[-1:] if r.stdout.strip() else []
            if tail and tail != last:
                log(f"{TRAINER}: {tail[0][-200:]}")
                last = tail
        want = {f"pilot_{n}.json" for n in ("init",) + ARMS}
        if "PILOT_DONE" in r.stdout:
            full = "FULL_SKIPPED" not in r.stdout
            res["full"] = "done" if full else "skipped: no time left after the arms (pilot.log)"
            want |= {"pilot_full.json"} if full else set()
            return True
        if "ARMS_DONE" in r.stdout:
            res["full"] = "failed (pilot.log, logs/pilot_full.log)"
            return True
        return "the pod reported PILOT_FAILED"
    finally:
        if up:
            with contextlib.suppress(Exception):
                fetch(pod, want, final=True, full=full)
        with contextlib.suppress(Exception):
            res["cost"] = pod.cost()
        pod.delete()


def fetch(pod, want=(), tries=3, final=False, full=False):
    """Pulls the exam results and logs, at the end FULL's last.pt and last_venc.pth too (new's last.pt when there is
    no FULL), until every one expected is here, at most `tries` times. Returns what is still missing."""
    files = {f"results/exams/{f}" for f in want} | ({f"checkpoints/full/{f}" for f in FULL_FILES} if full else set())
    for i in range(tries):
        rcs = [pod.pull("/root/lr/results/exams/", OUT / "results" / "exams"), pod.pull("/root/lr/logs/", OUT / "logs"),
               pod.pull("/root/lr/pilot.log", OUT)]
        if full:
            rcs += [pod.pull(f"/root/lr/checkpoints/pilot_full/{f}", OUT / "checkpoints" / "full") for f in FULL_FILES
                    if not (OUT / "checkpoints" / "full" / f).exists()]
        missing = sorted(f for f in files if not (OUT / f).exists())
        if not missing and not any(rcs):
            break
        log(f"{TRAINER}: pull {i + 1}/{tries}: " + (f"missing {', '.join(missing)}" if missing else "rsync failed"))
    if final and not full:
        pod.pull("/root/lr/checkpoints/pilot_new/last.pt", OUT / "checkpoints" / "pilot_new")
    return missing


# ---------------------------------------------------------------- decision
def compare(prev: dict, cur: dict) -> dict:
    """WER drop prev -> cur on every exam both ran: MuAViC by speaker, the others per clip."""
    out = {}
    for name in exams.ORDER:
        if name not in prev["exams"] or name not in cur["exams"]:
            continue
        if name == exams.MAIN:
            out[name] = exams.speaker_bootstrap(exams.per_clip_speaker(prev, name), exams.per_clip_speaker(cur, name))
        else:
            out[name] = exams.bootstrap(exams.per_clip(prev, [name]), exams.per_clip(cur, [name]))
    return out


PAIRS = (("new", "narrow0"), ("new", "narrow1"), ("new", "init"), ("narrow0", "init"), ("narrow1", "init"))


def run_log(text):
    """(steps planned, last step done, stopped by the time guard, best.pt's step or None) from a train_e2e.py log."""
    planned = re.findall(r"step \d+/(\d+) loss", text)
    done = re.findall(r"step (\d+) dev loss", text)  # train_e2e.py evaluates at the last step too
    best = re.findall(r"step (\d+) dev loss \S+ best", text)
    return (int(planned[-1]) if planned else None, int(done[-1]) if done else None, "time limit" in text,
            int(best[-1]) if best else None)


def veto(logs: dict):
    """Why the runs are not comparable, or None. logs: arm -> run_log() or None when the log is missing."""
    for arm in ARMS:
        if logs.get(arm) is None:
            return f"no training log of {arm}"
        planned, done, limited, _ = logs[arm]
        if limited:
            return f"{arm} stopped on its time guard at step {done}"
        if done is None or done != planned:
            return f"{arm} ended at step {done} of {planned}"
    if len({logs[a][1] for a in ARMS}) > 1:
        return "the runs differ in steps: " + ", ".join(f"{a} {logs[a][1]}" for a in ARMS)
    return None


def verdict(cmp: dict, logs: dict) -> dict:
    """cmp: {(run, baseline): compare(baseline, run)} for PAIRS."""
    why = veto(logs)
    if why:
        return dict(verdict="no verdict", why=why)
    b = [cmp[("new", n)].get(exams.MAIN) for n in ("narrow0", "narrow1")]
    if None in b:
        return dict(verdict="no evidence", why="the MuAViC exam is missing from a run")
    gap = min(x["gain"] for x in b)
    seed_gap = round(abs(b[0]["gain"] - b[1]["gain"]), 2)  # = |WER narrow0 - WER narrow1| on the same clips
    sig = all(x["significant"] for x in b)
    helps = sig and gap > seed_gap
    if helps:
        why = (f"new beats both narrow runs on MuAViC by >= {gap:.1f} points, more than the seeds differ "
               f"({seed_gap:.1f})")
    elif not sig:
        why = "new does not beat both narrow runs on MuAViC with the 95% interval above 0"
    else:
        why = f"new beats both narrow runs by {gap:.1f} points, no more than the seeds differ ({seed_gap:.1f})"
    return dict(verdict="diversity helps" if helps else "no evidence", why=why, gap=gap, seed_gap=seed_gap)


def decide():
    p = json.loads((LISTS / "plan.json").read_text())
    pr = OUT / "pilot_run.json"
    pod = json.loads(pr.read_text()) if pr.exists() else {}
    res = {}
    for name in ("init",) + ARMS:
        f = OUT / "results" / "exams" / f"pilot_{name}.json"
        if not f.exists():
            raise SystemExit(f"no exam result {f}")
        res[name] = json.loads(f.read_text())
    f = OUT / "results" / "exams" / "pilot_full.json"
    if f.exists():  # the release model: reported, not part of the verdict
        res["full"] = json.loads(f.read_text())
    logs = {}
    for arm in ARMS + ("full",):
        lg = OUT / "logs" / f"pilot_{arm}.log"
        logs[arm] = run_log(lg.read_text(errors="replace")) if lg.exists() else None
    cmp = {(a, b): compare(res[b], res[a]) for a, b in PAIRS + (("full", "init"),) if a in res}
    v = verdict(cmp, logs)
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(report(p, pod, res, cmp, logs, v))
    print(f"verdict: {v['verdict']} ({v['why']})")
    print(f"-> {rel(REPORT)}")
    return v


def report(p, pod, res, cmp, logs, v):
    w = [f"# Пилот: помогает ли разнообразие каналов\n",
         f"Записано {time.strftime('%F %T')}. Замеры (R13): " + ", ".join(
             f"{r} {res[r].get('time', '?')}" for r in res) + f"; init = `{p['init']}`, остальные = последний шаг "
         f"своего прогона (`checkpoints/pilot_<run>/last.pt` на поде). Под {pod.get('gpu') or '?'}, "
         f"{pod.get('hours') or '?'} ч срока, потрачено {exams.money(pod.get('cost'))}.\n",
         "## Данные\n",
         f"Только клипы пилота (после {p['since_str']}, 720p; {p['low_source']} отброшено за источник ниже 720p), "
         f"10–200 кадров, без клипов экзаменов. new: все каналы, ≤ 24% на канал. narrow: те же часы из 5 самых "
         f"больших каналов, ~20% каждый, длины клипов подобраны под new. dev ({p['dev']} клипов отложенных каналов "
         f"пилота) один на все прогоны и только для best.pt. full: все клипы пилота с потолком R1, модель для "
         f"выпуска, в вердикт не входит.\n",
         "| набор | клипы | часы | каналы | средний клип, с | крупнейшие каналы |", "|---|---|---|---|---|---|"]
    for name, d in p["sets"].items():
        w.append(f"| {name} | {d['clips']} | {d['hours']} | {d['channels']} | {d['mean_s']} | "
                 + ", ".join(f"{c} {s:.0%}" for c, s in d["top"]) + " |")
    w += ["", "## Обучение\n",
          "Три прогона от одного init, batch 4 × accum 8, одинаковое число шагов (`harvester/pod/pilot_train.sh`): "
          "new (seed 0), narrow0 (seed 0), narrow1 (seed 1, шум сида). На экзамен идёт последний шаг; шаг best.pt "
          "по dev-loss — только для сведения.\n",
          "| прогон | шагов план | сделано | проходов по new | стоп по времени | шаг best.pt |",
          "|---|---|---|---|---|---|"]
    for arm in ARMS + ("full",):
        if arm == "full" and logs.get(arm) is None:
            w.append(f"| full | — | — | — | — | — ({pod.get('full') or 'не запускался'}) |")
            continue
        planned, done, limited, best = logs.get(arm) or (None, None, False, None)
        n = p["full_clips"] if arm == "full" else p["new_clips"]
        passes = f"{done * cl.CLIPS_PER_STEP / n:.1f}" if done else "—"
        w.append(f"| {arm} | {planned or '—'} | {done or '—'} | {passes} | {'да' if limited else 'нет'} | "
                 f"{best if best is not None else 'нет (dev-loss не лучше шага 0)'} |")
    runs = ("init",) + ARMS + ("full",)
    w += ["", "## Экзамены, WER %\n", "| экзамен | " + " | ".join(runs) + " |", "|---|" + "---|" * len(runs)]
    for name in exams.ORDER:
        if any(name in res[r]["exams"] for r in res):
            w.append(f"| {name} | " + " | ".join(exams.fmt(res[r]["exams"].get(name)) if r in res else "—"
                                                 for r in runs) + " |")
    w += ["", "Δ = падение WER в пунктах (больше нуля = лучше), [95% интервал]. MuAViC: парный бутстреп по людям "
          f"({exams.SPEAKER_BOOT_REPS} повторов, клипы выбранных людей объединяются); остальные: парный бутстреп по "
          "клипам. sig = интервал выше 0.\n",
          "| экзамен | " + " | ".join(f"{a} vs {b}" for a, b in cmp) + " |", "|---|" + "---|" * len(cmp)]
    for name in exams.ORDER:
        row = [c.get(name) for c in cmp.values()]
        if any(b is not None for b in row):
            w.append(f"| {name} | " + " | ".join(exams.fmt_boot(b) for b in row) + " |")
    w += ["", "## Вердикт\n", f"**{v['verdict']}**: {v['why']}."]
    if v.get("seed_gap") is not None:
        w.append(f"\nРазрыв new − narrow (меньший из двух): {v['gap']:+.1f} п.; разница сидов |narrow0 − narrow1|: "
                 f"{v['seed_gap']:.1f} п.")
    return "\n".join(w) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("plan", "run"):
        s = sub.add_parser(name)
        s.add_argument("--since", type=float, default=None,
                       help=f"pilot start, epoch seconds (default: {START_FILE.name})")
        s.add_argument("--max-clips", type=int, default=0, help="at most N NEW clips (0 = what NARROW can match)")
        s.add_argument("--dev-pct", type=int, default=DEV_PCT,
                       help="train_e2e.py --dev-pct, here and on the pod: share of pilot channels held out for dev, %%")
    sub.add_parser("decide")
    s = sub.add_parser("steps", help="(pod, pilot_train.sh) steps per run from the smoke run and the exam time")
    s.add_argument("--smoke-log", required=True)
    s.add_argument("--smoke-s", type=float, required=True, help="wall seconds of the smoke run")
    s.add_argument("--exam-s", type=float, required=True, help="wall seconds of one exam run")
    s.add_argument("--left", type=float, required=True, help="seconds left before the pod's timer")
    s.add_argument("--clips", type=int, required=True, help="NEW clips, or FULL's")
    s.add_argument("--full", action="store_true", help="FULL: one run in what is left, at most FULL_MIN, or 0 0 0 0")
    a = ap.parse_args()
    if a.cmd == "plan":
        plan(a.since, a.max_clips, a.dev_pct)
    elif a.cmd == "run":
        run(a.since, a.max_clips, a.dev_pct)
    elif a.cmd == "steps":
        cmd_steps(a)
    else:
        decide()


if __name__ == "__main__":
    main()
