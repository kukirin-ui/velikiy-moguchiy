"""Крошечная модель-заменитель MultiVSR для симуляции: трансформер на синтетических последовательностях.

Задача: классифицировать последовательность (T=8 кадров x 16 признаков) на K=8 классов. Класс = прототип
последовательности + шум. «Стиль пользователя» = постоянный сдвиг признаков (аналог сдвига домена: веб-камера,
беззвучная артикуляция). Базовая модель предобучена на данных БЕЗ сдвига (аналог публичного набора), затем база
замораживается, а LoRA-адаптеры (ранг 8 на q и v в обоих блоках) обучаются на данных клиентов. Данные клиентов
не IID: у каждого свой перекос по классам (Дирихле), свой размер выборки и своя индивидуальная часть сдвига.
"""
from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

from protocol.spec import AdapterSpec, TensorSpec

K, T, DIN, D, HEADS, LAYERS, RANK, ALPHA = 8, 8, 16, 32, 2, 2, 8, 16.0
NOISE = 1.6
COMMON_SHIFT, OWN_SHIFT = 3.0, 1.5


class LoRALinear(nn.Module):
    def __init__(self, base: nn.Linear, r: int, alpha: float):
        super().__init__()
        self.base, self.scale = base, alpha / r
        self.A = nn.Parameter(torch.empty(r, base.in_features).uniform_(-1, 1) / math.sqrt(base.in_features))
        self.B = nn.Parameter(torch.zeros(base.out_features, r))

    def forward(self, x):
        return self.base(x) + (x @ self.A.t() @ self.B.t()) * self.scale


