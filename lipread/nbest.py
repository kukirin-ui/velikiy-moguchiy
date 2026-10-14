"""Шаг 0 плана, часть 1: n-best луча MultiVSR для всех клипов -> results/nbest.jsonl.

Один проход декодера на клип (луч 20, n_best 20), кропы лица берутся из кэша work/faces/. Батч 1, один
процесс. Ограничения памяти: PYTORCH_MPS_HIGH_WATERMARK_RATIO=0.35 (ставится здесь, если не задан),
перед каждым клипом проверка свободной памяти (< 25% -> стоп). В лог пишутся пики: RSS процесса и
память MPS-драйвера.

Запуск: ./run.sh nbest.py
"""
from __future__ import annotations

import argparse
import gc
import json
import os
import re
import resource
import subprocess
import sys
import time
from pathlib import Path

os.environ.setdefault("PYTORCH_MPS_HIGH_WATERMARK_RATIO", "0.35")
os.environ.setdefault("PYTORCH_MPS_LOW_WATERMARK_RATIO", "0.25")
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

ROOT = Path(__file__).resolve().parent


def free_pct() -> int:
    out = subprocess.run(["memory_pressure"], capture_output=True, text=True).stdout
    m = re.search(r"free percentage:\s*(\d+)%", out)
    return int(m.group(1)) if m else 100


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--clips", default=str(ROOT / "clips"))
    ap.add_argument("--faces", default=str(ROOT / "work" / "faces"))
    ap.add_argument("--out", default=str(ROOT / "results" / "nbest.jsonl"))
    ap.add_argument("--beam", type=int, default=20)
    ap.add_argument("--min-free", type=int, default=25, help="стоп, если свободной памяти меньше N%%")
    ap.add_argument("--limit", type=int, default=0)
    a = ap.parse_args()

    import torch
    from mvsr import MultiVSR

    clips = sorted(p for p in Path(a.clips).glob("*.mp4") if p.with_suffix(".txt").exists())
    if a.limit:
        clips = clips[:a.limit]
    f = free_pct()
    print(f"свободно памяти: {f}%", flush=True)
    if f < a.min_free:
        sys.exit(f"Свободной памяти {f}% < {a.min_free}%, не запускаю.")

    t0 = time.perf_counter()
    m = MultiVSR(device="mps", beam_size=a.beam)
    print(f"модели загружены за {time.perf_counter() - t0:.1f} с, устройство {m.device}", flush=True)
    peak_mps = peak_rss = 0.0
    min_free = f
    out_path = Path(a.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", encoding="utf-8") as fo:
        for c in clips:
            f = free_pct()
            min_free = min(min_free, f)
            if f < a.min_free:
                print(f"СТОП: свободной памяти {f}% < {a.min_free}%", flush=True)
                break
            cid = c.stem
            ref = c.with_suffix(".txt").read_text(encoding="utf-8").strip()
            face = Path(a.faces) / f"{cid}.avi"
            t1 = time.perf_counter()
            faces = m.load_faces(face)
            hyps = m.nbest_faces(faces, "ru")
            torch.mps.synchronize()
            sec = time.perf_counter() - t1
            mps = torch.mps.driver_allocated_memory() / 2**30
            nfr = int(faces.size(2))
            del faces
            gc.collect()
            torch.mps.empty_cache()  # кэш аллокатора растёт на клипах разной длины -> упирался в лимит
            rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 2**30  # на macOS в байтах
            peak_mps, peak_rss = max(peak_mps, mps), max(peak_rss, rss)
            fo.write(json.dumps(dict(id=cid, ref=ref, frames=nfr, sec=sec, hyps=hyps),
                                ensure_ascii=False) + "\n")
            fo.flush()
            print(f"{cid}: {len(hyps)} гипотез, {sec:.2f} с, MPS {mps:.2f} ГБ, RSS(пик) {rss:.2f} ГБ, "
                  f"свободно {f}%", flush=True)
    print(f"ПИК: MPS-драйвер {peak_mps:.2f} ГБ, RSS {peak_rss:.2f} ГБ, мин. свободно {min_free}%")
    print("HIGH_WATERMARK_RATIO =", os.environ.get("PYTORCH_MPS_HIGH_WATERMARK_RATIO"))


if __name__ == "__main__":
    main()
