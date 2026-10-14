import base64
import json
import pickle
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

from hub.tasks import TaskClaims, sign_claims, verify_token
from protocol.contribution import Contribution, sign_contribution
from protocol.identity import Identity
from protocol.package import pack_update
from tests.helpers import delta_with_norm, tiny_spec

WORKER = Path(__file__).resolve().parents[1] / "worker"
b64 = lambda b: base64.b64encode(b).decode()  # noqa: E731


def test_worker_defaults_are_generated_from_python():
    sys.path.insert(0, str(WORKER))
    from gen_defaults import OUT, render
    assert OUT.read_text(encoding="utf8") == render(), "запустите python worker/gen_defaults.py"


@pytest.mark.skipif(shutil.which("node") is None, reason="нужен Node.js")
def test_worker_accepts_what_the_python_client_signs(tmp_path):
    spec, ident, secret, now = tiny_spec(), Identity.generate(), "k" * 32, 1_800_000_000
    p = pack_update(delta_with_norm(spec, 1.0, 0), spec=spec, base_version=4, num_examples=7, identity=ident)
    c = Contribution(client_id=ident.client_id, payload_sha256=p.manifest.payload_sha256, base_version=4, task_token="t",
                     data_seconds=60.0, training_steps=50, num_clips=7)
    contribution = sign_contribution(c, ident)
    tampered = json.loads(contribution)
    tampered["contribution"]["data_seconds"] = 61.5
    token = sign_claims(TaskClaims("py1", "Alice", 4, 120.5, 50, now + 100, 12), secret.encode())
    fx = {"manifest": b64(p.envelope), "payload": b64(p.payload), "contribution": b64(contribution),
          "tampered_contribution": b64(json.dumps(tampered).encode()), "pickle": b64(pickle.dumps({"x": 1})),
          "spec": {"tensors": [{"name": t.name, "shape": t.shape} for t in spec.delta_tensors]},
          "token": token, "secret": secret, "login": "alice", "base": 4, "now": now}
    f = tmp_path / "fx.json"
    f.write_text(json.dumps(fx))
    r = subprocess.run(["node", str(WORKER / "tools" / "compat.mjs"), str(f)], capture_output=True, text=True, timeout=60)
    assert r.returncode == 0, r.stderr
    out = json.loads(r.stdout)
    assert out == {**out, "manifest": ident.client_id, "contribution": 60, "payload": "ok",
                   "tampered_contribution": "bad_signature", "pickle": "bad_payload", "python_token": ["py1", 12]}
    claims = verify_token(out["js_token"], secret.encode(), login="Alice", base_version=4, now=now)
    assert (claims.task_id, claims.seconds_max, claims.steps_max, claims.segments) == ("js1", 120.0, 50, 30)
