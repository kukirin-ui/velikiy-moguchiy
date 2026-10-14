import json
from pathlib import Path

import numpy as np
from starlette.testclient import TestClient

from client.config import ClientConfig
from protocol.identity import Identity
from protocol.modelsig import public_b64
from protocol.package import pack_update
from protocol.spec import AdapterSpec, TensorSpec, save_spec
from server import admin
from server.app import create_app
from server.store import Store


def tiny_spec() -> AdapterSpec:
    return AdapterSpec(spec_id="tiny-test", rank=2, alpha=4.0, tensors=[
        TensorSpec(name="m0.A", shape=[2, 8], kind="lora_A"), TensorSpec(name="m0.B", shape=[8, 2], kind="lora_B"),
        TensorSpec(name="m1.A", shape=[2, 8], kind="lora_A"), TensorSpec(name="m1.B", shape=[8, 2], kind="lora_B")])


def make_server(tmp_path: Path, toml: str = "[aggregation]\nmin_clients = 3\n[limits]\nmax_update_norm = 20.0\n"):
    spec = tiny_spec()
    sp = tmp_path / "spec.json"
    save_spec(spec, sp)
    d = tmp_path / "srv"
    assert admin.main(["init", "--data-dir", str(d), "--spec", str(sp)]) == 0
    (d / "server.toml").write_text(toml)
    app = create_app(d)
    return spec, d, Store(d), TestClient(app)


def delta_with_norm(spec: AdapterSpec, norm: float, seed: int) -> dict:
    rng = np.random.default_rng(seed)
    d = {t.name: rng.standard_normal(t.shape).astype(np.float32) for t in spec.delta_tensors}
    n = np.sqrt(sum(float((v.astype(np.float64) ** 2).sum()) for v in d.values()))
    return {k: v * (norm / n) for k, v in d.items()}


def post(client: TestClient, packed):
    return client.post("/v1/updates", files={"manifest": ("m.json", packed.envelope, "application/json"),
                                              "payload": ("p.safetensors", packed.payload, "application/octet-stream")})


def make_update(spec, ident: Identity, base: int, norm: float, seed: int, n_ex: int = 100):
    return pack_update(delta_with_norm(spec, norm, seed), spec=spec, base_version=base, num_examples=n_ex, identity=ident)
