"""Что «Помочь обучить» никогда не трогает и что никогда не уходит с компьютера.

1. Личные папки: данные приложения (~/.velikiy-moguchiy, прежнее ~/.koe) с записями камеры, диктовками и личной
   моделью «Обучить на мне», а также папки данных lipread (clips, data, work, checkpoints, results). Задание
   отказывается запускаться, если его рабочая папка внутри них или они внутри неё, и любой файл, который оно
   открывает, обязан лежать в его рабочей папке (без ссылок наружу).
2. Наружу уходит ровно три части: подписанный манифест, дельта весов в safetensors (fp16, только тензоры из
   спецификации) и подписанные сведения о вкладе. check_outgoing проверяет это перед каждой отправкой;
   всё остальное (видео, звук, кадры, признаки, тексты, пути) отправка отвергает.
"""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np

from protocol.adapter_io import loads_adapter, validate_against_spec
from protocol.contribution import MAX_CONTRIBUTION_BYTES, SignedContribution
from protocol.package import MAX_ENVELOPE_BYTES, parse_envelope
from protocol.spec import AdapterSpec

APP_DATA = ("~/.velikiy-moguchiy", "~/.koe", "~/Library/Application Support/velikiy-moguchiy",
            "~/Library/Application Support/Lipflow")
LIPREAD_DATA = ("clips", "data", "work", "checkpoints", "results", "lips_model", "lipdata")
OUTGOING_PARTS = ("manifest", "payload", "contribution")


class PrivacyError(Exception):
    pass


def personal_roots(lipread_dir: Path | None = None, home: Path | None = None) -> list[Path]:
    h = Path(home) if home else Path.home()
    roots = [h / p[2:] for p in APP_DATA]
    if lipread_dir:
        roots += [Path(lipread_dir).expanduser() / d for d in LIPREAD_DATA]
    return [r.resolve() for r in roots]


def _overlaps(a: Path, b: Path) -> bool:
    return a == b or a.is_relative_to(b) or b.is_relative_to(a)


def ensure_work_dir(work: Path, roots: list[Path]) -> Path:
    w = Path(work).expanduser().resolve()
    for r in roots:
        if _overlaps(w, r):
            raise PrivacyError(f"рабочая папка {w} пересекается с личной папкой {r}: задание не запускается")
    return w


def ensure_inside(path: Path, work: Path) -> Path:
    """Файл задания: внутри рабочей папки и без символических ссылок по пути."""
    p = Path(path)
    if p.is_symlink() or not p.resolve().is_relative_to(Path(work).resolve()):
        raise PrivacyError(f"{p} вне рабочей папки задания")
    return p.resolve()


def check_outgoing(parts: dict[str, bytes], spec: AdapterSpec) -> None:
    if tuple(sorted(parts)) != tuple(sorted(OUTGOING_PARTS)):
        raise PrivacyError(f"к отправке допускаются только части {OUTGOING_PARTS}, а не {sorted(parts)}")
    if len(parts["manifest"]) > MAX_ENVELOPE_BYTES or len(parts["contribution"]) > MAX_CONTRIBUTION_BYTES:
        raise PrivacyError("служебная часть больше допустимого")
    parse_envelope(parts["manifest"])
    SignedContribution.model_validate(json.loads(parts["contribution"]))
    tensors = loads_adapter(parts["payload"])
    validate_against_spec(tensors, spec, delta=True, dtype=np.float16)
    if len(parts["payload"]) > spec.max_payload_bytes():
        raise PrivacyError("нагрузка больше дельты адаптера")


def describe_outgoing(parts: dict[str, bytes], spec: AdapterSpec) -> dict:
    """То, что видит пользователь перед отправкой: оба служебных сообщения целиком и опись нагрузки."""
    import hashlib

    check_outgoing(parts, spec)
    tensors = loads_adapter(parts["payload"])
    return {
        "manifest": json.loads(parts["manifest"]),
        "contribution": json.loads(parts["contribution"]),
        "payload": {"format": "safetensors", "dtype": "float16", "bytes": len(parts["payload"]),
                    "sha256": hashlib.sha256(parts["payload"]).hexdigest(), "tensors": len(tensors),
                    "parameters": int(sum(t.size for t in tensors.values())),
                    "examples": sorted(tensors)[:3]},
        "total_bytes": sum(len(b) for b in parts.values()),
        "not_sent": ["видео", "звук", "кадры лица", "признаки VTP", "тексты отрезков", "названия роликов", "пути к файлам"],
    }
