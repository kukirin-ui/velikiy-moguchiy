"""Шаги 1c+2: склеивает ru_csv.jsonl с треками лиц (data/public_meta/tracks) -> data/public_meta/ru.jsonl,
затем выбирает клипы -> fetch/selection_ru.jsonl.

ru.jsonl (строка на клип датасета): clip_id, video_id, track, split, start (кадров от начала трека), length (кадров),
  transcript, track_frame0 (кадр трека в видео 25 fps), track_n, t_start/t_end (секунды в видео),
  boxes = "tracks/<video_id>.npz:<track>_bbox" (int16 [n,4] x1,y1,x2,y2 в пикселях исходного видео).
Отбор: не test и не val, 2-10 с, >=3 слов, <=20 клипов на ролик (равномерно по ролику), ролики в случайном порядке
(seed 0) - любой префикс списка разнообразен. Отбирается ~RESERVE_H часов (запас на недоступные ролики);
поле cum_h - накопленные часы, скачивание останавливается на TARGET_H."""
import collections, json, random, sys
from pathlib import Path
import numpy as np

ROOT = Path(__file__).resolve().parent.parent
META = ROOT / "data/public_meta"
RESERVE_H = float(sys.argv[1]) if len(sys.argv) > 1 else 55.0
PER_VIDEO = 20

tracks = {}
for p in (META / "tracks").glob("*.npz"):
    if p.name.endswith(".tmp.npz"):
        continue
    z = np.load(p)
    d = {}
    for k in z.files:
        if k.endswith("_frame0"):
            t = k[:-7]
            d[t] = {"frame0": int(z[k]), "n": int(z[t + "_bbox"].shape[0])}
    tracks[p.stem] = d

rows, miss = [], 0
for l in open(META / "ru_csv.jsonl"):
    r = json.loads(l)
    t = tracks.get(r["video_id"], {}).get(r["track"])
    if t is None:
        miss += 1
        continue
    r.update(track_frame0=t["frame0"], track_n=t["n"],
             t_start=round((t["frame0"] + r["start"]) / 25, 3), t_end=round((t["frame0"] + r["start"] + r["length"]) / 25, 3),
             boxes=f"tracks/{r['video_id']}.npz:{r['track']}_bbox")
    if r["start"] + r["length"] > t["n"]:
        miss += 1
        continue
    rows.append(r)
with open(META / "ru.jsonl.tmp", "w") as f:
    for r in rows:
        f.write(json.dumps(r, ensure_ascii=False) + "\n")
(META / "ru.jsonl.tmp").rename(META / "ru.jsonl")

hours = collections.defaultdict(float); cnt = collections.Counter()
for r in rows:
    hours[r["split"]] += r["length"] / 25 / 3600; cnt[r["split"]] += 1
vids = {r["video_id"] for r in rows}
print(f"ru.jsonl: клипов {len(rows)} (без трека/выход за трек: {miss}), роликов {len(vids)}")
for s in hours:
    print(f"  {s}: {cnt[s]} клипов, {hours[s]:.1f} ч")
print(f"  всего {sum(hours.values()):.1f} ч")

est = collections.defaultdict(float)  # оценка длины ролика по концу последнего трека, с
for r in rows:
    est[r["video_id"]] = max(est[r["video_id"]], (r["track_frame0"] + r["track_n"]) / 25)
MAX_DUR = 3600  # длиннее часа не берём (скачивание ролика целиком дорого, дикторов не добавляет)
byv = collections.defaultdict(list)
for r in rows:
    if est[r["video_id"]] > MAX_DUR:
        continue
    if r["split"] == "train_major" and 50 <= r["length"] <= 250 and len(r["transcript"].split()) >= 3:
        byv[r["video_id"]].append(r)
order = sorted(byv)
random.Random(0).shuffle(order)
sel, cum = [], 0.0
for v in order:
    c = sorted(byv[v], key=lambda r: r["t_start"])
    if len(c) > PER_VIDEO:
        idx = np.linspace(0, len(c) - 1, PER_VIDEO).round().astype(int)
        c = [c[i] for i in sorted(set(idx.tolist()))]
    for r in c:
        cum += r["length"] / 25 / 3600
        sel.append({**r, "cum_h": round(cum, 3), "video_est_dur": round(est[v])})
    if cum >= RESERVE_H:
        break
with open(ROOT / "fetch/selection_ru.jsonl", "w") as f:
    for r in sel:
        f.write(json.dumps(r, ensure_ascii=False) + "\n")
nv = len({r["video_id"] for r in sel})
print(f"selection_ru.jsonl: {len(sel)} клипов, {nv} роликов, {cum:.1f} ч, средняя длина {cum*3600/len(sel):.1f} с")
