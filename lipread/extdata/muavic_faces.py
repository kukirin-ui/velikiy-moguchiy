#!/usr/bin/env python3
"""Face size per MuAViC-ru segment from MuAViC's own landmark metadata, streamed (nothing is stored but the result).

  .venv/bin/python extdata/muavic_faces.py  ->  data/ext/muavic_ru/meta/face_meta.jsonl
One row per segment: id, frames, frames with landmarks, median landmark height (px, chin to brow, in MuAViC's own
download of the video), and the largest landmark x, y seen in the talk (a lower bound on that video's frame size).
"""
import json
import pickle
import tarfile
import urllib.request
from pathlib import Path

import numpy as np

URL = "https://dl.fbaipublicfiles.com/muavic/metadata/ru_metadata.tgz"
OUT = Path(__file__).resolve().parent.parent / "data" / "ext" / "muavic_ru" / "meta" / "face_meta.jsonl"

with open(OUT, "w") as out, tarfile.open(fileobj=urllib.request.urlopen(URL), mode="r|gz") as t:
    for m in t:
        if not (m.isfile() and m.name.endswith(".pkl")):
            continue
        split, vid = m.name.split("/")[1], Path(m.name).stem
        d = pickle.load(t.extractfile(m))
        rows, mx, my = [], 0.0, 0.0
        for sid, frames in d.items():
            hs = []
            for lm in frames or []:
                if lm is None:
                    continue
                a = np.asarray(lm, np.float32).reshape(-1, 2)
                hs.append(float(a[:, 1].max() - a[:, 1].min()))
                mx, my = max(mx, float(a[:, 0].max())), max(my, float(a[:, 1].max()))
            rows.append(dict(id=sid, video_id=vid, split=split, frames=len(frames or []), with_face=len(hs),
                             face_h_med=round(float(np.median(hs)), 1) if hs else None))
        for r in rows:
            out.write(json.dumps(dict(r, video_max_x=round(mx), video_max_y=round(my))) + "\n")
