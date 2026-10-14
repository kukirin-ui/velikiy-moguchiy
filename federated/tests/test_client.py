import datetime
import json
import os
import shutil
import socket
import ssl
import threading
import time
from dataclasses import replace
from pathlib import Path

import httpx
import numpy as np
import pytest
import uvicorn
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID
from starlette.testclient import TestClient

from client import consent, guard
from client.config import ClientConfig, GuardCfg, ScheduleCfg, ServerCfg, load_config
from client.downloader import AdapterStore, ModelSync
from client.power import Snapshot, SystemProbe, parse_hid_idle_seconds, parse_low_power, parse_on_ac
from client.runner import FederatedClient
from client.scheduler import ActiveClock, Monitor, evaluate
from client.trainer import StubTrainer, train_lora
from client.transport import Transport, spki_sha256
from client.uploader import upload_update
from protocol.adapter_io import load_adapter, save_adapter
from protocol.errors import ProtocolError
from protocol.identity import Identity
from protocol.modelsig import public_b64
from server.aggregate import run_round
from server.app import create_app
from server.config import load_config as load_server_config
from tests.helpers import make_server, make_update, tiny_spec

BATT_AC = "Now drawing from 'AC Power'\n -InternalBattery-0 (id=22872163)\t37%; charging; (no estimate) present: true\n"
BATT_BAT = "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t80%; discharging; 3:10 remaining present: true\n"
PMSET_G = " powermode            2\n sleep 1\n lowpowermode 0\n"
IOREG = '    | | |   "HIDIdleTime" = 6627891833\n    | |   "HIDIdleTime" = 31000000000\n'


# --- питание / простой ---
def test_power_parsers():
    assert parse_on_ac(BATT_AC) and not parse_on_ac(BATT_BAT) and not parse_on_ac("")
    assert not parse_low_power(PMSET_G)
    assert parse_low_power(" lowpowermode 1\n") and parse_low_power(" powermode 1\n")
    assert not parse_low_power(" powermode 2\n")
    assert parse_hid_idle_seconds(IOREG) == pytest.approx(6.627891833)   # минимум по устройствам
    assert parse_hid_idle_seconds("nothing") is None


def test_probe_with_fake_runner():
    outs = {"batt": BATT_AC, "-g": PMSET_G, "IOHIDSystem": IOREG}
    def run(cmd):
        return outs["batt"] if "batt" in cmd else outs["IOHIDSystem"] if "IOHIDSystem" in cmd else outs["-g"]
    s = SystemProbe(run).snapshot()
    assert s == Snapshot(True, False, pytest.approx(6.627891833))


@pytest.mark.skipif(shutil.which("pmset") is None, reason="нужны pmset/ioreg (macOS)")
def test_probe_real_machine_does_not_crash():
    s = SystemProbe().snapshot()          # реальные pmset/ioreg: только чтение
    assert isinstance(s.on_ac, bool) and s.idle_seconds >= 0


def test_evaluate_conditions():
    sc = ScheduleCfg(idle_minutes=10, min_hours_between_runs=24)
    ok = Snapshot(True, False, 700)
    assert evaluate(ok, sc, None, 1000).run
    d = evaluate(Snapshot(False, True, 30), sc, 900, 1000)
    assert not d.run and len(d.reasons) == 4
    assert not evaluate(ok, sc, 1000 - 3600, 1000).run                      # рано после прошлого
    assert evaluate(ok, sc, 1000 - 25 * 3600, 1000).run
    assert evaluate(ok, replace(sc, require_ac_power=False), None, 0).run
    assert not evaluate(Snapshot(True, False, 599), sc, None, 0).run         # простой 9.98 мин < 10


def test_active_clock_ignores_pauses():
    t = [0.0]
    c = ActiveClock(100, clock=lambda: t[0], gap_threshold=30, expected_period=1)
    for _ in range(10):
        t[0] += 1
        c.tick()
    assert c.active == 10
    t[0] += 3600                       # процесс заморожен охранником на час
    c.tick()
    assert c.active == 11 and c.paused_total == 3599
    paused = [False]
    c2 = ActiveClock(55, clock=lambda: t[0], paused_probe=lambda: paused[0])
    t[0] += 5; c2.tick(); paused[0] = True
    t[0] += 500; c2.tick()
    assert c2.active == 5 and c2.paused_total == 500
    paused[0] = False
    t[0] += 50; c2.tick()
    assert c2.active == 55 and c2.exceeded


