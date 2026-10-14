"""Can our lip readers read the synthetic lips? WER of MultiVSR models on synthetic clips (SynthVSR fig. 3, 'Synth-Test').

Reference points on real held-out YouTube clips (results/pod_runs/t1/checkpoints/e2e_full/eval_wer.json, 300 clips):
base 81.7, e2e_full 62.8. Synthetic WER close to these means the lip motion carries the words about as well as real
video does; far above means the generator's lips say little and synthetic training would teach little.

  LIPREAD_MAC_OK=1 ./guarded.sh synth/vsr_check.py --clips data/synth/pilot --model base --model e2e_full
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
import memguard  # noqa: E402,F401  (before torch)
import argparse  # noqa: E402
import json  # noqa: E402
import time  # noqa: E402

import mvsr  # noqa: E402
from metrics import corpus_rates, normalize  # noqa: E402

T1 = ROOT / "results" / "pod_runs" / "t1" / "checkpoints"
MODELS = {
    "base": {},
    "e2e_full": dict(lora=str(T1 / "e2e_full" / "best.pt"), venc_ckpt=str(T1 / "e2e_full" / "best_venc.pth")),
    "me1": dict(lora=str(T1 / "me1" / "best.pt"), venc_ckpt=str(T1 / "me1" / "best_venc.pth")),
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--clips", required=True)
    ap.add_argument("--model", action="append", choices=sorted(MODELS), required=True)
    ap.add_argument("--device", default="auto")
    ap.add_argument("--beam", type=int, default=20)
    ap.add_argument("--out", default=str(ROOT / "results" / "synth"))
    a = ap.parse_args()
    clips = sorted(Path(a.clips).glob("synth_*.mp4"))
    res = {}
    for name in a.model:
        m = mvsr.MultiVSR(device=a.device, beam_size=a.beam, **MODELS[name])
        rows = []
        t0 = time.time()
        for c in clips:
            ref = (c.with_suffix(".txt")).read_text(encoding="utf8").strip()
            meta = json.loads(c.with_suffix(".json").read_text())
            hyp, sec = m.transcribe(str(c), "ru")
            rows.append(dict(clip=c.stem, corpus=meta["audio_corpus"], ref=ref, hyp=hyp))
            print(f"[{name}] {c.stem}: {ref}  ->  {hyp}", flush=True)
            memguard.mps_cleanup()
        out = dict(n=len(rows), sec=round(time.time() - t0))
        for corp in [None] + sorted({r["corpus"] for r in rows}):
            sel = [r for r in rows if corp is None or r["corpus"] == corp]
            wer, cer = corpus_rates([(r["ref"], r["hyp"]) for r in sel], norm=normalize)
            out["all" if corp is None else corp] = dict(n=len(sel), wer=round(wer * 100, 1), cer=round(cer * 100, 1))
        res[name] = dict(summary=out, rows=rows)
        print(f"SUMMARY {name} " + json.dumps(out, ensure_ascii=False), flush=True)
        del m
        memguard.mps_cleanup()
    Path(a.out).mkdir(parents=True, exist_ok=True)
    tag = Path(a.clips).name
    (Path(a.out) / f"vsr_{tag}.json").write_text(json.dumps(res, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
