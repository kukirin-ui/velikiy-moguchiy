"""Каноническая сериализация JSON: байты, которые подписываются, одинаковы на клиенте и сервере."""
from __future__ import annotations

import json


def canonical_json(obj) -> bytes:
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=True, allow_nan=False).encode("ascii")
