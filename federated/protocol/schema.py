"""Схемы сообщений (pydantic v2; JSON Schema экспортируется в protocol/schemas/*.json).

Манифест обновления содержит РОВНО эти поля и ничего больше (extra=forbid): идентификатор установки, версию базы,
число примеров, служебные поля протокола (схема, спецификация адаптера, хэш и размер полезной нагрузки, публичный
ключ). Ни текстов, ни видео, ни признаков, ни имён устройств, ни времени отправки в нём нет.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Literal, Optional

from pydantic import BaseModel, ConfigDict, Field, field_validator

from . import PROTOCOL_VERSION

HEX32 = r"^[0-9a-f]{32}$"
HEX64 = r"^[0-9a-f]{64}$"
MAX_EXAMPLES = 1_000_000


class UpdateManifest(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)
    schema_version: Literal[2] = PROTOCOL_VERSION
    client_id: str = Field(pattern=HEX32, description="псевдоним установки = SHA-256(public_key)[:16] в hex")
    public_key: str = Field(min_length=44, max_length=44, description="Ed25519, 32 байта в base64")
    base_version: int = Field(ge=1, description="версия глобального адаптера, от которой посчитана дельта")
    spec_id: str = Field(min_length=1, max_length=64)
    spec_hash: str = Field(pattern=HEX64)
    num_examples: int = Field(ge=1, le=MAX_EXAMPLES, description="сколько клипов участвовало в локальном обучении")
    payload_sha256: str = Field(pattern=HEX64)
    payload_bytes: int = Field(ge=1)
    payload_dtype: Literal["float16"] = "float16"


class SignedManifest(BaseModel):
    """Тело части `manifest` в multipart-запросе."""
    model_config = ConfigDict(extra="forbid")
    manifest: UpdateManifest
    signature: str = Field(min_length=88, max_length=88, description="Ed25519 (64 байта) в base64")


class UpdateReceipt(BaseModel):
    status: Literal["accepted", "duplicate"]
    update_id: str
    base_version: int
    update_norm: float = Field(description="L2-норма принятой дельты (по всем тензорам)")
    pending_in_round: int = Field(description="сколько обновлений ждут агрегации на эту базовую версию")


class ModelInfo(BaseModel):
    """Описание глобального адаптера. Подписывается ключом сервера (signing key), чей публичный ключ закреплён в клиенте."""
    model_config = ConfigDict(extra="forbid")
    version: int = Field(ge=1)
    spec_id: str
    spec_hash: str = Field(pattern=HEX64)
    sha256: str = Field(pattern=HEX64, description="SHA-256 файла адаптера (safetensors fp32)")
    size_bytes: int
    created_at: int = Field(description="unix-время публикации")
    round_clients: Optional[int] = Field(None, description="сколько обновлений вошло в версию")
    rollback_of: Optional[int] = Field(None, description="версия-содержимое, если это откат")
    download_path: str
    signature: str = Field(min_length=88, max_length=88)

    def signed_part(self) -> dict:
        return self.model_dump(mode="json", exclude={"signature"})

    @field_validator("download_path")
    @classmethod
    def _path(cls, v: str) -> str:
        if not v.startswith("/v1/model/") or ".." in v:
            raise ValueError("недопустимый download_path")
        return v


class ErrorBody(BaseModel):
    error: str
    message: str = ""
    latest_version: Optional[int] = None


class Health(BaseModel):
    status: Literal["ok"] = "ok"
    protocol: int = PROTOCOL_VERSION
    latest_version: Optional[int] = None


SCHEMAS = {
    "update_manifest": UpdateManifest,
    "signed_manifest": SignedManifest,
    "update_receipt": UpdateReceipt,
    "model_info": ModelInfo,
    "error": ErrorBody,
    "health": Health,
}


def export_schemas(out_dir: Path) -> list[Path]:
    from .spec import AdapterSpec
    out_dir.mkdir(parents=True, exist_ok=True)
    paths = []
    for name, model in {**SCHEMAS, "adapter_spec": AdapterSpec}.items():
        p = out_dir / f"{name}.schema.json"
        p.write_text(json.dumps(model.model_json_schema(), indent=1, ensure_ascii=False) + "\n")
        paths.append(p)
    return paths


if __name__ == "__main__":
    for p in export_schemas(Path(__file__).parent / "schemas"):
        print(p)
