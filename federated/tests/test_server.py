import json
import sqlite3
import time

import numpy as np
import pytest

from protocol.adapter_io import load_adapter, l2_norm
from protocol.identity import Identity
from protocol.modelsig import verify_model_info, public_b64
from protocol.schema import ModelInfo
from server import admin
from server.aggregate import run_round
from server.config import load_config
from tests.helpers import delta_with_norm, make_server, make_update, post


def test_health_and_latest(tmp_path):
    spec, d, store, c = make_server(tmp_path)
    assert c.get("/v1/health").json() == {"status": "ok", "protocol": 1, "latest_version": 1}
    info = ModelInfo.model_validate(c.get("/v1/model/latest").json())
    verify_model_info(info, public_b64(store.signing_key()))
    data = c.get(info.download_path).content
    assert len(data) == info.size_bytes
    assert c.get("/v1/model/99/adapter").status_code == 404


def test_accept_and_duplicate_idempotent(tmp_path):
    spec, d, store, c = make_server(tmp_path)
    p = make_update(spec, Identity.generate(), 1, 1.0, 1)
    r1 = post(c, p)
    assert r1.status_code == 200 and r1.json()["status"] == "accepted"
    r2 = post(c, p)
    assert r2.status_code == 200 and r2.json()["status"] == "duplicate"
    assert r2.json()["update_id"] == r1.json()["update_id"]


def test_second_different_update_same_base_conflicts(tmp_path):
    spec, d, store, c = make_server(tmp_path)
    ident = Identity.generate()
    assert post(c, make_update(spec, ident, 1, 1.0, 1)).status_code == 200
    r = post(c, make_update(spec, ident, 1, 1.0, 2))
    assert r.status_code == 409 and r.json()["error"] == "conflict"


def test_bad_signature_and_garbage(tmp_path):
    spec, d, store, c = make_server(tmp_path)
    p = make_update(spec, Identity.generate(), 1, 1.0, 1)
    env = json.loads(p.envelope)
    env["manifest"]["num_examples"] = 7
    r = c.post("/v1/updates", files={"manifest": ("m", json.dumps(env).encode(), "application/json"), "payload": ("p", p.payload)})
    assert r.status_code == 401 and r.json()["error"] == "bad_signature"
    r = c.post("/v1/updates", files={"manifest": ("m", b"not json"), "payload": ("p", p.payload)})
    assert r.status_code == 422 and r.json()["error"] == "bad_schema"
    r = c.post("/v1/updates", data={"x": "y"})
    assert r.status_code == 422


def test_oversize_body_rejected_before_parsing(tmp_path):
    spec, d, store, c = make_server(tmp_path)
    r = c.post("/v1/updates", files={"manifest": ("m", b"{}"), "payload": ("p", b"\0" * (spec.max_payload_bytes() + 200_000))})
    assert r.status_code == 413 and r.json()["error"] == "too_large"


def test_stale_base_rejected(tmp_path):
    spec, d, store, c = make_server(tmp_path)
    for i in range(3):
        assert post(c, make_update(spec, Identity.generate(), 1, 1.0, i)).status_code == 200
    assert run_round(store, load_config(d)).published
    r = post(c, make_update(spec, Identity.generate(), 1, 1.0, 9))
    assert r.status_code == 409 and r.json()["error"] == "stale_base" and r.json()["latest_version"] == 2
    r = post(c, make_update(spec, Identity.generate(), 77, 1.0, 9))
    assert r.status_code == 409 and r.json()["error"] == "unknown_base"


def test_duplicate_after_round_is_still_ok(tmp_path):
    spec, d, store, c = make_server(tmp_path)
    ps = [make_update(spec, Identity.generate(), 1, 1.0, i) for i in range(3)]
    for p in ps:
        assert post(c, p).status_code == 200
    assert run_round(store, load_config(d)).published
    assert post(c, ps[0]).json()["status"] == "duplicate"   # ответ потерялся, клиент повторил


