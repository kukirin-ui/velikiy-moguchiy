"""Упаковка и проверка обновления: safetensors (fp16) + подписанный манифест (Ed25519).

pack_update  (клиент): дельта fp32 -> fp16 safetensors, манифест, подпись.
verify_update (сервер, и тесты): размеры, схема, соответствие ключа и client_id, подпись, хэш и размер нагрузки,
спецификация, имена/формы/dtype/конечность, L2-норма. Базовую версию и лимиты сервер проверяет сам (нужна БД).

Подписываются байты  DOMAIN + canonical_json(manifest); манифест содержит payload_sha256, значит подпись
покрывает и нагрузку.
"""
from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from typing import Mapping

import numpy as np
from pydantic import ValidationError

from .adapter_io import dumps_adapter, l2_norm, loads_adapter, validate_against_spec
from .canonical import canonical_json
from .errors import ProtocolError
from .identity import Identity, b64d, b64e, client_id_from_public, verify_signature
from .schema import SignedManifest, UpdateManifest
from .spec import AdapterSpec

DOMAIN = b"velikiy-moguchiy-fl/update/v2\n"
MAX_ENVELOPE_BYTES = 8 * 1024
FP16_MAX = 65000.0


@dataclass
class PackedUpdate:
    envelope: bytes   # JSON: {"manifest": ..., "signature": ...}
    payload: bytes    # safetensors fp16
    manifest: UpdateManifest


@dataclass
class VerifiedUpdate:
    manifest: UpdateManifest
    tensors: dict[str, np.ndarray]  # fp16, проверены
    norm: float                      # L2 по всем тензорам


def _signing_bytes(manifest: UpdateManifest) -> bytes:
    return DOMAIN + canonical_json(manifest.model_dump(mode="json"))


def to_fp16(delta: Mapping[str, np.ndarray]) -> dict[str, np.ndarray]:
    out = {}
    for k, v in delta.items():
        a = np.asarray(v, np.float32)
        if not np.isfinite(a).all():
            raise ProtocolError("nonfinite", f"{k}: NaN/Inf в дельте, отправка отменена")
        if np.abs(a).max(initial=0.0) > FP16_MAX:
            raise ProtocolError("nonfinite", f"{k}: значения не помещаются в fp16")
        out[k] = a.astype(np.float16)
    return out


def pack_update(delta: Mapping[str, np.ndarray], *, spec: AdapterSpec, base_version: int, num_examples: int,
                identity: Identity) -> PackedUpdate:
    t16 = to_fp16(delta)
    validate_against_spec(t16, spec, delta=True, dtype=np.float16)
    payload = dumps_adapter(t16)  # без metadata: нечему утекать
    manifest = UpdateManifest(
        client_id=identity.client_id, public_key=identity.public_b64, base_version=base_version,
        spec_id=spec.spec_id, spec_hash=spec.hash, num_examples=num_examples,
        payload_sha256=hashlib.sha256(payload).hexdigest(), payload_bytes=len(payload))
    sig = identity.sign(_signing_bytes(manifest))
    signed = SignedManifest(manifest=manifest, signature=b64e(sig))
    return PackedUpdate(envelope=signed.model_dump_json().encode(), payload=payload, manifest=manifest)


def parse_envelope(envelope: bytes) -> SignedManifest:
    if len(envelope) > MAX_ENVELOPE_BYTES:
        raise ProtocolError("too_large", f"манифест {len(envelope)} Б больше {MAX_ENVELOPE_BYTES}")
    try:
        return SignedManifest.model_validate(json.loads(envelope))
    except (ValueError, ValidationError) as e:
        raise ProtocolError("bad_schema", f"манифест не прошёл схему: {str(e)[:200]}") from e


def verify_signature_and_identity(sm: SignedManifest) -> None:
    try:
        pub = b64d(sm.manifest.public_key)
        sig = b64d(sm.signature)
    except Exception as e:  # noqa: BLE001
        raise ProtocolError("bad_schema", "base64 ключа или подписи некорректен") from e
    if len(pub) != 32 or len(sig) != 64:
        raise ProtocolError("bad_schema", "длина ключа или подписи неверна")
    if client_id_from_public(pub) != sm.manifest.client_id:
        raise ProtocolError("bad_signature", "client_id не соответствует публичному ключу")
    if not verify_signature(pub, sig, _signing_bytes(sm.manifest)):
        raise ProtocolError("bad_signature", "подпись не сходится")


def verify_update(envelope: bytes, payload: bytes, spec: AdapterSpec) -> VerifiedUpdate:
    if len(payload) > spec.max_payload_bytes():
        raise ProtocolError("too_large", f"нагрузка {len(payload)} Б больше предела {spec.max_payload_bytes()}")
    sm = parse_envelope(envelope)
    verify_signature_and_identity(sm)
    m = sm.manifest
    if m.payload_bytes != len(payload) or m.payload_sha256 != hashlib.sha256(payload).hexdigest():
        raise ProtocolError("bad_payload", "размер или SHA-256 нагрузки не совпали с манифестом")
    if m.spec_id != spec.spec_id or m.spec_hash != spec.hash:
        raise ProtocolError("spec_mismatch", "спецификация адаптера в манифесте не совпала с серверной")
    tensors = loads_adapter(payload)
    validate_against_spec(tensors, spec, delta=True, dtype=np.float16)
    return VerifiedUpdate(manifest=m, tensors=tensors, norm=l2_norm(tensors))
