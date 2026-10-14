"""Одноразовый генератор спецификации адаптера MultiVSR (имена и формы тензоров LoRA r=16 на q,v).

Строит модель MultiVSR на device='meta' (0 байт памяти, веса не нужны) через код lipread и читает формы.
Запуск окружением lipread:
  ../tools/mem_guard.py -- ../lipread/.venv/bin/python sim/gen_real_spec.py   (из каталога federated/)
Код lipread не меняется и не копируется, читается только на импорт.
"""
import hashlib
import json
import os
import sys
from pathlib import Path

# lipread/ рядом с federated/ в том же репозитории; LIPREAD_RU_DIR переопределяет.
LIPREAD = Path(os.environ.get("LIPREAD_RU_DIR") or Path(__file__).resolve().parents[2] / "lipread")
sys.path.insert(0, str(LIPREAD))
import torch  # noqa: E402
import mvsr  # noqa: E402  (импорт memguard из lipread)

R = 16
mv = mvsr._multivsr()
with torch.device("meta"):
    model = mv["models"].build_model()

tensors = []
for name, mod in model.named_modules():
    if type(mod).__name__ != "MultiHeadedAttention":
        continue
    for i in (0, 2):  # q, v
        lin = mod.linears[i]
        path = f"{name}.linears.{i}"
        tensors.append({"name": f"{path}.A", "shape": [R, lin.in_features], "kind": "lora_A", "trainable": True})
        tensors.append({"name": f"{path}.B", "shape": [lin.out_features, R], "kind": "lora_B", "trainable": True})
n_params = sum(t["shape"][0] * t["shape"][1] for t in tensors)
spec = {"spec_id": "multivsr-ru-lora-r16-qv", "format": 1, "rank": R, "alpha": 32.0, "tensors": tensors}
out = Path(__file__).resolve().parent.parent / "protocol" / "specs" / "multivsr_lora_r16.json"
out.write_text(json.dumps(spec, indent=1, ensure_ascii=False) + "\n")
print(f"{len(tensors)} тензоров, {n_params} параметров -> {out}")
print("первые:", [t["name"] for t in tensors[:4]])
