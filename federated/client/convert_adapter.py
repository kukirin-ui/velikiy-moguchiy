"""Конвертер формата адаптера (запускается окружением lipread, где есть torch; без импортов проекта).

  python convert_adapter.py to-pt  in.safetensors out.pt  [--alpha 32] [--target-format norm]
  python convert_adapter.py from-pt in.pt out.safetensors

safetensors: ключи "<путь модуля>.A" / "<путь модуля>.B" (fp32). .pt (формат lipread/train.py):
{"lora": {путь: {"A": тензор, "B": тензор}}, "config": {"r", "alpha", "target_format"}, "step": N}.
Печатает JSON {"step": N, "tensors": K} в stdout.
"""
import argparse
import json

import torch
from safetensors.torch import load_file, save_file


def to_pt(src: str, dst: str, alpha: float, target_format: str) -> dict:
    flat = load_file(src)
    lora: dict = {}
    for k, v in flat.items():
        path, _, ab = k.rpartition(".")
        if ab not in ("A", "B"):
            raise SystemExit(f"неожиданный ключ {k}")
        lora.setdefault(path, {})[ab] = v.float().clone()
    r = next(iter(lora.values()))["A"].shape[0]
    torch.save({"lora": lora, "config": {"r": int(r), "alpha": float(alpha), "target_format": target_format}, "step": 0}, dst)
    return {"step": 0, "tensors": len(flat)}


def from_pt(src: str, dst: str) -> dict:
    ck = torch.load(src, map_location="cpu", weights_only=False)
    flat = {}
    for path, ab in ck["lora"].items():
        flat[f"{path}.A"] = ab["A"].float().contiguous()
        flat[f"{path}.B"] = ab["B"].float().contiguous()
    save_file(flat, dst)
    return {"step": int(ck.get("step", 0)), "tensors": len(flat)}


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["to-pt", "from-pt"])
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--alpha", type=float, default=32.0)
    ap.add_argument("--target-format", default="norm")
    a = ap.parse_args()
    res = to_pt(a.src, a.dst, a.alpha, a.target_format) if a.mode == "to-pt" else from_pt(a.src, a.dst)
    print(json.dumps(res))
