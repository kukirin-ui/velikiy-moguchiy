"""Личность участника = логин GitHub. Клиент получает токен через OAuth device flow (client/github_login.py) и
шлёт его в заголовке Authorization; сервер узнаёт по нему логин запросом GET /user к API GitHub.

Токен нигде не сохраняется и не пишется в журнал: в памяти держится только SHA-256 токена -> пользователь на
cache_seconds, чтобы не спрашивать GitHub на каждый запрос. Токену не нужны никакие права (scope пустой).
"""
from __future__ import annotations

import hashlib
import re
import threading
import time
from dataclasses import dataclass
from datetime import datetime
from typing import Callable

import httpx

from protocol.errors import ProtocolError

API = "https://api.github.com"
LOGIN_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38}$")


@dataclass(frozen=True)
class GithubUser:
    login: str
    id: int
    created_at: float  # unix-время создания аккаунта


def bearer_token(header: str | None) -> str:
    if not header:
        raise ProtocolError("unauthorized", "нужен вход через GitHub (заголовок Authorization: Bearer <токен>)")
    scheme, _, token = header.partition(" ")
    token = token.strip()
    if scheme.lower() not in ("bearer", "token") or not token or len(token) > 512 or not token.isascii():
        raise ProtocolError("unauthorized", "заголовок Authorization не разобран")
    return token


def parse_user(body: dict) -> GithubUser:
    login, uid, created = body.get("login"), body.get("id"), body.get("created_at")
    if not isinstance(login, str) or not LOGIN_RE.match(login) or not isinstance(uid, int) or not isinstance(created, str):
        raise ProtocolError("unauthorized", "GitHub вернул неожиданный ответ")
    if body.get("type", "User") != "User":
        raise ProtocolError("forbidden", "участвовать могут только личные аккаунты GitHub")
    ts = datetime.fromisoformat(created.replace("Z", "+00:00")).timestamp()
    return GithubUser(login=login, id=uid, created_at=ts)


class GithubVerifier:
    def __init__(self, http: httpx.Client | None = None, *, api: str = API, cache_seconds: float = 600.0,
                 min_account_age_days: float = 30.0, clock: Callable[[], float] = time.time):
        self.http = http or httpx.Client(timeout=15.0, trust_env=False)
        self.api, self.ttl, self.min_age, self.clock = api.rstrip("/"), cache_seconds, min_account_age_days, clock
        self.cache: dict[str, tuple[float, GithubUser]] = {}
        self.lock = threading.Lock()

    def _fetch(self, token: str) -> GithubUser:
        try:
            r = self.http.get(f"{self.api}/user", headers={"Authorization": f"Bearer {token}",
                                                           "Accept": "application/vnd.github+json",
                                                           "X-GitHub-Api-Version": "2022-11-28"})
        except httpx.HTTPError as e:
            raise ProtocolError("unavailable", f"GitHub недоступен: {type(e).__name__}") from e
        if r.status_code == 401:
            raise ProtocolError("unauthorized", "токен GitHub недействителен или отозван: войдите заново")
        if r.status_code != 200:
            raise ProtocolError("unavailable", f"GitHub ответил {r.status_code}")
        return parse_user(r.json())

    def verify(self, authorization: str | None) -> GithubUser:
        token = bearer_token(authorization)
        key = hashlib.sha256(token.encode()).hexdigest()
        now = self.clock()
        with self.lock:
            hit = self.cache.get(key)
            if hit and now - hit[0] < self.ttl:
                user = hit[1]
            else:
                user = None
        if user is None:
            user = self._fetch(token)
            with self.lock:
                self.cache[key] = (now, user)
                if len(self.cache) > 10_000:
                    for k in [k for k, (t, _) in self.cache.items() if now - t >= self.ttl]:
                        self.cache.pop(k, None)
        if now - user.created_at < self.min_age * 86400:
            raise ProtocolError("forbidden", f"аккаунту GitHub меньше {self.min_age:g} дней: так сервер защищается "
                                             "от подставных аккаунтов")
        return user
