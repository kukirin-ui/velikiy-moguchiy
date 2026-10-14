"""Pick 200 train + 40 extra clips for the video-SFT probe: videos disjoint from the 50-clip test pool, <=6 s, >=4 words."""
import json, random, glob, collections, os, sys
sys.path.insert(0, os.path.dirname(__file__))
from common import *

ch = dict(l.split("\t")[:2] for l in open(ROOT / "harvester" / "video_channels.tsv").read().splitlines())
test = json.load(open(OUT / "clips_pool100.json"))
test_vids = {c["video"] for c in test}
rng = random.Random(11)
files = sorted(glob.glob(str(PUB / "*.json")))
rng.shuffle(files)
vids = collections.defaultdict(list)
for f in files:
    cid = Path(f).stem
    d = json.load(open(f))
    vid = d["video_id"]
    t = d["end"] - d["start"]
    if vid in test_vids or not vid.startswith("yt_") or not (2.5 <= t <= 6):
        continue
    txt = (PUB / f"{cid}.txt").read_text().strip()
    if len(txt.split()) < 4:
        continue
    vids[vid].append((cid, t, txt))
by_ch = collections.defaultdict(list)
for v, cl in vids.items():
    by_ch[ch.get(v.removeprefix("yt_"), "?")].append((v, cl))
caps = {}  # channel -> clip cap; filled locally, never published
rows = []
for c, lst in by_ch.items():
    if c not in caps:
        continue
    rng.shuffle(lst)
    take = []
    for v, cl in lst:
        take += [(c, v, *x) for x in cl[:3]]
        if len(take) >= caps[c]:
            break
    rows += take[: caps[c]]
rng.shuffle(rows)
json.dump([{"channel": c, "video": v, "id": cid, "dur": round(t, 2), "ref": txt} for c, v, cid, t, txt in rows],
          open(OUT / "ft_train_pool.json", "w"), ensure_ascii=False, indent=1)
print(len(rows), collections.Counter(r[0] for r in rows), len({r[1] for r in rows}), "videos")