def test_monitor_stops_when_user_returns_or_unplugged():
    sc = ScheduleCfg(idle_minutes=10, monitor_seconds=15)
    state = {"snap": Snapshot(True, False, 900)}
    probe = type("P", (), {"snapshot": lambda self: state["snap"]})()
    t = [0.0]
    m = Monitor(probe, sc, now=lambda: t[0])
    assert not m()
    state["snap"] = Snapshot(True, False, 2)
    assert not m()                       # проверка не чаще, чем раз в 15 с
    t[0] += 16
    assert m() and m.reason.startswith("conditions")


def test_group_pause_probe():
    ps = "  500 T\n  500 T+\n  900 S\n"
    def run(cmd):
        return "500\n" if cmd[0] == "pgrep" else ps
    assert guard.GroupPauseProbe(1, run)()
    def run2(cmd):
        return "500\n" if cmd[0] == "pgrep" else "500 T\n500 S\n"
    assert not guard.GroupPauseProbe(1, run2)()
    assert not guard.GroupPauseProbe(1, lambda c: "")()


def test_guard_wraps_command():
    cmd = guard.wrap_command(["./run.sh", "train.py"], GuardCfg(reserve_gb=6, min_free_pct=15))
    assert cmd[1].endswith("mem_guard.py") and cmd[-2:] == ["./run.sh", "train.py"] and "--reserve-gb" in cmd
    assert guard.wrap_command(["x"], GuardCfg(enabled=False)) == ["x"]


# --- транспорт ---
def _cfg(**kw):
    return ServerCfg(url="http://testserver", allow_insecure_localhost=True, retry_base_seconds=1.0, retry_max_sleep_seconds=30, **kw)


def test_http_only_for_localhost():
    from client.transport import build_http_client
    with pytest.raises(ValueError):
        build_http_client(ServerCfg(url="http://example.com"))
    with pytest.raises(ValueError):
        build_http_client(ServerCfg(url="http://127.0.0.1:1", allow_insecure_localhost=False))
    with pytest.raises(ValueError):
        build_http_client(ServerCfg(url="https://127.0.0.1:1"))     # без закрепления https не принимаем


def test_retry_backoff_then_success():
    calls, sleeps = [], []
    def handler(req):
        calls.append(1)
        return httpx.Response(503) if len(calls) < 3 else httpx.Response(200, json={"ok": 1})
    tr = Transport(_cfg(), client=httpx.Client(transport=httpx.MockTransport(handler), base_url="http://x"),
                   sleep=sleeps.append, rng=lambda: 1.0)
    assert tr.request("GET", "/a").json() == {"ok": 1}
    assert sleeps == [1.0, 2.0]                     # экспонента: 1, 2


def test_retry_network_error_and_give_up():
    def handler(req):
        raise httpx.ConnectError("down")
    sleeps = []
    tr = Transport(_cfg(), client=httpx.Client(transport=httpx.MockTransport(handler), base_url="http://x"), sleep=sleeps.append, rng=lambda: 1.0)
    with pytest.raises(ProtocolError) as e:
        tr.request("GET", "/a")
    assert e.value.code == "server_error" and sleeps == [1.0, 2.0, 4.0, 8.0]


def test_no_retry_on_permanent_error_and_429_long_retry_after():
    calls = []
    def handler(req):
        calls.append(1)
        if req.url.path == "/p":
            return httpx.Response(422, json={"error": "norm_too_large", "message": "m"})
        return httpx.Response(429, headers={"Retry-After": "80000"}, json={"error": "rate_limited"})
    tr = Transport(_cfg(), client=httpx.Client(transport=httpx.MockTransport(handler), base_url="http://x"), sleep=lambda s: None)
    with pytest.raises(ProtocolError) as e:
        tr.request("POST", "/p")
    assert e.value.code == "norm_too_large" and len(calls) == 1
    with pytest.raises(ProtocolError) as e:
        tr.request("POST", "/q")
    assert e.value.code == "rate_limited" and len(calls) == 2


def test_429_short_retry_after_is_honored():
    seq = [httpx.Response(429, headers={"Retry-After": "7"}, json={"error": "rate_limited"}), httpx.Response(200, json={})]
    sleeps = []
    tr = Transport(_cfg(), client=httpx.Client(transport=httpx.MockTransport(lambda r: seq.pop(0)), base_url="http://x"),
                   sleep=sleeps.append, rng=lambda: 0.0)
    tr.request("GET", "/")
    assert sleeps == [7.0]


