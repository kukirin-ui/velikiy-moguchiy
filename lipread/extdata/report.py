#!/usr/bin/env python3
"""What extdata/pod_segments.py made of each dataset: segments seen, kept, kept hours and speakers, top reasons.

  python3 extdata/report.py [data/ext]
"""
import collections
import json
import sys
from pathlib import Path

ext = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent / "data" / "ext"
for ds in sorted(p for p in ext.iterdir() if (p / "selection.jsonl").exists()):
    kept, sec, spk = 0, 0.0, set()
    for js in ds.glob("*/yt_*.json"):
        try:
            d = json.loads(js.read_text())
        except (OSError, ValueError):
            continue
        kept += 1
        sec += d.get("frames", 0) / 25
        spk.add(d.get("speaker"))
    why = collections.Counter()
    rej = ds / "rejects.jsonl"
    if rej.exists():
        for line in rej.read_text().splitlines():
            why[json.loads(line)["reason"]] += 1
    seen = kept + sum(why.values())
    top = ", ".join(f"{k} {v}" for k, v in why.most_common(4))
    print(f"{ds.name}: seen {seen}, kept {kept} ({sec / 3600:.2f} h, {len(spk)} speakers); rejected: {top or '-'}")
