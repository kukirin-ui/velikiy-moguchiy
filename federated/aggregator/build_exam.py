"""Собрать скрытый экзамен из готовых признаков (на машине, где они посчитаны: под или сервер, не Mac автора).

  python -m aggregator.build_exam --manifest MANIFEST.jsonl --out DIR [--split test] [--limit 80] [--seed 0]

MANIFEST — строки формата lipread (id, text, feats, split, source, ...): признаки VTP (T, 512), посчитанные визуальной
частью lips-0.1, той же, что у клиентов. Берутся только строки source == "public" (например, тест MuAViC-ru или
каналы, отложенные под проверку, и не из пула заданий); записи автора проекта (silent, voiced) в экзамен не попадают
никогда, даже если окажутся в манифесте.
Результат загружается в закрытый датасет Hugging Face и в git не попадает:

  huggingface-cli upload --repo-type dataset --private <владелец>/<экзамен> DIR .
"""
from __future__ import annotations

import argparse
import hashlib
import json
import random
import shutil
import sys
from pathlib import Path

import numpy as np


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--split", default="test")
    ap.add_argument("--limit", type=int, default=80, help="клипов: на CPU раннера одна оценка ~1 с на клип")
    ap.add_argument("--seed", type=int, default=0)
    a = ap.parse_args(argv)
    rows = [json.loads(ln) for ln in Path(a.manifest).read_text(encoding="utf8").splitlines() if ln.strip()]
    rows = [r for r in rows if r.get("source") == "public" and r.get("split") == a.split and r.get("feats") and r.get("text")]
    random.Random(a.seed).shuffle(rows)
    out = Path(a.out)
    (out / "feats").mkdir(parents=True, exist_ok=True)
    lines = []
    for r in rows[:a.limit]:
        f = np.load(r["feats"], mmap_mode="r")
        if f.ndim != 2 or f.shape[1] != 512:
            continue
        cid = hashlib.sha256(r["id"].encode()).hexdigest()[:16]  # names of the source clips stay out of the exam
        shutil.copyfile(r["feats"], out / "feats" / f"{cid}.npy")
        lines.append(json.dumps({"id": cid, "text": r["text"], "feats": f"feats/{cid}.npy"}, ensure_ascii=False))
    (out / "exam.jsonl").write_text("\n".join(lines) + "\n", encoding="utf8")
    print(f"экзамен: {len(lines)} клипов в {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
