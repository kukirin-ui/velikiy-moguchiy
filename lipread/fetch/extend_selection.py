"""Расширение отбора: fetch/selection_ru_v1.jsonl (50 ч, <=20 клипов на ролик) -> fetch/selection_ru.jsonl.
Только train_major (val/test и ролики, где они встречаются, не берутся в новую часть). До 60 клипов на ролик.
Порядок: A) ролики прежнего отбора, которые ещё не докачаны (прежние клипы + добавленные), B) новые ролики
(разнообразие дикторов), C) добавки к прежним роликам, уже скачанным целиком. Готовые клипы (.json) run.py пропускает."""
import collections, json, random
from pathlib import Path
import numpy as np

ROOT = Path(__file__).resolve().parent.parent
PUB = ROOT / "data/public"
PER_VIDEO = 60
MAX_DUR = 3600

old = [json.loads(l) for l in open(ROOT / "fetch/selection_ru_v1.jsonl")]
old_vids = list(dict.fromkeys(r["video_id"] for r in old))
old_ids = {r["clip_id"] for r in old}
rows = [json.loads(l) for l in open(ROOT / "data/public_meta/ru.jsonl")]
heldout = {r["video_id"] for r in rows if r["split"] != "train_major"}
est = collections.defaultdict(float)
for r in rows:
    est[r["video_id"]] = max(est[r["video_id"]], (r["track_frame0"] + r["track_n"]) / 25)
byv = collections.defaultdict(list)
for r in rows:
    if r["split"] == "train_major" and est[r["video_id"]] <= MAX_DUR and 50 <= r["length"] <= 250 \
            and len(r["transcript"].split()) >= 3:
        byv[r["video_id"]].append(r)


def pick(v):
    c = sorted(byv[v], key=lambda r: r["t_start"])
    if len(c) > PER_VIDEO:
        idx = sorted(set(np.linspace(0, len(c) - 1, PER_VIDEO).round().astype(int).tolist()))
        c = [c[i] for i in idx]
    return c


def oid(r):
    return f"{r['video_id']}__{r['track']}_{r['start']:06d}"


def fully_done(v):
    return all((PUB / f"{oid(r)}.json").exists() for r in old if r["video_id"] == v)


A, C = [], []
oldrows = collections.defaultdict(list)
for r in old:
    oldrows[r["video_id"]].append(r)
for v in old_vids:
    full = pick(v)
    keep = {r["clip_id"] for r in oldrows[v]}
    extra = [r for r in full if r["clip_id"] not in keep]
    if all((PUB / f"{oid(r)}.json").exists() for r in oldrows[v]):
        C += extra
    else:
        A += oldrows[v] + extra
new_vids = sorted(v for v in byv if v not in set(old_vids) and v not in heldout)
random.Random(1).shuffle(new_vids)
B = [r for v in new_vids for r in pick(v)]
sel, cum = [], 0.0
for part, name in ((A, "A"), (B, "B"), (C, "C")):
    for r in part:
        cum += r["length"] / 90000
        sel.append({**r, "cum_h": round(cum, 3), "video_est_dur": round(est[r["video_id"]])})
    print(f"часть {name}: {len(part)} клипов, {len({r['video_id'] for r in part})} роликов, "
          f"{sum(r['length'] for r in part)/90000:.1f} ч")
tmp = ROOT / "fetch/selection_ru.jsonl.tmp"
with open(tmp, "w") as f:
    for r in sel:
        f.write(json.dumps(r, ensure_ascii=False) + "\n")
tmp.replace(ROOT / "fetch/selection_ru.jsonl")
print(f"selection_ru.jsonl: {len(sel)} клипов, {len({r['video_id'] for r in sel})} роликов, {cum:.1f} ч")
