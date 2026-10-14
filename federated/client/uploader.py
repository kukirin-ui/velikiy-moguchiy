"""Отправка упакованного обновления. Повторы и задержки в Transport; повтор безопасен (сервер идемпотентен)."""
from __future__ import annotations

import json
import time
from pathlib import Path

from client.transport import Transport
from protocol.package import PackedUpdate
from protocol.schema import UpdateReceipt


def upload_update(transport: Transport, envelope: bytes, payload: bytes) -> UpdateReceipt:
    resp = transport.request("POST", "/v1/updates", files={
        "manifest": ("manifest.json", envelope, "application/json"),
        "payload": ("update.safetensors", payload, "application/octet-stream"),
    })
    return UpdateReceipt.model_validate(resp.json())


def log_upload(path: Path, packed: PackedUpdate, receipt: UpdateReceipt | None, error: str | None = None) -> None:
    """Журнал для пользователя: ровно то, что было отправлено (манифест целиком) и чем ответил сервер.
    Содержимое весов в журнал не пишется (оно в нагрузке; размер и хэш указаны в манифесте)."""
    rec = {"ts": int(time.time()), "manifest": json.loads(packed.manifest.model_dump_json()),
           "receipt": receipt.model_dump() if receipt else None, "error": error}
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf8") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")
