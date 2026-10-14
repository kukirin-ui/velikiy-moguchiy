"""Сведения о вкладе участника: сколько данных и шагов обучения стоит за обновлением. Третья часть запроса
POST /v1/updates рядом с подписанным манифестом и нагрузкой.

Подписывается тем же ключом установки, что и манифест (DOMAIN отдельный, поэтому подпись одного сообщения
не подходит к другому), и ссылается на ту же нагрузку (payload_sha256). Здесь только числа и идентификатор задания:
ни названий роликов, ни текстов, ни кадров.
"""
from __future__ import annotations

import json

from pydantic import BaseModel, ConfigDict, Field, ValidationError

from . import PROTOCOL_VERSION
from .canonical import canonical_json
from .errors import ProtocolError
from .identity import Identity, b64d, b64e, verify_signature
from .schema import HEX32, HEX64, UpdateManifest

DOMAIN = b"velikiy-moguchiy-fl/contribution/v2\n"
MAX_CONTRIBUTION_BYTES = 4 * 1024
MAX_DATA_SECONDS = 24 * 3600
MAX_TRAINING_STEPS = 100_000


class Contribution(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)
    schema_version: int = Field(PROTOCOL_VERSION, ge=PROTOCOL_VERSION, le=PROTOCOL_VERSION)
    client_id: str = Field(pattern=HEX32)
    payload_sha256: str = Field(pattern=HEX64)
    base_version: int = Field(ge=1)
    task_token: str = Field(min_length=1, max_length=2048, description="токен задания, выданный сервером")
    data_seconds: float = Field(ge=0, le=MAX_DATA_SECONDS, description="секунд видео с лицом, на которых шло обучение")
    training_steps: int = Field(ge=0, le=MAX_TRAINING_STEPS)
    num_clips: int = Field(ge=0, le=100_000)
    credit_public: bool = Field(True, description="показывать логин GitHub в таблице участников")


class SignedContribution(BaseModel):
    model_config = ConfigDict(extra="forbid")
    contribution: Contribution
    signature: str = Field(min_length=88, max_length=88)


def _signing_bytes(c: Contribution) -> bytes:
    return DOMAIN + canonical_json(c.model_dump(mode="json"))


def sign_contribution(c: Contribution, identity: Identity) -> bytes:
    if c.client_id != identity.client_id:
        raise ValueError("client_id вклада не совпадает с ключом установки")
    return SignedContribution(contribution=c, signature=b64e(identity.sign(_signing_bytes(c)))).model_dump_json().encode()


def verify_contribution(data: bytes, manifest: UpdateManifest) -> Contribution:
    """Схема, подпись ключом из уже проверенного манифеста, ссылка на ту же нагрузку и ту же базу."""
    if len(data) > MAX_CONTRIBUTION_BYTES:
        raise ProtocolError("too_large", f"сведения о вкладе {len(data)} Б больше {MAX_CONTRIBUTION_BYTES}")
    try:
        sc = SignedContribution.model_validate(json.loads(data))
    except (ValueError, ValidationError) as e:
        raise ProtocolError("bad_schema", f"сведения о вкладе не прошли схему: {str(e)[:200]}") from e
    c = sc.contribution
    if c.client_id != manifest.client_id or c.payload_sha256 != manifest.payload_sha256 or c.base_version != manifest.base_version:
        raise ProtocolError("bad_payload", "сведения о вкладе относятся к другому обновлению")
    try:
        ok = verify_signature(b64d(manifest.public_key), b64d(sc.signature), _signing_bytes(c))
    except Exception as e:  # noqa: BLE001
        raise ProtocolError("bad_schema", "base64 подписи вклада некорректен") from e
    if not ok:
        raise ProtocolError("bad_signature", "подпись сведений о вкладе не сходится")
    return c
