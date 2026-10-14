"""Подпись описания глобального адаптера ключом сервера (signing key). Публичный ключ закреплён в клиенте."""
from __future__ import annotations

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from .canonical import canonical_json
from .errors import ProtocolError
from .identity import b64d, b64e, verify_signature
from .schema import ModelInfo

DOMAIN = b"velikiy-moguchiy-fl/model/v2\n"


def _bytes(info_part: dict) -> bytes:
    return DOMAIN + canonical_json(info_part)


def sign_model_info(info_part: dict, key: Ed25519PrivateKey) -> str:
    return b64e(key.sign(_bytes(info_part)))


def public_b64(key: Ed25519PrivateKey) -> str:
    return b64e(key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw))


def verify_model_info(info: ModelInfo, pinned_public_b64: str) -> None:
    try:
        ok = verify_signature(b64d(pinned_public_b64), b64d(info.signature), _bytes(info.signed_part()))
    except Exception as e:  # noqa: BLE001
        raise ProtocolError("bad_signature", "подпись модели не разобрана") from e
    if not ok:
        raise ProtocolError("bad_signature", "подпись глобального адаптера не сходится с закреплённым ключом сервера")