# --- закрепление TLS ---
def _selfsigned(tmp_path):
    from sim.tls import make_selfsigned
    return make_selfsigned(tmp_path)


def test_tls_spki_pinning(tmp_path):
    spec, d, store, _ = make_server(tmp_path)
    cp, kp, pin = _selfsigned(tmp_path)
    s = socket.socket(); s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]; s.close()
    server = uvicorn.Server(uvicorn.Config(create_app(d), host="127.0.0.1", port=port, ssl_certfile=str(cp), ssl_keyfile=str(kp), log_level="error"))
    th = threading.Thread(target=server.run, daemon=True)
    th.start()
    for _ in range(100):
        if server.started:
            break
        time.sleep(0.05)
    try:
        good = ServerCfg(url=f"https://127.0.0.1:{port}", tls_ca_file=str(cp), tls_spki_sha256=pin, retry_attempts=1)
        tr = Transport(good)
        assert tr.request("GET", "/v1/health").json()["latest_version"] == 1
        # тело обновления уходит по закреплённому соединению
        r = upload_update(tr, *(lambda p: (p.envelope, p.payload))(make_update(spec, Identity.generate(), 1, 1.0, 1)))
        assert r.status == "accepted"
        tr.close()
        bad = ServerCfg(url=f"https://127.0.0.1:{port}", tls_ca_file=str(cp), tls_spki_sha256="00" * 32, retry_attempts=3)
        sleeps = []
        tr2 = Transport(bad, sleep=sleeps.append)
        with pytest.raises(ProtocolError) as e:
            tr2.request("GET", "/v1/health")
        assert e.value.code == "bad_signature" and "закреплённый" in e.value.message and not sleeps   # без повторов
        # сертификат не из доверенных: проверка цепочки тоже работает
        nocA = ServerCfg(url=f"https://127.0.0.1:{port}", tls_spki_sha256=pin, retry_attempts=1)
        with pytest.raises(ProtocolError):
            Transport(nocA).request("GET", "/v1/health")
    finally:
        server.should_exit = True
        th.join(timeout=5)


# --- загрузка модели ---
def _client_setup(tmp_path, **srv_kw):
    spec, d, store, tc = make_server(tmp_path)
    cfg = ClientConfig(home=tmp_path / "home")
    consent.record(cfg.home, True)
    cfg.server = _cfg(signing_public_key=public_b64(store.signing_key()))
    cfg.training.backend = "stub"
    cfg.training.features_dir = str(tmp_path / "feats")
    cfg.schedule.min_examples = 2
    cfg.schedule.steps = 10
    (tmp_path / "feats").mkdir()
    for i in range(5):
        np.save(tmp_path / "feats" / f"{i}.npy", np.zeros((3, 4), np.float16))
    tr = Transport(cfg.server, client=tc)
    return spec, d, store, tc, cfg, tr


def test_downloader_installs_verifies_and_keeps_previous(tmp_path):
    spec, d, store, tc, cfg, tr = _client_setup(tmp_path)
    ms = ModelSync(cfg, spec, tr)
    r = ms.sync()
    assert r.changed and r.version == 1 and not ms.sync().changed
    for i in range(3):
        tc.post("/v1/updates", files={"manifest": ("m", (p := make_update(spec, Identity.generate(), 1, 1.0, i)).envelope), "payload": ("p", p.payload)})
    run_round(store, load_server_config(d))
    r = ms.sync()
    assert r.changed and r.version == 2
    assert ms.store.rollback_local() == 1 and ms.store.current() == 1


def test_downloader_rejects_wrong_key_and_downgrade_and_corruption(tmp_path):
    spec, d, store, tc, cfg, tr = _client_setup(tmp_path)
    ms = ModelSync(cfg, spec, tr)
    ms.sync()
    wrong = replace(cfg.server, signing_public_key=public_b64(__import__("cryptography.hazmat.primitives.asymmetric.ed25519", fromlist=["x"]).Ed25519PrivateKey.generate()))
    cfg2 = ClientConfig(home=tmp_path / "home2"); cfg2.server = wrong
    with pytest.raises(ProtocolError) as e:
        ModelSync(cfg2, spec, tr).sync()
    assert e.value.code == "bad_signature"
    # установленная версия выше предложенной: отвергаем (подмена старым ответом)
    ms.store.activate(5)
    with pytest.raises(ProtocolError) as e:
        ms.sync()
    assert "ниже установленной" in e.value.message
    # повреждённый файл: sha256 не сходится
    cfg3 = ClientConfig(home=tmp_path / "home3"); cfg3.server = cfg.server
    real_request = tr.request
    def corrupt(method, path, **kw):
        resp = real_request(method, path, **kw)
        if path.endswith("/adapter"):
            return httpx.Response(200, content=resp.content[:-1] + b"\x01")
        return resp
    tr.request = corrupt
    with pytest.raises(ProtocolError) as e:
        ModelSync(cfg3, spec, tr).sync()
    assert e.value.code == "bad_payload"
    assert ModelSync(cfg3, spec, tr).store.current() is None