class Block(nn.Module):
    def __init__(self):
        super().__init__()
        self.q, self.k, self.v, self.o = (nn.Linear(D, D) for _ in range(4))
        self.ff1, self.ff2 = nn.Linear(D, 2 * D), nn.Linear(2 * D, D)
        self.ln1, self.ln2 = nn.LayerNorm(D), nn.LayerNorm(D)

    def forward(self, x):
        B, L, _ = x.shape
        h = self.ln1(x)
        sp = lambda t: t.view(B, L, HEADS, D // HEADS).transpose(1, 2)
        a = F.scaled_dot_product_attention(sp(self.q(h)), sp(self.k(h)), sp(self.v(h)))
        x = x + self.o(a.transpose(1, 2).reshape(B, L, D))
        return x + self.ff2(F.gelu(self.ff1(self.ln2(x))))


class Tiny(nn.Module):
    def __init__(self):
        super().__init__()
        self.inp = nn.Linear(DIN, D)
        self.pos = nn.Parameter(torch.randn(T, D) * 0.1)
        self.layers = nn.ModuleList(Block() for _ in range(LAYERS))
        self.head = nn.Linear(D, K)

    def forward(self, x):
        h = self.inp(x) + self.pos
        for b in self.layers:
            h = b(h)
        return self.head(h.mean(1))


def add_lora(model: Tiny) -> None:
    for p in model.parameters():
        p.requires_grad_(False)
    for b in model.layers:
        b.q, b.v = LoRALinear(b.q, RANK, ALPHA), LoRALinear(b.v, RANK, ALPHA)


def lora_names(model: Tiny) -> list[str]:
    return [f"layers.{i}.{n}" for i in range(LAYERS) for n in ("q", "v")]


def tiny_spec() -> AdapterSpec:
    ts = []
    for i in range(LAYERS):
        for n in ("q", "v"):
            ts.append(TensorSpec(name=f"layers.{i}.{n}.A", shape=[RANK, D], kind="lora_A"))
            ts.append(TensorSpec(name=f"layers.{i}.{n}.B", shape=[D, RANK], kind="lora_B"))
    return AdapterSpec(spec_id="tiny-sim-lora-r8-qv", rank=RANK, alpha=ALPHA, tensors=ts)


def get_adapter(model: Tiny) -> dict[str, np.ndarray]:
    out = {}
    for i, b in enumerate(model.layers):
        for n in ("q", "v"):
            m = getattr(b, n)
            out[f"layers.{i}.{n}.A"] = m.A.detach().cpu().numpy().astype(np.float32).copy()
            out[f"layers.{i}.{n}.B"] = m.B.detach().cpu().numpy().astype(np.float32).copy()
    return out


def set_adapter(model: Tiny, ad: dict[str, np.ndarray]) -> None:
    with torch.no_grad():
        for i, b in enumerate(model.layers):
            for n in ("q", "v"):
                m = getattr(b, n)
                m.A.copy_(torch.from_numpy(ad[f"layers.{i}.{n}.A"]))
                m.B.copy_(torch.from_numpy(ad[f"layers.{i}.{n}.B"]))


# --- данные ---
@dataclass
class World:
    protos: np.ndarray      # (K, T, DIN)
    common: np.ndarray      # общий сдвиг домена (DIN,)


def make_world(seed: int = 0) -> World:
    r = np.random.default_rng(seed)
    c = r.standard_normal(DIN)
    return World(r.standard_normal((K, T, DIN)).astype(np.float32), (COMMON_SHIFT * c / np.linalg.norm(c) * math.sqrt(DIN) / 2).astype(np.float32))


def sample(world: World, y: np.ndarray, shift: np.ndarray, rng) -> np.ndarray:
    return (world.protos[y] + NOISE * rng.standard_normal((len(y), T, DIN)) + shift).astype(np.float32)


def make_client_shift(world: World, rng) -> np.ndarray:
    o = rng.standard_normal(DIN)
    return world.common + (OWN_SHIFT * o / np.linalg.norm(o) * math.sqrt(DIN) / 2).astype(np.float32)


@dataclass
class Shard:
    name: str
    x_train: torch.Tensor
    y_train: torch.Tensor
    x_test: torch.Tensor        # те же перекос и сдвиг, что у обучающей части
    y_test: torch.Tensor
    x_bal: torch.Tensor         # сбалансированная по классам выборка со сдвигом клиента (вклад в «глобальный» тест)
    y_bal: torch.Tensor
    class_probs: np.ndarray


def make_shard(world: World, name: str, n_train: int, alpha_dir: float, rng) -> Shard:
    probs = rng.dirichlet(alpha_dir * np.ones(K))
    shift = make_client_shift(world, rng)
    ytr, yte = rng.choice(K, n_train, p=probs), rng.choice(K, 200, p=probs)
    ybal = np.repeat(np.arange(K), 20)
    t = lambda a: torch.from_numpy(a)
    return Shard(name, t(sample(world, ytr, shift, rng)), t(ytr), t(sample(world, yte, shift, rng)), t(yte),
                 t(sample(world, ybal, shift, rng)), t(ybal), probs)


def pretrain_base(world: World, seed: int = 0, steps: int = 500) -> Tiny:
    torch.manual_seed(seed)
    m = Tiny()
    opt = torch.optim.Adam(m.parameters(), lr=3e-3)
    rng = np.random.default_rng(seed + 1)
    for _ in range(steps):
        y = rng.integers(0, K, 64)
        x = torch.from_numpy(sample(world, y, np.zeros(DIN, np.float32), rng))
        loss = F.cross_entropy(m(x), torch.from_numpy(y))
        opt.zero_grad(); loss.backward(); opt.step()
    return m


def train_local(model: Tiny, shard: Shard, steps: int, lr: float, seed: int, batch: int = 32,
                should_stop=None, y_override: torch.Tensor | None = None) -> int:
    params = [p for p in model.parameters() if p.requires_grad]
    opt = torch.optim.Adam(params, lr=lr)
    g = torch.Generator().manual_seed(seed)
    y_all = shard.y_train if y_override is None else y_override
    done = 0
    for done in range(1, steps + 1):
        idx = torch.randint(0, len(y_all), (batch,), generator=g)
        loss = F.cross_entropy(model(shard.x_train[idx]), y_all[idx])
        opt.zero_grad(); loss.backward(); opt.step()
        if should_stop and should_stop():
            break
    return done


@torch.no_grad()
def accuracy(model: Tiny, x: torch.Tensor, y: torch.Tensor) -> float:
    return float((model(x).argmax(-1) == y).float().mean())
