"""Вход через GitHub с устройства (OAuth device flow, https://docs.github.com/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps#device-flow).

Приложение показывает короткий код и открывает github.com/login/device; пользователь вводит код у себя в браузере.
Токен без прав (scope пустой: виден только публичный профиль) хранится в <каталог установки>/github-token (0600)
и уходит только на сервер обучения, который по нему узнаёт логин. Выход = удалить файл.
"""
from __future__ import annotations

import os
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

import httpx

DEVICE_CODE_URL = "https://github.com/login/device/code"
TOKEN_URL = "https://github.com/login/oauth/access_token"
GRANT = "urn:ietf:params:oauth:grant-type:device_code"
TOKEN_FILE = "github-token"
LOGIN_FILE = "github-login"
USER_URL = "https://api.github.com/user"


@dataclass
class DeviceCode:
    device_code: str
    user_code: str
    verification_uri: str
    interval: float
    expires_in: float


class LoginError(Exception):
    pass


def start(client_id: str, http: httpx.Client) -> DeviceCode:
    if not client_id:
        raise LoginError("сервер не сообщил Client ID для входа через GitHub")
    r = http.post(DEVICE_CODE_URL, data={"client_id": client_id, "scope": ""}, headers={"Accept": "application/json"})
    r.raise_for_status()
    b = r.json()
    if "device_code" not in b:
        raise LoginError("GitHub не выдал код входа (проверьте, что у приложения GitHub включён Device Flow)")
    return DeviceCode(b["device_code"], b["user_code"], b["verification_uri"], float(b.get("interval", 5)),
                      float(b.get("expires_in", 900)))


def poll(client_id: str, code: DeviceCode, http: httpx.Client, *, sleep: Callable[[float], None] = time.sleep,
         clock: Callable[[], float] = time.monotonic, should_stop: Callable[[], bool] = lambda: False) -> str:
    deadline, interval = clock() + code.expires_in, code.interval
    while clock() < deadline:
        if should_stop():
            raise LoginError("вход отменён")
        sleep(interval)
        r = http.post(TOKEN_URL, data={"client_id": client_id, "device_code": code.device_code, "grant_type": GRANT},
                      headers={"Accept": "application/json"})
        r.raise_for_status()
        b = r.json()
        if b.get("access_token"):
            return b["access_token"]
        err = b.get("error")
        if err == "authorization_pending":
            continue
        if err == "slow_down":
            interval = float(b.get("interval", interval + 5))
            continue
        raise LoginError({"expired_token": "код истёк, начните вход заново",
                          "access_denied": "вход отклонён на GitHub"}.get(err, "вход через GitHub не удался"))
    raise LoginError("код истёк, начните вход заново")


def fetch_login(token: str, http: httpx.Client) -> str:
    """Логин для показа в приложении; запрос идёт только на сам GitHub."""
    r = http.get(USER_URL, headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json"})
    r.raise_for_status()
    login = r.json().get("login")
    if not isinstance(login, str) or not login:
        raise LoginError("GitHub не сообщил логин")
    return login


def save_login(home: Path, login: str) -> None:
    (Path(home) / LOGIN_FILE).write_text(login + "\n")


def load_login(home: Path) -> str | None:
    try:
        return (Path(home) / LOGIN_FILE).read_text().strip() or None
    except OSError:
        return None


def token_path(home: Path) -> Path:
    return Path(home) / TOKEN_FILE


def save_token(home: Path, token: str) -> None:
    home = Path(home)
    home.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp = token_path(home).with_suffix(".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(token.strip() + "\n")
    os.replace(tmp, token_path(home))


def load_token(home: Path) -> str | None:
    try:
        t = token_path(home).read_text().strip()
    except OSError:
        return None
    return t or None


def logout(home: Path) -> None:
    token_path(home).unlink(missing_ok=True)
    (Path(home) / LOGIN_FILE).unlink(missing_ok=True)
