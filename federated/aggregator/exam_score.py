"""WER адаптеров LoRA на скрытом экзамене (готовые признаки VTP). Запускается в окружении с torch и кодом MultiVSR:

  python exam_score.py --exam DIR --lipread ../lipread [--beam 4] [--limit N] --out scores.json A.safetensors [B ...]

Пишет {"<путь адаптера>": {"wer", "cer", "n"}}. Печатает только ход работы и итоговые числа, без текстов экзамена.
Базовая модель (lipread/weights/model.pth) грузится один раз; каждый адаптер вливается в веса и после оценки
вычитается обратно из сохранённой копии, поэтому порядок адаптеров на результат не влияет.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--exam", required=True)
    ap.add_argument("--lipread", required=True)
    ap.add_argument("--alpha", type=float, default=32.0)
    ap.add_argument("--rank", type=int, default=16)
    ap.add_argument("--beam", type=int, default=4)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--out", required=True)
    ap.add_argument("adapters", nargs="+")
    a = ap.parse_args()

    sys.path.insert(0, str(Path(a.lipread).resolve()))
    import numpy as np
    import torch
    from safetensors.numpy import load_file

    import metrics
    import mvsr

    torch.set_num_threads(os.cpu_count() or 2)
    exam = Path(a.exam)
    rows = [json.loads(ln) for ln in (exam / "exam.jsonl").read_text(encoding="utf8").splitlines() if ln.strip()]
    if a.limit:
        rows = rows[:a.limit]
    feats = [np.load(exam / r["feats"]).astype(np.float32) for r in rows]
    print(f"экзамен: {len(rows)} клипов", flush=True)

    mv = mvsr._multivsr()
    mv["models"].set_amp("cpu", False)
    model = mv["models"].build_model()
    # weights_only only: no fallback that would run code from the checkpoint (its SHA-256 is checked by the workflow)
    sd = torch.load(mvsr.DEFAULT_CKPT, map_location="cpu", weights_only=True, mmap=True)["state_dict"]
    model.load_state_dict({(k[7:] if k.startswith("module.") else k): v for k, v in sd.items()})
    del sd
    model.eval()

    def decode_last(memory, src_mask, tgt, tgt_mask):
        return model.generator(model.decoder(model.tgt_embed(tgt), memory, src_mask, tgt_mask)[:, -1:])
    model.decode = decode_last  # beam search reads only the last position; the full projection is wasted on CPU

    tok, search = mv["tokenizer"], mv["search"]
    start = [50258, tok.encode("<|ru|>")[0]]
    modules = dict(model.named_modules())
    scale = a.alpha / a.rank

    @torch.inference_mode()
    def transcribe(f: np.ndarray) -> str:
        preds = []
        for i in range(0, f.shape[0], 14 * 25):
            x = torch.from_numpy(f[i:i + 14 * 25])[None]
            src_mask = torch.ones(1, 1, x.shape[1]).long()
            enc, src_mask = model.encode(x, src_mask)
            outs, _ = search.beam_search(model=model, bos_index=start, eos_index=tok.eot, max_output_length=100,
                                         pad_index=0, encoder_output=enc, src_mask=src_mask, size=a.beam, n_best=1)
            if not outs[0]:
                continue
            pred = tok.decode(outs[0][0].numpy().tolist()[:-1]).strip().lower()
            preds.append(pred.replace("<|transcribe|><|notimestamps|>", " ")[7:].strip())
        return " ".join(preds).strip()

    results = {}
    for path in a.adapters:
        t0 = time.perf_counter()
        flat = load_file(path)
        pairs: dict[str, dict] = {}
        for k, v in flat.items():
            mod, _, ab = k.rpartition(".")
            pairs.setdefault(mod, {})[ab] = torch.from_numpy(v).float()
        saved = {}
        with torch.no_grad():
            for mod, ab in pairs.items():
                lin = modules[mod]
                saved[mod] = lin.weight.detach().clone()
                lin.weight.add_((ab["B"] @ ab["A"]) * scale)
        try:
            hyps = [transcribe(f) for f in feats]
        finally:
            with torch.no_grad():
                for mod, w in saved.items():
                    modules[mod].weight.copy_(w)
        wer, cer = metrics.corpus_rates([(r["text"], h) for r, h in zip(rows, hyps)])
        results[path] = {"wer": float(wer), "cer": float(cer), "n": len(rows)}
        print(f"{Path(path).name}: WER {wer * 100:.2f}% CER {cer * 100:.2f}% ({time.perf_counter() - t0:.0f} с)", flush=True)
    Path(a.out).write_text(json.dumps(results))
    return 0


if __name__ == "__main__":
    sys.exit(main())