def test_downloader_local_validator_can_reject(tmp_path):
    spec, d, store, tc, cfg, tr = _client_setup(tmp_path)
    ms = ModelSync(cfg, spec, tr)
    r = ms.sync(validator=lambda p: False)
    assert not r.changed and "локальную проверку" in r.skipped_reason and ms.store.current() is None
    assert 1 in ms.store.rejected()


# --- полный цикл клиента ---
def _fc(tmp_path, tc, cfg, tr, snap=Snapshot(True, False, 3600)):
    probe = type("P", (), {"snapshot": lambda self: snap})()
    return FederatedClient(cfg, spec=tiny_spec(), trainer=StubTrainer(), probe=probe, transport=tr, clock=lambda: 1_000_000.0, log=lambda s: None)


def test_full_cycle_uploads_once_and_logs_manifest(tmp_path):
    spec, d, store, tc, cfg, tr = _client_setup(tmp_path)
    fc = _fc(tmp_path, tc, cfg, tr)
    r = fc.run_cycle()
    assert r.status == "uploaded", r
    with store.db() as db:
        row = db.execute("SELECT * FROM updates").fetchone()
        assert row["client_id"] == fc.identity.client_id and row["num_examples"] == 5 and row["base_version"] == 1
    log = [json.loads(l) for l in cfg.upload_log.read_text().splitlines()]
    assert set(log[0]["manifest"]) == {"schema_version", "client_id", "public_key", "base_version", "spec_id", "spec_hash",
                                        "num_examples", "payload_sha256", "payload_bytes", "payload_dtype"}
    # повторно в том же раунде не участвуем
    fc2 = _fc(tmp_path, tc, cfg, tr)
    fc2.state.update(last_run_ts=0)
    assert fc2.run_cycle().status == "nothing_new"


def test_cycle_skipped_when_unplugged_or_busy(tmp_path):
    spec, d, store, tc, cfg, tr = _client_setup(tmp_path)
    assert _fc(tmp_path, tc, cfg, tr, Snapshot(False, False, 3600)).run_cycle().status == "skipped"
    assert _fc(tmp_path, tc, cfg, tr, Snapshot(True, False, 5)).run_cycle().status == "skipped"
    with store.db() as db:
        assert db.execute("SELECT COUNT(*) FROM updates").fetchone()[0] == 0


def test_cycle_not_enough_data_and_too_little_training(tmp_path):
    spec, d, store, tc, cfg, tr = _client_setup(tmp_path)
    cfg.schedule.min_examples = 100
    assert _fc(tmp_path, tc, cfg, tr).run_cycle().status == "not_enough_data"
    cfg.schedule.min_examples = 2
    snaps = iter([Snapshot(True, False, 3600)] + [Snapshot(True, False, 1)] * 50)   # пользователь вернулся
    probe = type("P", (), {"snapshot": lambda self: next(snaps)})()
    fc = FederatedClient(cfg, spec=spec, trainer=StubTrainer(), probe=probe, transport=tr, clock=lambda: 1e6, log=lambda s: None)
    cfg.schedule.monitor_seconds = 0
    r = fc.run_cycle()
    assert r.status == "too_little_training"


def test_outbox_retry_after_network_failure(tmp_path):
    spec, d, store, tc, cfg, tr = _client_setup(tmp_path)
    cfg.server.retry_attempts = 1
    real = tr.http
    fail = {"on": True}
    class Flaky(httpx.Client):
        pass
    orig_request = real.request
    def flaky(method, url, **kw):
        if fail["on"] and method == "POST":
            raise httpx.ConnectError("down")
        return orig_request(method, url, **kw)
    real.request = flaky
    tr.cfg = cfg.server
    fc = _fc(tmp_path, tc, cfg, tr)
    r = fc.run_cycle()
    assert r.status == "error" and "outbox" in r.detail
    assert list(cfg.outbox_dir.glob("*.envelope.json"))
    fail["on"] = False
    fc2 = _fc(tmp_path, tc, cfg, tr)
    assert fc2.run_cycle().status == "uploaded"            # отправлено то же упакованное обновление
    assert not list(cfg.outbox_dir.glob("*"))


