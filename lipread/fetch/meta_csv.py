"""Шаг 1a: потоком читает CSV MultiVSR с Hugging Face и оставляет только строки language == ru.
Результат: data/public_meta/ru_csv.jsonl (clip_id=<video>/<track>, transcript, length, start, split)
Сами CSV на диск не сохраняются."""
import csv, io, json, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "data/public_meta/ru_csv.jsonl"
BASE = "https://huggingface.co/datasets/sindhuhegde/multivsr/resolve/main/"
SPLITS = ["train_major", "train_minor", "val_major", "val_minor", "test"]

OUT.parent.mkdir(parents=True, exist_ok=True)
n = 0
with open(OUT.with_suffix(".tmp"), "w") as fo:
    for sp in SPLITS:
        p = subprocess.Popen(["nice", "-n", "10", "curl", "-sSL", "--retry", "5", "--retry-delay", "5", BASE + sp + ".csv"],
                             stdout=subprocess.PIPE)
        rd = csv.DictReader(io.TextIOWrapper(p.stdout, encoding="utf-8", newline=""))
        k = tot = 0
        for r in rd:
            tot += 1
            if r["language"] == "ru":
                vid, trk = r["file_path"].split("/")
                fo.write(json.dumps({"clip_id": r["file_path"], "video_id": vid, "track": trk,
                                     "transcript": r["transcript"], "length": int(r["length"]),
                                     "start": int(r["start"]), "split": sp}, ensure_ascii=False) + "\n")
                k += 1
        p.wait()
        if p.returncode != 0:
            sys.exit(f"curl failed on {sp}: {p.returncode}")
        print(f"{sp}: rows={tot} ru={k}", flush=True)
        n += k
OUT.with_suffix(".tmp").rename(OUT)
print("total ru rows", n)
