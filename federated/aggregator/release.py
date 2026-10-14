"""Начальная версия общего адаптера: LoRA из релиза lips-0.1 (zigansh1n/velikiy-moguchiy-models).

Файл .pt скачивается, сверяется с закреплённым SHA-256 и читается aggregator/ptload.py (без torch, белый список
классов). Берётся ключ "lora" (72 модуля q/v, ранг 16), конфигурация сверяется со спецификацией протокола.
Визуальная часть из того же релиза остаётся у клиентов как есть.
"""
from __future__ import annotations

import hashlib

import httpx
import numpy as np

from aggregator import ptload
from protocol.adapter_io import dumps_adapter, validate_against_spec
from protocol.spec import AdapterSpec

URL = "https://github.com/zigansh1n/velikiy-moguchiy-models/releases/download/lips-0.1/velikiy-moguchiy-lips-0.1.pt"
SHA256 = "720186ee8b0cd613a0ba0d76f02b73ba173571d3c5502839e4637aed9be628cf"


def adapter_from_checkpoint(data: bytes, spec: AdapterSpec) -> bytes:
    ck = ptload.load(data)
    cfg = ck.get("config", {})
    if int(cfg.get("r", -1)) != spec.rank or float(cfg.get("alpha", -1)) != spec.alpha:
        raise SystemExit(f"lips-0.1: r={cfg.get('r')} alpha={cfg.get('alpha')}, а в спецификации r={spec.rank} alpha={spec.alpha}")
    flat = {}
    for path, ab in ck["lora"].items():
        flat[f"{path}.A"] = np.ascontiguousarray(ab["A"], np.float32)
        flat[f"{path}.B"] = np.ascontiguousarray(ab["B"], np.float32)
    validate_against_spec(flat, spec, delta=False, dtype=np.float32)
    return dumps_adapter(flat, metadata={"spec_hash": spec.hash})


def lips01_adapter(spec: AdapterSpec, url: str = URL, sha256: str = SHA256) -> bytes:
    data = httpx.get(url, follow_redirects=True, timeout=300.0).raise_for_status().content
    if hashlib.sha256(data).hexdigest() != sha256:
        raise SystemExit("lips-0.1.pt: SHA-256 не совпал с закреплённым")
    return adapter_from_checkpoint(data, spec)