def test_train_lora_functional_interface(tmp_path):
    spec = tiny_spec()
    from protocol.spec import init_adapter
    base = tmp_path / "b.safetensors"
    save_adapter(init_adapter(spec, 0), base)
    (tmp_path / "f").mkdir()
    out = tmp_path / "o.safetensors"
    res = train_lora(tmp_path / "f", base, 5, out)
    assert res.steps_done == 5 and out.exists() and res.stopped_reason is None
    res = train_lora(tmp_path / "f", base, 50, out, should_stop=lambda: True)
    assert res.steps_done == 1 and res.stopped_reason == "stopped"


def test_config_toml(tmp_path):
    (tmp_path / "config.toml").write_text('[server]\nurl = "https://x"\n[schedule]\nidle_minutes = 3\n[guard]\nreserve_gb = 8\n')
    c = load_config(tmp_path)
    assert c.server.url == "https://x" and c.schedule.idle_minutes == 3.0 and c.guard.reserve_gb == 8.0 and c.guard.enabled
    (tmp_path / "config.toml").write_text("[schedule]\nbogus = 1\n")
    with pytest.raises(ValueError):
        load_config(tmp_path)


def test_daemon_exits_with_parent_and_backs_off(tmp_path):
    from client.runner import daemon, parent_alive
    spec, d, store, tc, cfg, tr = _client_setup(tmp_path)
    cfg.schedule.poll_seconds = 10
    fc = _fc(tmp_path, tc, cfg, tr, Snapshot(True, False, 5))        # всегда «skipped»
    alive = iter([True, True, False] + [False] * 50)
    import client.runner as R
    orig = R.parent_alive
    R.parent_alive = lambda pid: next(alive)
    try:
        sleeps = []
        assert daemon(fc, 1234, sleep=sleeps.append) == 0
    finally:
        R.parent_alive = orig
    assert parent_alive(os.getpid()) and not parent_alive(2**22 + 12345)


# --- согласие на участие ---
def test_no_consent_means_no_sync_training_or_upload(tmp_path):
    spec, d, store, tc, cfg, tr = _client_setup(tmp_path)
    consent.record(cfg.home, False)
    calls = []
    tr.request = lambda *a, **kw: calls.append(a) or (_ for _ in ()).throw(AssertionError("network without consent"))
    fc = _fc(tmp_path, tc, cfg, tr)
    for kw in ({}, {"force": True}, {"force": True, "dry_run": True}):
        assert fc.run_cycle(**kw).status == "no_consent"
    assert calls == [] and not (cfg.work_dir / "trained.safetensors").exists()


def test_consent_is_off_by_default_and_revocable(tmp_path):
    home = tmp_path / "fresh"
    assert not consent.granted(home)
    (home).mkdir()
    (home / consent.FILE_NAME).write_text("not json")
    assert not consent.granted(home)
    data = consent.record(home, True, now=0)
    assert consent.granted(home) and data["changed_at"] == "1970-01-01T00:00:00Z" and data["agreement"]
    assert oct((home / consent.FILE_NAME).stat().st_mode & 0o777) == "0o600"
    consent.record(home, False)
    assert not consent.granted(home)


def test_consent_to_another_edition_is_not_consent(tmp_path):
    data = consent.record(tmp_path, True)
    assert consent.granted(tmp_path)
    for edition in ("2000-01-01", None):
        if edition is None:
            data.pop("agreement")
        else:
            data["agreement"] = edition
        (tmp_path / consent.FILE_NAME).write_text(json.dumps(data))
        assert not consent.granted(tmp_path)
    consent.record(tmp_path, True)
    assert consent.granted(tmp_path)


def test_consent_cli(tmp_path, capsys):
    from client.runner import main
    assert main(["consent", "--home", str(tmp_path)]) == 0
    assert "выключено" in capsys.readouterr().out
    assert main(["consent", "on", "--home", str(tmp_path)]) == 0
    assert consent.granted(tmp_path)
    assert main(["consent", "off", "--home", str(tmp_path)]) == 0
    assert not consent.granted(tmp_path)

