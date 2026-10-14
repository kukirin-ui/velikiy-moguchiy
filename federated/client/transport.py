"""HTTPS-транспорт клиента: закрепление ключа сертификата сервера (SPKI pinning), повторы с экспоненциальной задержкой.

Закрепление выполняется при КАЖДОМ TLS-рукопожатии, до отправки первого байта запроса: если SHA-256 от
SubjectPublicKeyInfo сертификата не совпал с закреплённым, соединение закрывается (тело обновления не уходит).
http:// допустим только для localhost при allow_insecure_localhost (разработка, симуляция).
"""
from __future__ import annotations

import hashlib
import ipaddress
import random
import ssl
import time
from typing import Callable
from urllib.parse import urlparse

import httpx
from cryptography import x509
from cryptography.hazmat.primitives import serialization

from client.config import ServerCfg
from protocol.errors import PERMANENT, ProtocolError


class PinMismatchError(ssl.SSLError):
    pass


def spki_sha256(der_cert: bytes) -> str:
    cert = x509.load_der_x509_certificate(der_cert)
    spki = cert.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
    return hashlib.sha256(spki).hexdigest()


class PinnedSSLContext(ssl.SSLContext):
    pin: str = ""

    def wrap_socket(self, sock, *args, **kwargs):  # noqa: D401
        s = super().wrap_socket(sock, *args, **kwargs)
        try:
            got = spki_sha256(s.getpeercert(binary_form=True))
        except Exception:
            s.close()
            raise
        if got != self.pin.lower():
            s.close()
            raise PinMismatchError(f"ключ сертификата сервера не совпал с закреплённым ({got[:12]}… != {self.pin[:12]}…)")
        return s


def is_localhost(host: str) -> bool:
    if host == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def build_http_client(cfg: ServerCfg) -> httpx.Client:
    u = urlparse(cfg.url)
    if u.scheme == "http":
        if not (cfg.allow_insecure_localhost and is_localhost(u.hostname or "")):
            raise ValueError("http:// разрешён только для localhost при allow_insecure_localhost=true; нужен https://")
        return httpx.Client(base_url=cfg.url, timeout=cfg.timeout_seconds, trust_env=False)
    if u.scheme != "https":
        raise ValueError(f"неподдерживаемая схема {u.scheme}")
    if not cfg.tls_spki_sha256:
        if not cfg.tls_system_trust:
            raise ValueError("для https:// нужен tls_spki_sha256 (закрепление ключа сервера)")
        # the downloaded adapter is still checked against the pinned model-signing key
        import certifi  # an httpx dependency; python.org builds on macOS have no system CA file
        ctx = ssl.create_default_context(cafile=certifi.where())
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        return httpx.Client(base_url=cfg.url, timeout=cfg.timeout_seconds, verify=ctx, trust_env=False)
    ctx = PinnedSSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.pin = cfg.tls_spki_sha256
    ctx.check_hostname = True
    ctx.verify_mode = ssl.CERT_REQUIRED
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    if cfg.tls_ca_file:
        ctx.load_verify_locations(cafile=cfg.tls_ca_file)
    else:
        ctx.load_default_certs()
    return httpx.Client(base_url=cfg.url, timeout=cfg.timeout_seconds, verify=ctx, trust_env=False)


def _is_pin_failure(exc: BaseException) -> bool:
    seen = set()
    while exc is not None and id(exc) not in seen:
        if isinstance(exc, PinMismatchError):
            return True
        seen.add(id(exc))
        exc = exc.__cause__ or exc.__context__
    return False


class Transport:
    def __init__(self, cfg: ServerCfg, *, client: httpx.Client | None = None,
                 sleep: Callable[[float], None] = time.sleep, rng: Callable[[], float] = random.random):
        self.cfg = cfg
        self.http = client or build_http_client(cfg)
        self.sleep, self.rng = sleep, rng

    def close(self) -> None:
        self.http.close()

    def _delay(self, attempt: int) -> float:
        base = min(self.cfg.retry_max_sleep_seconds, self.cfg.retry_base_seconds * (2 ** attempt))
        return base * (0.5 + 0.5 * self.rng())

    @staticmethod
    def _error(resp: httpx.Response) -> ProtocolError:
        try:
            b = resp.json()
            extra = {k: v for k, v in b.items() if k not in ("error", "message")}
            if "latest_version" in b:
                extra["latest_version"] = b["latest_version"]
            return ProtocolError(b.get("error", "server_error"), b.get("message", ""), http_status=resp.status_code, **extra)
        except Exception:  # noqa: BLE001
            return ProtocolError("server_error", f"HTTP {resp.status_code}", http_status=resp.status_code)

    def request(self, method: str, path: str, **kw) -> httpx.Response:
        """Повторяет при сетевых сбоях, 5xx и 429 (с учётом Retry-After, если он не больше потолка задержки).
        Постоянные ошибки протокола (4xx) поднимаются сразу как ProtocolError."""
        last: Exception | None = None
        for attempt in range(self.cfg.retry_attempts):
            try:
                resp = self.http.request(method, path, **kw)
            except httpx.TransportError as e:
                if _is_pin_failure(e):
                    raise ProtocolError("bad_signature", "закреплённый ключ TLS сервера не совпал: соединение отвергнуто") from e
                last = e
                if attempt + 1 < self.cfg.retry_attempts:
                    self.sleep(self._delay(attempt))
                continue
            if resp.status_code < 400:
                return resp
            if resp.status_code == 429:
                ra = float(resp.headers.get("Retry-After", "0") or 0)
                if ra > self.cfg.retry_max_sleep_seconds:
                    raise self._error(resp)  # лимит на сутки: ждать внутри вызова бессмысленно
                last = self._error(resp)
                if attempt + 1 < self.cfg.retry_attempts:
                    self.sleep(max(ra, self._delay(attempt)))
                continue
            if resp.status_code >= 500:
                last = self._error(resp)
                if attempt + 1 < self.cfg.retry_attempts:
                    self.sleep(self._delay(attempt))
                continue
            err = self._error(resp)
            raise err
        if isinstance(last, ProtocolError):
            raise last
        raise ProtocolError("server_error", f"сервер недоступен после {self.cfg.retry_attempts} попыток: {type(last).__name__}")


__all__ = ["Transport", "build_http_client", "PinMismatchError", "spki_sha256", "PERMANENT"]
