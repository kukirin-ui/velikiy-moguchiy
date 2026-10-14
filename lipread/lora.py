"""LoRA на чистом PyTorch для трансформера MultiVSR (peft не нужен и не ставится: он потянул бы за собой
версии transformers, а у нас они закреплены).

Целевые модули: проекции q и v (индексы 0 и 2 в MultiHeadedAttention.linears) во ВСЕХ вниманиях:
самовнимание энкодера (12), самовнимание декодера (12), кросс-внимание декодера (12) = 36 внимания,
72 адаптера, при ранге 16 это 1 769 472 обучаемых параметра.

  apply_lora(model, r, alpha, dropout)      оборачивает linears[0], linears[2] в LoRALinear
  lora_state_dict(model)                    {путь: {"A": тензор, "B": тензор}} (fp32, на CPU)
  load_lora_state_dict(model, sd)           загрузка адаптеров в обёрнутую модель
  merge_lora_into_base(model, ckpt)         для инференса: W += (alpha/r) * B @ A, без обёрток
"""
from __future__ import annotations

import torch
import torch.nn as nn

QV = (0, 2)  # q, v


class LoRALinear(nn.Module):
    def __init__(self, base: nn.Linear, r: int = 16, alpha: float = 32.0, dropout: float = 0.0):
        super().__init__()
        self.base = base
        self.r, self.alpha = r, alpha
        self.scale = alpha / r
        self.A = nn.Parameter(torch.empty(r, base.in_features, dtype=torch.float32))
        self.B = nn.Parameter(torch.zeros(base.out_features, r, dtype=torch.float32))
        nn.init.kaiming_uniform_(self.A, a=5 ** 0.5)  # как в peft; B = 0, поэтому старт = исходная модель
        self.drop = nn.Dropout(dropout) if dropout > 0 else nn.Identity()

    def forward(self, x):
        d = (self.drop(x) @ self.A.t().to(x.dtype)) @ self.B.t().to(x.dtype)
        return self.base(x) + d * self.scale


def _attn_modules(model):
    for name, mod in model.named_modules():
        if type(mod).__name__ == "MultiHeadedAttention":
            yield name, mod


def apply_lora(model: nn.Module, r: int = 16, alpha: float = 32.0, dropout: float = 0.0) -> int:
    """Замораживает всю модель и вставляет адаптеры. Возвращает число обучаемых параметров."""
    for p in model.parameters():
        p.requires_grad_(False)
    n = 0
    for name, mod in _attn_modules(model):
        lins = list(mod.linears)
        for i in QV:
            lins[i] = LoRALinear(lins[i], r, alpha, dropout)
        mod.linears = nn.ModuleList(lins)
        n += 1
    assert n == 36, f"ожидалось 36 вниманий, найдено {n}"
    dev = next(model.parameters()).device
    for m in model.modules():
        if isinstance(m, LoRALinear):
            m.to(dev)
    return sum(p.numel() for p in model.parameters() if p.requires_grad)


def lora_params(model: nn.Module):
    return [p for p in model.parameters() if p.requires_grad]


def lora_state_dict(model: nn.Module) -> dict:
    out = {}
    for name, mod in model.named_modules():
        if isinstance(mod, LoRALinear):
            out[name] = {"A": mod.A.detach().float().cpu().clone(), "B": mod.B.detach().float().cpu().clone()}
    return out


def load_lora_state_dict(model: nn.Module, sd: dict):
    mods = {n: m for n, m in model.named_modules() if isinstance(m, LoRALinear)}
    missing = set(mods) ^ set(sd)
    if missing:
        raise ValueError(f"адаптеры не совпадают с моделью: {sorted(missing)[:4]}...")
    for n, m in mods.items():
        m.A.data.copy_(sd[n]["A"].to(m.A.device))
        m.B.data.copy_(sd[n]["B"].to(m.B.device))


@torch.no_grad()
def merge_lora_into_base(model: nn.Module, ckpt: dict) -> int:
    """model: обычная модель MultiVSR (без обёрток), ckpt: словарь из train.py ({'lora': ..., 'config': ...}).
    Сливает W += scale * B @ A в fp32. Возвращает число слитых адаптеров."""
    cfg = ckpt["config"]
    scale = cfg["alpha"] / cfg["r"]
    sd = ckpt["lora"]
    mods = dict(model.named_modules())
    n = 0
    for path, ab in sd.items():
        # путь вида encoder.layers.0.self_attn.linears.0 -> модуль nn.Linear
        lin = mods[path]
        if not isinstance(lin, nn.Linear):
            raise ValueError(f"{path}: ожидался nn.Linear (модель уже с LoRA-обёртками?)")
        delta = (ab["B"].float() @ ab["A"].float()) * scale
        lin.weight.add_(delta.to(lin.weight.device, lin.weight.dtype))
        n += 1
    return n
