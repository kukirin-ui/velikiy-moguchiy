"""Лимиты запросов. По установке: в SQLite (переживает перезапуск); по адресу: только в памяти (адреса на диск не пишем)."""
from __future__ import annotations

import collections
import threading
import time

from protocol.errors import ProtocolError


class IpLimiter:
    def __init__(self, per_minute: int):
        self.per_minute = per_minute
        self.hits: dict[str, collections.deque] = {}
        self.lock = threading.Lock()

    def check(self, ip: str, now: float | None = None) -> None:
        now = time.monotonic() if now is None else now
        with self.lock:
            q = self.hits.setdefault(ip, collections.deque())
            while q and now - q[0] > 60:
                q.popleft()
            if len(q) >= self.per_minute:
                raise ProtocolError("rate_limited", "слишком много запросов с этого адреса", retry_after=60)
            q.append(now)
            if len(self.hits) > 10000:  # не растём бесконечно
                for k in [k for k, v in self.hits.items() if not v or now - v[-1] > 60]:
                    self.hits.pop(k, None)


def check_client_quota(conn, client_id: str, max_per_day: int, now: int | None = None) -> None:
    """Считает попытки с проверенной подписью за 24 часа; превышение даёт 429 с Retry-After до освобождения слота."""
    now = int(time.time()) if now is None else now
    conn.execute("DELETE FROM request_log WHERE ts < ?", (now - 86400,))
    rows = conn.execute("SELECT ts FROM request_log WHERE client_id=? ORDER BY ts", (client_id,)).fetchall()
    if len(rows) >= max_per_day:
        retry = max(1, rows[0]["ts"] + 86400 - now)
        raise ProtocolError("rate_limited", f"не более {max_per_day} обновлений за 24 часа на установку", retry_after=retry)
    conn.execute("INSERT INTO request_log (client_id, ts) VALUES (?,?)", (client_id, now))
