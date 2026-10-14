"""Спецификация адаптера: какие тензоры есть в LoRA, их формы, какие из них обучаются и уходят дельтой.

Сервер и клиент обязаны иметь одну и ту же спецификацию (сверка по spec_hash). Для MultiVSR файл
`protocol/specs/multivsr_lora_r16.json` (144 тензора, 1 769 472 параметра) сгенерирован `sim/gen_real_spec.py`.

`trainable=False` у тензоров позволяет режим FFA-LoRA (A заморожен, шлётся только B): тогда усреднение точное,
потому что (mean B)·A = mean(B·A). По умолчанию обучаются оба фактора (A и B усредняются отдельно, это приближение,
см. docs/DESIGN.md).
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Literal

import numpy as np
from pydantic import BaseModel, ConfigDict, Field

from .canonical import canonical_json

SPEC_FORMAT = 1
HEADER_SLACK = 64 * 1024  # запас на заголовок safetensors при расчёте предельного размера


class TensorSpec(BaseModel):
    model_config = ConfigDict(extra="forbid")
    name: str
    shape: list[int]
    kind: Literal["lora_A", "lora_B", "other"] = "other"
    trainable: bool = True

    @property
    def numel(self) -> int:
        n = 1
        for s in self.shape:
            n *= s
        return n


class AdapterSpec(BaseModel):
    model_config = ConfigDict(extra="forbid")
    spec_id: str
    format: int = SPEC_FORMAT
    rank: int
    alpha: float
    tensors: list[TensorSpec] = Field(min_length=1)

    @property
    def hash(self) -> str:
        return hashlib.sha256(canonical_json(self.model_dump(mode="json"))).hexdigest()

    def by_name(self) -> dict[str, TensorSpec]:
        return {t.name: t for t in self.tensors}

    @property
    def delta_tensors(self) -> list[TensorSpec]:
        return [t for t in self.tensors if t.trainable]

    @property
    def num_params(self) -> int:
        return sum(t.numel for t in self.tensors)

    @property
    def num_delta_params(self) -> int:
        return sum(t.numel for t in self.delta_tensors)

    def max_payload_bytes(self) -> int:
        """Предел размера дельты fp16 (+ заголовок safetensors). Всё больше отвергается ещё до разбора."""
        return 2 * self.num_delta_params + HEADER_SLACK


def load_spec(path) -> AdapterSpec:
    return AdapterSpec.model_validate(json.loads(Path(path).read_text()))


def save_spec(spec: AdapterSpec, path) -> None:
    Path(path).write_text(json.dumps(spec.model_dump(mode="json"), indent=1) + "\n")


def init_adapter(spec: AdapterSpec, seed: int = 0) -> dict[str, np.ndarray]:
    """Начальный глобальный адаптер: A ~ U(-1/sqrt(in), 1/sqrt(in)) (как kaiming_uniform(a=sqrt(5)) в lora.py),
    B = 0, прочее 0. Все клиенты стартуют от одной и той же версии, поэтому A у всех общий."""
    rng = np.random.default_rng(seed)
    out = {}
    for t in spec.tensors:
        if t.kind == "lora_A":
            bound = 1.0 / np.sqrt(t.shape[1])
            out[t.name] = rng.uniform(-bound, bound, size=t.shape).astype(np.float32)
        else:
            out[t.name] = np.zeros(t.shape, dtype=np.float32)
    return out
