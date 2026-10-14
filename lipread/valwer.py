"""Sidecar for the pod: validation WER/CER of LoRA checkpoints on held-out public clips (2% of videos by video_id).

Runs next to train: every --every seconds picks checkpoints/<run>/last.pt (if its step changed), merges the LoRA
into the base weights, beam-decodes N fixed dev clips from the cached VTP features (no video decoding) and appends a
line to <ckpt-dir>/<run>/val_wer.jsonl. Step 0 (no LoRA) is evaluated first. Exits when <run>/DONE exists.
"""
import memguard  # noqa: F401
import argparse
import json
import random
import time
from pathlib import Path

import numpy as np
import torch

import lora as L
import mvsr
from metrics import corpus_rates, normalize

ap = argparse.ArgumentParser()
ap.add_argument("--run", required=True)
ap.add_argument("--manifest", default="data/manifest.jsonl")
ap.add_argument("--ckpt-dir", default="checkpoints")
ap.add_argument("--n", type=int, default=200)
ap.add_argument("--beam", type=int, default=5)
ap.add_argument("--max-seconds", type=float, default=8.0)
ap.add_argument("--every", type=float, default=600)
ap.add_argument("--final", default=None, help="evaluate this checkpoint once and exit (e.g. best.pt)")
a = ap.parse_args()

rows = [json.loads(l) for l in open(a.manifest, encoding="utf8") if l.strip()]
dev = [r for r in rows if r["source"] == "public" and r["split"] == "dev" and 10 <= r["frames"] <= a.max_seconds * 25]
dev.sort(key=lambda r: r["id"])
random.Random(0).shuffle(dev)
dev = dev[:a.n]
print(f"val clips {len(dev)} ({sum(r['frames'] for r in dev) / 25 / 60:.1f} min), beam {a.beam}", flush=True)
feats = [torch.from_numpy(np.load(r["feats"]).astype(np.float32)) for r in dev]

m = mvsr.MultiVSR(device="cuda", fp16=True, beam_size=a.beam)
model, tok, search = m.model, m.tok, m.search
paths = [n for n, mod in model.named_modules() if type(mod).__name__ == "MultiHeadedAttention"]
orig = {}
for p in paths:
    mod = dict(model.named_modules())[p]
    for i in L.QV:
        orig[f"{p}.linears.{i}"] = mod.linears[i].weight.detach().clone()


def restore():
    mods = dict(model.named_modules())
    with torch.no_grad():
        for k, w in orig.items():
            mods[k].weight.copy_(w)


@torch.no_grad()
def decode(f):
    x = f.unsqueeze(0).cuda()
    mask = torch.ones(1, 1, x.shape[1]).long().cuda()
    enc, mask = model.encode(x, mask)
    start = [50258, tok.encode("<|ru|>")[0]]
    with torch.autocast("cuda", enabled=True):
        outs, _ = search.beam_search(model=model, bos_index=start, eos_index=tok.eot, max_output_length=100, pad_index=0,
                                     encoder_output=enc, src_mask=mask, size=a.beam, n_best=1)
    if not outs[0]:
        return ""
    pred = tok.decode(outs[0][0].cpu().numpy().tolist()[:-1]).strip().lower()
    pred = pred.replace("<|transcribe|><|notimestamps|>", " ")
    return pred[7:].strip()


def evaluate(tag, ckpt):
    restore()
    step = 0
    if ckpt is not None:
        ck = torch.load(ckpt, map_location="cpu", weights_only=False)
        L.merge_lora_into_base(model, ck)
        step = ck.get("step", 0)
    model.eval()
    t0 = time.time()
    pairs = [(r["text"], decode(f)) for r, f in zip(dev, feats)]
    wer, cer = corpus_rates(pairs, normalize)
    rec = dict(t=time.strftime("%F %T"), tag=tag, step=step, val_wer=round(wer * 100, 2), val_cer=round(cer * 100, 2),
               n=len(pairs), sec=round(time.time() - t0, 1), sample=[pairs[i] for i in (0, 1, 2)])
    print(json.dumps(rec, ensure_ascii=False), flush=True)
    with open(Path(a.ckpt_dir) / a.run / "val_wer.jsonl", "a", encoding="utf8") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    return step


(Path(a.ckpt_dir) / a.run).mkdir(parents=True, exist_ok=True)
if a.final:
    evaluate("final", a.final)
    raise SystemExit
evaluate("base", None)
last_step = -1
last_t = 0.0
while True:
    done = (Path(a.ckpt_dir) / a.run / "DONE").exists()
    ck = Path(a.ckpt_dir) / a.run / "last.pt"
    if ck.exists() and (done or time.time() - last_t >= a.every):
        try:
            peek = torch.load(ck, map_location="cpu", weights_only=False).get("step")
        except Exception as e:
            print("load failed, retry", e, flush=True)
            time.sleep(10)
            continue
        if peek != last_step:
            last_step = evaluate("ckpt", ck)
            last_t = time.time()
    if done:
        break
    time.sleep(20)
