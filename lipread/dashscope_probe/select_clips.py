"""Pick evaluation clips: 1 clip per video, spread over videos and channels (per-channel caps), 3..8 s, >=4 words."""
import json, random, glob, collections, os, sys
sys.path.insert(0, os.path.dirname(__file__))
from common import *

ch = dict(l.split("\t")[:2] for l in open(ROOT / "harvester" / "video_channels.tsv").read().splitlines())
rng = random.Random(7)
vids = collections.defaultdict(list)
files = sorted(glob.glob(str(PUB / "*.json")))
rng.shuffle(files)
for f in files:
    cid = Path(f).stem
    try:
        d = json.load(open(f))
    except Exception:
        continue
    t = d["end"] - d["start"]
    vid = d["video_id"]
    if not (3 <= t <= 8):
        continue
    txt = (PUB / f"{cid}.txt").read_text().strip() if (PUB / f"{cid}.txt").exists() else ""
    if len(txt.split()) < 4 or d.get("src_height", 0) < 360:
        continue
    vids[vid].append((cid, t, txt))
print(len(vids), "videos")
by_ch = collections.defaultdict(list)
for v, cl in vids.items():
    by_ch[ch.get(v.removeprefix("yt_"), ch.get(v, "?"))].append((v, cl[0]))
print({k: len(v) for k, v in by_ch.items()})
caps = {}  # channel -> clip cap; filled locally, never published
pick = []
for c, lst in by_ch.items():
    rng.shuffle(lst)
    lst[:] = [x for x in lst if x[0].startswith("yt_")]
    pick += [(c, v, *cl) for v, cl in lst[:caps.get(c, 2)]]
rng.shuffle(pick)
pick = pick[:100]
json.dump([{"channel": c, "video": v, "id": cid, "dur": round(t, 2), "ref": txt} for c, v, cid, t, txt in pick],
          open(OUT / "clips_pool100.json", "w"), ensure_ascii=False, indent=1)
print(len(pick))
