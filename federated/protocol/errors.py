"""Коды ошибок протокола. Один и тот же код видят и сервер (HTTP-ответ), и клиент (исключение)."""
from __future__ import annotations

# код -> HTTP-статус
HTTP_STATUS = {
    "bad_schema": 422,
    "bad_signature": 401,
    "bad_payload": 422,
    "spec_mismatch": 422,
    "too_large": 413,
    "nonfinite": 422,
    "norm_too_large": 422,
    "stale_base": 409,
    "unknown_base": 409,
    "conflict": 409,
    "rate_limited": 429,
    "banned": 403,
    "not_found": 404,
    "length_required": 411,
    "unauthorized": 401,
    "forbidden": 403,
    "bad_task": 422,
    "unavailable": 503,
    "server_error": 500,
}

# Эти ошибки повторять бессмысленно: результат не изменится от повтора.
PERMANENT = {"bad_schema", "bad_signature", "bad_payload", "spec_mismatch", "too_large", "nonfinite",
             "norm_too_large", "conflict", "banned", "length_required", "unauthorized", "forbidden",
             "bad_task"}


class ProtocolError(Exception):
    def __init__(self, code: str, message: str = "", **extra):
        super().__init__(f"{code}: {message}" if message else code)
        self.code = code
        self.message = message
        self.extra = extra

    @property
    def status(self) -> int:
        return HTTP_STATUS.get(self.code, 400)

    def to_body(self) -> dict:
        return {"error": self.code, "message": self.message, **self.extra}
