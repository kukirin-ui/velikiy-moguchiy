#!/usr/bin/env python3
"""Примеры кадров: 6 принятых клипов (по одному кадру из середины, кроп 224x224) и 3 ролика, отбракованных по синхронности
(s6_sync/s7_video): 3 кадра из 30-секундной пробы с рамкой лица. Результат: /tmp/newdata_samples/*.png"""
import json, shutil, sqlite3, subprocess, sys, random
from pathlib import Path
import cv2, numpy as np
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import ytdl, vision as V
OUT = Path("/tmp/newdata_samples"); OUT.mkdir(exist_ok=True)
PUB = HERE.parent / "data" / "public_new"
db = sqlite3.connect(str(HERE / "state.db"))
# принятые
by_vid = {}
for j in sorted(PUB.glob("*.json")):
    d = json.loads(j.read_text()); by_vid.setdefault(d["video_id"], []).append((j.stem, d))
random.Random(1).seed(1)
picks = []
vids = list(by_vid)
random.Random(3).shuffle(vids)
for v in vids:
    picks.append(random.Random(5).choice(by_vid[v]))
    if len(picks) == 6: break
while len(picks) < 6 and vids:  # мало роликов: добираем из тех же
    v = vids[len(picks) % len(vids)]
    picks.append(random.Random(len(picks)).choice(by_vid[v]))
tiles = []
for cid, d in picks:
    mp4 = PUB / f"{cid}.mp4"
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", str(mp4), "-vf", "select=eq(n\\,%d)" % (d["frames"] // 2), "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "bgr24", "-"], capture_output=True).stdout
    img = np.frombuffer(raw, np.uint8).reshape(224, 224, 3).copy()
    txt = (PUB / f"{cid}.txt").read_text().strip()
    cv2.putText(img, f"r={d['scores']['sync_r']}", (4, 14), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (0, 255, 255), 1)
    tiles.append(img)
    print("ACCEPTED", cid, d["scores"], "|", txt[:90])
if tiles:
    cv2.imwrite(str(OUT / "accepted.png"), np.hstack(tiles[:3]) if len(tiles) < 4 else np.vstack([np.hstack(tiles[:3]), np.hstack(tiles[3:6])]))
# отбракованные по синхронности
rows = db.execute("SELECT video_id, stage, reason, probe FROM videos WHERE stage IN ('s6_sync','s7_video') AND reason IN ('low_sync') ORDER BY RANDOM() LIMIT 3").fetchall()
for k, (vid, stage, reason, probe) in enumerate(rows):
    info, kind, err = ytdl.yt_info(vid)
    if not info: print("no info", vid); continue
    vf, af = ytdl.pick_formats(info)
    d = OUT / f"rej_{vid}.mkv"
    ok, kind, err = ytdl.download_probe(info, vf, af, max(0, info["duration"] / 2 - 15), 30, d)
    if not ok: print("probe fail", vid, err); continue
    frames = V.decode_frames(d, 5, 20, out_h=360)
    ff = V.FaceFeat(2); tl = []
    for i in (50, 200, 350):
        r = ff.step(frames[i - 1]); r = ff.step(frames[i])
        im = cv2.cvtColor(frames[i], cv2.COLOR_RGB2BGR).copy()
        if r["face"]:
            cv2.rectangle(im, (int(r["x0"]), int(r["y0"])), (int(r["x1"]), int(r["y1"])), (0, 255, 0), 2)
        tl.append(cv2.resize(im, (480, int(480 * im.shape[0] / im.shape[1]))))
    cv2.imwrite(str(OUT / f"rejected_sync_{k}_{vid}.png"), np.hstack(tl))
    print("REJECTED", vid, stage, reason, info["title"][:80], (probe or "")[:300])
    d.unlink(missing_ok=True)
