"""Ключи установки: пара Ed25519 создаётся при первом запуске и хранится локально (права 0600).

client_id = первые 16 байт SHA-256 от публичного ключа (hex, 32 символа). Это псевдоним без связи с аккаунтом,
именем, устройством: по нему сервер считает лимиты и проверяет подпись. Приватный ключ из каталога не выходит.
(В приложении позже: Keychain вместо файла, см. docs/DESIGN.md.)
"""
from __future__ import annotations

import base64
import hashlib
import os
from dataclasses import dataclass
from pathlib import Path

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey

KEY_FILE = "identity.key"


def b64e(b: bytes) -> str:
    return base64.b64encode(b).decode("ascii")


def b64d(s: str) -> bytes:
    return base64.b64decode(s.encode("ascii"), validate=True)


def client_id_from_public(pub_raw: bytes) -> str:
    return hashlib.sha256(pub_raw).digest()[:16].hex()


@dataclass
class Identity:
    private_key: Ed25519PrivateKey

    @property
    def public_raw(self) -> bytes:
        return self.private_key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)

    @property
    def public_b64(self) -> str:
        return b64e(self.public_raw)

    @property
    def client_id(self) -> str:
        return client_id_from_public(self.public_raw)

    def sign(self, data: bytes) -> bytes:
        return self.private_key.sign(data)

    @classmethod
    def generate(cls) -> "Identity":
        return cls(Ed25519PrivateKey.generate())

    @classmethod
    def load_or_create(cls, home: Path) -> "Identity":
        """Читает ключ из home/identity.key, при отсутствии создаёт (атомарно, 0600)."""
        home = Path(home)
        home.mkdir(parents=True, exist_ok=True, mode=0o700)
        path = home / KEY_FILE
        if path.exists():
            raw = base64.b64decode(path.read_text().strip())
            if len(raw) != 32:
                raise ValueError(f"{path}: ожидалось 32 байта приватного ключа")
            return cls(Ed25519PrivateKey.from_private_bytes(raw))
        ident = cls.generate()
        raw = ident.private_key.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw,
                                              serialization.NoEncryption())
        tmp = path.with_suffix(".tmp")
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(base64.b64encode(raw).decode("ascii") + "\n")
        os.replace(tmp, path)
        return ident


def verify_signature(public_raw: bytes, signature: bytes, data: bytes) -> bool:
    try:
        Ed25519PublicKey.from_public_bytes(public_raw).verify(signature, data)
        return True
    except (InvalidSignature, ValueError):
        return False
