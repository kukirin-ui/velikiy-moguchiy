"""Corpus WER per crop and a paired bootstrap by clip against the s3fd crop of the same model.

Usage: python results/framing/paired.py [DIR]   (DIR holds <model>_<crop>.json from evaluate.py; default: this folder)
"""
import json
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent.parent))
from metrics import normalize, wer_counts  # noqa: E402

CROPS = ["s3fd", "s3fd720", "fm720", "s3fd480", "s3fd360", "collector"]


def counts(path):
    return {r["id"]: wer_counts(normalize(r["ref"]), normalize(r["hyp"] or "")) for r in json.loads(path.read_text())}


def main():
    d = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE
    rng = np.random.default_rng(0)
    for model in ["base", "me1", "e2e_full"]:
        ref = d / f"{model}_s3fd.json"
        if not ref.exists():
            continue
        a = counts(ref)
        ids = sorted(a)
        ea = np.array([a[k][0] for k in ids], float)
        n = np.array([a[k][1] for k in ids], float)
        for crop in CROPS:
            p = d / f"{model}_{crop}.json"
            if not p.exists():
                continue
            b = counts(p)
            eb = np.array([b[k][0] for k in ids], float)
            idx = rng.integers(0, len(ids), (5000, len(ids)))
            bs = (eb[idx].sum(1) - ea[idx].sum(1)) / n[idx].sum(1)
            lo, hi = np.percentile(bs, [2.5, 97.5])
            print(f"{model:9s} {crop:10s} WER {eb.sum() / n.sum() * 100:5.1f}%   vs s3fd "
                  f"{(eb.sum() - ea.sum()) / n.sum() * 100:+5.1f}  [95% {lo * 100:+.1f} .. {hi * 100:+.1f}]")


if __name__ == "__main__":
    main()