def test_poisoned_huge_update_rejected(tmp_path):
    spec, d, store, c = make_server(tmp_path)
    r = post(c, make_update(spec, Identity.generate(), 1, 1000.0, 1))
    assert r.status_code == 422 and r.json()["error"] == "norm_too_large"
    with store.db() as db:
        assert db.execute("SELECT COUNT(*) FROM updates").fetchone()[0] == 0
        assert db.execute("SELECT COUNT(*) FROM events WHERE kind='norm_too_large'").fetchone()[0] == 1


def test_poisoned_moderate_update_is_clipped_and_trimmed(tmp_path):
    spec, d, store, c = make_server(tmp_path, "[aggregation]\nmin_clients = 5\ntrim_ratio = 0.2\n[limits]\nmax_update_norm = 20.0\n")
    base_dir = delta_with_norm(spec, 1.0, 0)
    ids = [Identity.generate() for _ in range(5)]
    for i, ident in enumerate(ids[:4]):
        # честные: общее направление + шум
        dl = {k: v + 0.05 * delta_with_norm(spec, 1.0, 10 + i)[k] for k, v in base_dir.items()}
        from protocol.package import pack_update
        assert post(c, pack_update(dl, spec=spec, base_version=1, num_examples=100, identity=ident)).status_code == 200
    from protocol.package import pack_update
    poison = {k: -15.0 * v for k, v in base_dir.items()}       # норма 15 < 20: пройдёт приём
    assert post(c, pack_update(poison, spec=spec, base_version=1, num_examples=100, identity=ids[4])).status_code == 200
    res = run_round(store, load_config(d))
    assert res.published
    st = res.stats
    assert min(st["clip_scales"]) < 0.2 and max(st["trimmed_frac"]) > 0.9
    g1, g2 = load_adapter(store.version_path(1)), load_adapter(store.version_path(2))
    upd = {k: g2[k] - g1[k] for k in g1}
    dot = sum(float((upd[k] * base_dir[k]).sum()) for k in upd)
    assert dot > 0                                              # направление честных, не ядовитое


def test_not_enough_clients_no_round(tmp_path):
    spec, d, store, c = make_server(tmp_path)
    post(c, make_update(spec, Identity.generate(), 1, 1.0, 1))
    r = run_round(store, load_config(d))
    assert not r.published and store.current_version() == 1


def test_rate_limit_per_install(tmp_path):
    spec, d, store, c = make_server(tmp_path, "[limits]\nmax_updates_per_client_per_day = 2\nmax_update_norm = 20.0\n")
    ident = Identity.generate()
    # норма-нарушения тоже расходуют квоту; разные «базы» невозможны (v1 одна), поэтому считаем попытки с разным содержимым
    r1 = post(c, make_update(spec, ident, 1, 1000.0, 1))
    r2 = post(c, make_update(spec, ident, 1, 1000.0, 2))
    r3 = post(c, make_update(spec, ident, 1, 1000.0, 3))
    assert r1.status_code == 422 and r2.status_code == 422
    assert r3.status_code == 429 and "retry-after" in r3.headers


def test_banned_client_rejected(tmp_path):
    spec, d, store, c = make_server(tmp_path)
    ident = Identity.generate()
    assert post(c, make_update(spec, ident, 1, 1.0, 1)).status_code == 200
    assert admin.main(["ban", "--data-dir", str(d), ident.client_id]) == 0
    spec2 = spec
    # новая «база» невозможна без раунда, поэтому проверяем через другое содержимое: блок срабатывает раньше конфликта
    r = post(c, make_update(spec2, ident, 1, 1.0, 5))
    assert r.status_code == 403 and r.json()["error"] == "banned"


def test_round_publishes_new_version_and_deletes_payloads(tmp_path):
    spec, d, store, c = make_server(tmp_path)
    for i in range(4):
        assert post(c, make_update(spec, Identity.generate(), 1, 1.0, i)).status_code == 200
    assert list(store.incoming_dir.glob("*.safetensors"))
    res = run_round(store, load_config(d))
    assert res.published and res.version == 2 and store.current_version() == 2
    assert not list(store.incoming_dir.glob("*.safetensors"))            # хранение: дельты не остаются
    info = ModelInfo.model_validate(c.get("/v1/model/latest").json())
    verify_model_info(info, public_b64(store.signing_key()))
    assert info.version == 2 and info.round_clients == 4
    with store.db() as db:
        assert db.execute("SELECT COUNT(*) FROM updates WHERE status='aggregated' AND payload_path IS NULL").fetchone()[0] == 4


