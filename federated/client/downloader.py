"""Загрузка и проверка глобального адаптера.

Проверки: подпись описания закреплённым ключом сервера, совпадение спецификации (spec_hash), версия не ниже
установленной (откат делается НОВОЙ версией, понижение отвергается: защита от подмены старым ответом), размер,
SHA-256, имена/формы/dtype/конечность тензоров. Установка атомарная; предыдущая версия хранится для локального отката.
Необязательный validator(path) -> bool: локальная проверка (например, качество на своём dev-наборе); False = не ставить.
"""
from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional

import numpy as np

from client.config import ClientConfig
from client.transport import Transport
from protocol.adapter_io import check_safetensors_header, load_adapter, loads_adapter, validate_against_spec
from protocol.errors import ProtocolError
from protocol.modelsig import verify_model_info
from protocol.schema import ModelInfo
from protocol.spec import AdapterSpec

SLACK = 64 * 1024


@dataclass
class SyncResult:
    version: int
    path: Path
    changed: bool
    skipped_reason: Optional[str] = None


class AdapterStore:
    def __init__(self, directory: Path):
        self.dir = directory
        self.index_path = directory / "index.json"

    def _read(self) -> dict:
        if self.index_path.exists():
            return json.loads(self.index_path.read_text())
        return {"current": None, "previous": None, "rejected": []}

    def _write(self, idx: dict) -> None:
        self.dir.mkdir(parents=True, exist_ok=True)
        tmp = self.index_path.with_suffix(".tmp")
        tmp.write_text(json.dumps(idx))
        tmp.replace(self.index_path)

    def path(self, v: int) -> Path:
        return self.dir / f"v{v:06d}.safetensors"

    def current(self) -> Optional[int]:
        return self._read()["current"]

    def rejected(self) -> list[int]:
        return self._read()["rejected"]

    def install(self, v: int, data: bytes) -> Path:
        self.dir.mkdir(parents=True, exist_ok=True)
        p = self.path(v)
        tmp = p.with_suffix(".tmp")
        tmp.write_bytes(data)
        tmp.replace(p)
        return p

    def activate(self, v: int) -> None:
        idx = self._read()
        if idx["current"] != v:
            idx["previous"], idx["current"] = idx["current"], v
        self._write(idx)
        keep = {idx["current"], idx["previous"]}
        for f in self.dir.glob("v*.safetensors"):
            if int(f.stem[1:]) not in keep:
                f.unlink()

    def reject(self, v: int) -> None:
        idx = self._read()
        idx["rejected"] = sorted(set(idx["rejected"]) | {v})
        self._write(idx)
        p = self.path(v)
        if idx["current"] != v and idx["previous"] != v:
            p.unlink(missing_ok=True)

    def rollback_local(self) -> Optional[int]:
        idx = self._read()
        if idx["previous"] is None:
            return None
        idx["current"], idx["previous"] = idx["previous"], None
        self._write(idx)
        return idx["current"]


class ModelSync:
    def __init__(self, cfg: ClientConfig, spec: AdapterSpec, transport: Transport):
        self.cfg, self.spec, self.tr = cfg, spec, transport
        self.store = AdapterStore(cfg.adapters_dir)

    def fetch_latest(self) -> ModelInfo:
        return ModelInfo.model_validate(self.tr.request("GET", "/v1/model/latest").json())

    def fetch_adapter(self, info: ModelInfo) -> bytes:
        return self.tr.request("GET", info.download_path).content

    def fetch_info(self) -> ModelInfo:
        if not self.cfg.server.signing_public_key:
            raise ValueError("server.signing_public_key не задан: без закреплённого ключа модель не принимается")
        info = self.fetch_latest()
        verify_model_info(info, self.cfg.server.signing_public_key)
        if info.spec_hash != self.spec.hash or info.spec_id != self.spec.spec_id:
            raise ProtocolError("spec_mismatch", "сервер отдаёт адаптер другой спецификации (обновите приложение)")
        return info

    def sync(self, validator: Optional[Callable[[Path], bool]] = None) -> SyncResult:
        info = self.fetch_info()
        cur = self.store.current()
        if cur is not None and info.version < cur:
            raise ProtocolError("bad_signature", f"сервер предлагает версию v{info.version} ниже установленной v{cur}: отвергнуто")
        if info.version in self.store.rejected():
            return SyncResult(cur or 0, self.store.path(cur) if cur else Path(), False, f"v{info.version} ранее отвергнута локальной проверкой")
        if cur == info.version and self.store.path(cur).exists():
            return SyncResult(cur, self.store.path(cur), False)
        limit = 4 * self.spec.num_params + SLACK
        if info.size_bytes > limit:
            raise ProtocolError("too_large", f"размер адаптера {info.size_bytes} Б больше ожидаемого {limit}")
        data = self.fetch_adapter(info)
        if len(data) != info.size_bytes or hashlib.sha256(data).hexdigest() != info.sha256:
            raise ProtocolError("bad_payload", "размер или SHA-256 скачанного адаптера не совпали с подписанным описанием")
        check_safetensors_header(data)
        validate_against_spec(loads_adapter(data), self.spec, delta=False, dtype=np.float32)
        p = self.store.install(info.version, data)
        if validator is not None and not validator(p):
            self.store.reject(info.version)
            return SyncResult(cur or 0, self.store.path(cur) if cur else Path(), False, f"v{info.version} не прошла локальную проверку")
        self.store.activate(info.version)
        return SyncResult(info.version, p, True)

    def load_current(self) -> tuple[int, dict[str, np.ndarray]]:
        v = self.store.current()
        if v is None:
            raise FileNotFoundError("глобальный адаптер ещё не загружен")
        return v, load_adapter(self.store.path(v))


class HubModelSync(ModelSync):
    """Версии прямо из открытого репозитория модели (index.json и versions/, hub/registry.py), без сервера приёма.
    Доверие то же: описание версии подписано закреплённым ключом, файл сверяется с подписанными SHA-256 и размером."""

    def __init__(self, cfg: ClientConfig, spec: AdapterSpec, base_url: str, http):
        super().__init__(cfg, spec, transport=None)
        self.base, self.http = base_url.rstrip("/"), http

    def _get(self, path: str) -> bytes:
        r = self.http.get(f"{self.base}/{path}", follow_redirects=True)
        r.raise_for_status()
        return r.content

    def fetch_latest(self) -> ModelInfo:
        idx = json.loads(self._get("index.json"))
        cur = idx.get("current")
        rec = next((v for v in idx.get("versions", []) if v.get("version") == cur and v.get("status") == "active"), None)
        if rec is None:
            raise ProtocolError("not_found", "в репозитории модели нет текущей версии общего адаптера")
        return ModelInfo.model_validate(rec["info"])

    def fetch_adapter(self, info: ModelInfo) -> bytes:
        return self._get(f"versions/v{info.version:06d}.safetensors")
