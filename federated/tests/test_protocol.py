import json

import numpy as np
import pytest

from protocol.errors import ProtocolError
from protocol.identity import Identity, b64e
from protocol.package import pack_update, verify_update
from protocol.schema import UpdateManifest
from protocol.spec import AdapterSpec, load_spec
from tests.helpers import delta_with_norm, tiny_spec

from pathlib import Path

REAL_SPEC = Path(__file__).resolve().parent.parent / "protocol" / "specs" / "multivsr_lora_r16.json"


def packed(**kw):
    spec = tiny_spec()
    ident = kw.pop("ident", Identity.generate())
    return spec, ident, pack_update(delta_with_norm(spec, 1.0, 0), spec=spec, base_version=kw.get("base", 3),
                                    num_examples=kw.get("n", 50), identity=ident)


def test_roundtrip_and_fields():
    spec, ident, p = packed()
    v = verify_update(p.envelope, p.payload, spec)
    assert v.manifest.base_version == 3 and v.manifest.num_examples == 50
    assert v.manifest.client_id == ident.client_id
    assert abs(v.norm - 1.0) < 1e-2          # fp16-округление
    assert all(a.dtype == np.float16 for a in v.tensors.values())


def test_manifest_has_exactly_the_allowed_fields():
    assert set(UpdateManifest.model_fields) == {"schema_version", "client_id", "public_key", "base_version", "spec_id",
                                                 "spec_hash", "num_examples", "payload_sha256", "payload_bytes", "payload_dtype"}


def test_extra_field_in_manifest_rejected():
    spec, _, p = packed()
    env = json.loads(p.envelope)
    env["manifest"]["device_model"] = "MacBookPro"
    with pytest.raises(ProtocolError) as e:
        verify_update(json.dumps(env).encode(), p.payload, spec)
    assert e.value.code == "bad_schema"


def test_tampered_manifest_fails_signature():
    spec, _, p = packed()
    env = json.loads(p.envelope)
    env["manifest"]["num_examples"] = 99999
    with pytest.raises(ProtocolError) as e:
        verify_update(json.dumps(env).encode(), p.payload, spec)
    assert e.value.code == "bad_signature"


def test_signature_from_other_key_rejected():
    spec, _, p = packed()
    other = Identity.generate()
    env = json.loads(p.envelope)
    env["signature"] = b64e(other.sign(b"whatever"))
    with pytest.raises(ProtocolError) as e:
        verify_update(json.dumps(env).encode(), p.payload, spec)
    assert e.value.code == "bad_signature"


def test_public_key_not_matching_client_id_rejected():
    spec, _, p = packed()
    env = json.loads(p.envelope)
    env["manifest"]["public_key"] = Identity.generate().public_b64
    with pytest.raises(ProtocolError) as e:
        verify_update(json.dumps(env).encode(), p.payload, spec)
    assert e.value.code == "bad_signature"


def test_tampered_payload_rejected():
    spec, _, p = packed()
    bad = bytearray(p.payload)
    bad[-1] ^= 0xFF
    with pytest.raises(ProtocolError) as e:
        verify_update(p.envelope, bytes(bad), spec)
    assert e.value.code == "bad_payload"


def test_spec_mismatch_rejected():
    spec, _, p = packed()
    other = AdapterSpec.model_validate({**spec.model_dump(), "rank": 4})
    with pytest.raises(ProtocolError) as e:
        verify_update(p.envelope, p.payload, other)
    assert e.value.code == "spec_mismatch"


def test_nan_delta_not_packable_and_oversize_rejected():
    spec = tiny_spec()
    d = delta_with_norm(spec, 1.0, 0)
    d["m0.A"][0, 0] = np.nan
    with pytest.raises(ProtocolError) as e:
        pack_update(d, spec=spec, base_version=1, num_examples=1, identity=Identity.generate())
    assert e.value.code == "nonfinite"
    _, _, p = packed()
    with pytest.raises(ProtocolError) as e:
        verify_update(p.envelope, p.payload + b"\0" * (spec.max_payload_bytes() + 1), spec)
    assert e.value.code == "too_large"


def test_wrong_shape_payload_rejected():
    spec = tiny_spec()
    ident = Identity.generate()
    d = delta_with_norm(spec, 1.0, 0)
    bigger = AdapterSpec.model_validate({**spec.model_dump(), "tensors": [
        {**t.model_dump(), "shape": [t.shape[0] + 1, t.shape[1]]} if t.name == "m0.A" else t.model_dump() for t in spec.tensors]})
    d["m0.A"] = np.zeros((3, 8), np.float32)
    with pytest.raises(ProtocolError) as e:
        pack_update(d, spec=spec, base_version=1, num_examples=1, identity=ident)
    assert e.value.code == "spec_mismatch"


def test_identity_persisted_with_0600(tmp_path):
    a = Identity.load_or_create(tmp_path / "h")
    b = Identity.load_or_create(tmp_path / "h")
    assert a.client_id == b.client_id
    assert ((tmp_path / "h" / "identity.key").stat().st_mode & 0o777) == 0o600


def test_real_multivsr_spec():
    s = load_spec(REAL_SPEC)
    assert len(s.tensors) == 144 and s.num_params == 1_769_472
    assert s.max_payload_bytes() < 3_700_000