def test_rollback_creates_new_version_with_old_content(tmp_path, capsys):
    spec, d, store, c = make_server(tmp_path)
    for rnd in (1, 2):
        for i in range(3):
            assert post(c, make_update(spec, Identity.generate(), rnd, 1.0, 100 * rnd + i)).status_code == 200
        assert run_round(store, load_config(d)).published
    assert store.current_version() == 3
    pending = make_update(spec, Identity.generate(), 3, 1.0, 5)
    assert post(c, pending).status_code == 200
    assert admin.main(["rollback", "--data-dir", str(d), "--to", "1", "--reason", "тест"]) == 0
    assert store.current_version() == 4
    a1, a4 = load_adapter(store.version_path(1)), load_adapter(store.version_path(4))
    assert all(np.array_equal(a1[k], a4[k]) for k in a1)
    info = ModelInfo.model_validate(c.get("/v1/model/latest").json())
    assert info.version == 4 and info.rollback_of == 1
    assert c.get("/v1/model/3/adapter").status_code == 404                # отозвана
    r = post(c, make_update(spec, Identity.generate(), 3, 1.0, 6))        # база отозванной версии: устарела
    assert r.status_code == 409 and r.json()["latest_version"] == 4
    admin.main(["rounds", "--data-dir", str(d)])
    out = capsys.readouterr().out
    assert "rolled_back" in out
    with store.db() as db:
        assert db.execute("SELECT status FROM updates WHERE base_version=3").fetchone()[0] == "discarded"


def test_dp_round_adds_noise_and_reports_epsilon(tmp_path):
    toml = ("[aggregation]\nmin_clients = 3\nmethod = \"mean\"\nclip_norm = 1.0\n[limits]\nmax_update_norm = 20.0\n"
            "[dp]\nenabled = true\nnoise_multiplier = 2.0\ndelta = 1e-6\n")
    spec, d, store, c = make_server(tmp_path, toml)
    for i in range(3):
        assert post(c, make_update(spec, Identity.generate(), 1, 1.0, i)).status_code == 200
    res = run_round(store, load_config(d), rng=np.random.default_rng(0))
    assert res.published and res.stats["dp_formal"] and res.stats["dp_epsilon"] > 0
    assert res.stats["dp_sigma"] == pytest.approx(2.0 * 1.0 * (1 / 3))


def test_dp_budget_stops_publishing(tmp_path):
    toml = ("[aggregation]\nmin_clients = 3\nmethod = \"mean\"\nclip_norm = 1.0\n[limits]\nmax_update_norm = 20.0\n"
            "[dp]\nenabled = true\nnoise_multiplier = 1.0\nmax_epsilon = 1.0\n")
    spec, d, store, c = make_server(tmp_path, toml)
    for i in range(3):
        post(c, make_update(spec, Identity.generate(), 1, 1.0, i))
    res = run_round(store, load_config(d))
    assert not res.published and "DP-бюджет" in res.reason and store.current_version() == 1


def test_server_refuses_non_loopback():
    from server.run import is_loopback, main
    assert is_loopback("127.0.0.1") and is_loopback("localhost") and is_loopback("::1")
    assert not is_loopback("0.0.0.0") and not is_loopback("192.168.1.5")
    assert main(["--data-dir", "/nonexistent", "--host", "0.0.0.0"]) == 2


def test_prune_removes_old_metadata_only(tmp_path):
    spec, d, store, c = make_server(tmp_path)
    for i in range(3):
        assert post(c, make_update(spec, Identity.generate(), 1, 1.0, i)).status_code == 200
    run_round(store, load_config(d))
    with store.db() as db:
        db.execute("UPDATE updates SET received_at = received_at - 400*86400")
        db.execute("UPDATE clients SET first_seen = first_seen - 400*86400")
    assert admin.main(["prune", "--data-dir", str(d), "--older-than-days", "180"]) == 0
    with store.db() as db:
        assert db.execute("SELECT COUNT(*) FROM updates").fetchone()[0] == 0
        assert db.execute("SELECT COUNT(*) FROM versions").fetchone()[0] == 2     # версии модели не трогаются
