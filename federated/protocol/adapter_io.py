"""Чтение и запись адаптеров (safetensors, numpy) и вычисление дельты."""
from __future__ import annotations

from pathlib import Path
from typing import Mapping

import numpy as np
from safetensors.numpy import load as st_load
from safetensors.numpy import save as st_save

from .errors import ProtocolError
from .spec import AdapterSpec

MAX_HEADER_BYTES = 256 * 1024


FOREIGN_FORMATS = (
    (b"PK\x03\x04", "zip (torch.save)"),
    (b"\x93NUMPY", "numpy"),
    (b"\x89HDF", "HDF5"),
)


def check_safetensors_header(data: bytes) -> None:
    """Дешёвая проверка заголовка до полного разбора (защита от гигантского заголовка). Принимается только
    safetensors: pickle, torch.save и прочие форматы, которые могут нести исполняемый код, отвергаются по сигнатуре."""
    for magic, name in FOREIGN_FORMATS:
        if data.startswith(magic):
            raise ProtocolError("bad_payload", f"принимается только safetensors, а это {name}")
    # a safetensors header length may also start with 0x80, so the JSON brace at offset 8 decides
    if data[:1] == b"\x80" and data[8:9] != b"{":
        raise ProtocolError("bad_payload", "принимается только safetensors, а это pickle")
    if len(data) < 8:
        raise ProtocolError("bad_payload", "файл короче заголовка safetensors")
    hlen = int.from_bytes(data[:8], "little")
    if hlen > MAX_HEADER_BYTES or 8 + hlen > len(data):
        raise ProtocolError("bad_payload", f"некорректная длина заголовка safetensors: {hlen}")
    if data[8:9] != b"{":
        raise ProtocolError("bad_payload", "заголовок safetensors не JSON")


def dumps_adapter(tensors: Mapping[str, np.ndarray], metadata: dict | None = None) -> bytes:
    return st_save({k: np.ascontiguousarray(v) for k, v in tensors.items()}, metadata=metadata)


def loads_adapter(data: bytes) -> dict[str, np.ndarray]:
    check_safetensors_header(data)
    try:
        return st_load(data)
    except Exception as e:  # noqa: BLE001  (safetensors бросает разные типы)
        raise ProtocolError("bad_payload", f"safetensors не читается: {type(e).__name__}") from e


def save_adapter(tensors, path, metadata=None) -> None:
    p = Path(path)
    tmp = p.with_suffix(p.suffix + ".tmp")
    tmp.write_bytes(dumps_adapter(tensors, metadata))
    tmp.replace(p)


def load_adapter(path) -> dict[str, np.ndarray]:
    return loads_adapter(Path(path).read_bytes())


def validate_against_spec(tensors: Mapping[str, np.ndarray], spec: AdapterSpec, *, delta: bool, dtype) -> None:
    """Имена, формы, dtype, конечность значений. delta=True: только обучаемые тензоры."""
    want = {t.name: t for t in (spec.delta_tensors if delta else spec.tensors)}
    got = set(tensors)
    if got != set(want):
        miss, extra = sorted(set(want) - got)[:3], sorted(got - set(want))[:3]
        raise ProtocolError("spec_mismatch", f"набор тензоров не совпал: нет {miss}, лишние {extra}")
    for name, t in want.items():
        a = tensors[name]
        if list(a.shape) != t.shape:
            raise ProtocolError("spec_mismatch", f"{name}: форма {list(a.shape)} вместо {t.shape}")
        if a.dtype != np.dtype(dtype):
            raise ProtocolError("spec_mismatch", f"{name}: dtype {a.dtype} вместо {np.dtype(dtype)}")
        if not np.isfinite(a).all():
            raise ProtocolError("nonfinite", f"{name}: NaN/Inf")


def l2_norm(tensors: Mapping[str, np.ndarray]) -> float:
    s = 0.0
    for a in tensors.values():
        x = a.astype(np.float64, copy=False)
        s += float(np.dot(x.ravel(), x.ravel()))
    return float(np.sqrt(s))


def compute_delta(new: Mapping[str, np.ndarray], base: Mapping[str, np.ndarray], spec: AdapterSpec) -> dict[str, np.ndarray]:
    """Дельта = локально обученный адаптер минус глобальный (fp32). Только обучаемые тензоры."""
    return {t.name: (np.asarray(new[t.name], np.float32) - np.asarray(base[t.name], np.float32)) for t in spec.delta_tensors}


def apply_delta(base: Mapping[str, np.ndarray], delta: Mapping[str, np.ndarray], scale: float = 1.0) -> dict[str, np.ndarray]:
    out = {k: np.array(v, dtype=np.float32, copy=True) for k, v in base.items()}
    for k, d in delta.items():
        out[k] += scale * np.asarray(d, np.float32)
    return out
