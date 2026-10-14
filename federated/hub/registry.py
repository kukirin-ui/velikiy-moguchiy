"""Реестр версий общего адаптера в открытом репозитории модели на Hugging Face.

  index.json                       список версий (подписанные описания ModelInfo, итог экзамена, статус)
  versions/v<версия:06d>.safetensors   адаптер fp32

Хранится каждая версия. Номера только растут: откат публикует НОВУЮ версию с содержимым старой
(rollback_of), а версии после неё получают статус revoked. Клиент отвергает понижение версии, поэтому старая
подписанная копия не может быть подсунута как новая. Описание каждой версии подписано ключом модели; публичный
ключ закреплён в клиенте.
"""
from __future__ import annotations

import hashlib
import time
from typing import Optional

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from pydantic import BaseModel, ConfigDict, Field

from protocol.errors import ProtocolError
from protocol.modelsig import sign_model_info, verify_model_info
from protocol.schema import ModelInfo
from protocol.spec import AdapterSpec
from hub.storage import BlobStore

INDEX = "index.json"
INDEX_FORMAT = 1


class VersionRecord(BaseModel):
    model_config = ConfigDict(extra="forbid")
    version: int = Field(ge=1)
    status: str = "active"                 # active | revoked
    exam_wer: Optional[float] = None       # WER на скрытом экзамене при публикации
    exam_n: Optional[int] = None
    note: str = ""
    info: ModelInfo


class RegistryIndex(BaseModel):
    model_config = ConfigDict(extra="forbid")
    format: int = INDEX_FORMAT
    spec_id: str
    spec_hash: str
    current: Optional[int] = None
    versions: list[VersionRecord] = []

    def record(self, v: int) -> VersionRecord:
        for r in self.versions:
            if r.version == v:
                return r
        raise KeyError(v)


def version_path(v: int) -> str:
    return f"versions/v{v:06d}.safetensors"


class RegistryError(Exception):
    pass


class Registry:
    """public_key (base64): описания версий проверяются этим ключом подписи, прежде чем версии доверяют."""

    def __init__(self, store: BlobStore, spec: AdapterSpec, public_key: str | None = None):
        self.store, self.spec, self.public_key = store, spec, public_key

    def verified(self, v: int, idx: RegistryIndex | None = None) -> VersionRecord:
        rec = (idx or self.index()).record(v)
        if self.public_key:
            try:
                verify_model_info(rec.info, self.public_key)
            except ProtocolError as e:
                raise RegistryError(f"описание версии v{v} не подписано ключом проекта") from e
        if rec.info.version != v or rec.info.spec_hash != self.spec.hash:
            raise RegistryError(f"описание версии v{v} не совпадает с записью реестра")
        return rec

    def index(self) -> RegistryIndex:
        raw = self.store.read(INDEX)
        if raw is None:
            return RegistryIndex(spec_id=self.spec.spec_id, spec_hash=self.spec.hash)
        idx = RegistryIndex.model_validate_json(raw)
        if idx.spec_hash != self.spec.hash:
            raise RegistryError(f"реестр для другой спецификации адаптера ({idx.spec_id}); обновите код")
        return idx

    def current(self) -> Optional[VersionRecord]:
        idx = self.index()
        return idx.record(idx.current) if idx.current else None

    def adapter_bytes(self, v: int, idx: RegistryIndex | None = None) -> bytes:
        rec = self.verified(v, idx)
        data = self.store.read(version_path(v))
        if data is None:
            raise RegistryError(f"нет файла версии v{v}")
        if len(data) != rec.info.size_bytes or hashlib.sha256(data).hexdigest() != rec.info.sha256:
            raise RegistryError(f"файл версии v{v} не совпал с подписанным описанием")
        return data

    def publish(self, data: bytes, key: Ed25519PrivateKey, *, round_clients: int | None = None,
                rollback_of: int | None = None, exam_wer: float | None = None, exam_n: int | None = None,
                note: str = "", revoke_after: int | None = None, now: int | None = None) -> int:
        """Одним коммитом: файл новой версии и index.json, где она текущая. revoke_after=N отзывает версии > N."""
        idx = self.index()
        ver = max((r.version for r in idx.versions), default=0) + 1
        part = dict(version=ver, spec_id=self.spec.spec_id, spec_hash=self.spec.hash,
                    sha256=hashlib.sha256(data).hexdigest(), size_bytes=len(data),
                    created_at=int(time.time()) if now is None else now, round_clients=round_clients,
                    rollback_of=rollback_of, download_path=f"/v1/model/{ver}/adapter")
        info = ModelInfo(**part, signature=sign_model_info(part, key))
        if revoke_after is not None:
            for r in idx.versions:
                if r.version > revoke_after and r.status == "active":
                    r.status = "revoked"
        idx.versions.append(VersionRecord(version=ver, exam_wer=exam_wer, exam_n=exam_n, note=note, info=info))
        idx.current = ver
        self.store.commit({version_path(ver): data, INDEX: idx.model_dump_json(indent=1).encode()},
                          message=f"adapter v{ver}" + (f" (rollback to v{rollback_of})" if rollback_of else ""))
        return ver

    def rollback(self, to: int, key: Ed25519PrivateKey, reason: str = "", now: int | None = None) -> int:
        idx = self.index()
        rec = idx.record(to)
        if rec.status != "active":
            raise RegistryError(f"версия v{to} отозвана, к ней не откатиться")
        if idx.current == to:
            raise RegistryError(f"v{to} и так текущая")
        data = self.adapter_bytes(to, idx)
        return self.publish(data, key, rollback_of=to, exam_wer=rec.exam_wer, exam_n=rec.exam_n,
                            note=f"откат: {reason}"[:300], revoke_after=to, now=now)

    def history(self) -> list[dict]:
        return [dict(version=r.version, status=r.status, exam_wer=r.exam_wer, rollback_of=r.info.rollback_of,
                     round_clients=r.info.round_clients, created_at=r.info.created_at, note=r.note)
                for r in self.index().versions]
