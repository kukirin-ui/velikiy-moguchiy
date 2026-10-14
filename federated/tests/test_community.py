import hashlib
import importlib.util
import io
import json
import pickle
import re
from pathlib import Path

import httpx
import numpy as np
import pytest

from aggregator.credits import Credit, merge_credits, update_file
from aggregator.run import run_round
from client import consent
from client.community import Controls, status_report
from client.github_login import DeviceCode, LoginError, load_token, poll, start
from client.privacy import PrivacyError, check_outgoing, ensure_inside, ensure_work_dir, personal_roots
from hub.github_auth import GithubVerifier, bearer_token
from hub.inbox import Inbox
from hub.registry import Registry, RegistryError
from hub.storage import LocalBlobStore
from hub.tasks import Exclusions, TaskIssuer, parse_exclusions, parse_pool, sign_claims, TaskClaims, verify_token
from protocol.adapter_io import dumps_adapter, load_adapter, loads_adapter
from protocol.contribution import Contribution, sign_contribution, verify_contribution
from protocol.errors import ProtocolError
from protocol.identity import Identity
from protocol.modelsig import verify_model_info
from protocol.modelsig import public_b64
from protocol.package import pack_update, verify_update
from space.settings import Settings, SettingsError
from tests.helpers import delta_with_norm, tiny_spec
from tests.hubkit import (MARKER, NOW, SECRET, FakePipeline, Hub, client_job, exam_fn, github_http, pool, read_preview,
                          user)

ROOT = Path(__file__).resolve().parents[2]


def auth(tok):
    return {"Authorization": f"Bearer {tok}"}


def signed_parts(spec, ident, base, *, norm=1.0, seed=0, token="x", seconds=60.0, steps=50):
    p = pack_update(delta_with_norm(spec, norm, seed), spec=spec, base_version=base, num_examples=30, identity=ident)
    c = Contribution(client_id=ident.client_id, payload_sha256=p.manifest.payload_sha256, base_version=base,
                     task_token=token, data_seconds=seconds, training_steps=steps, num_clips=30)
    return {"manifest": p.envelope, "payload": p.payload, "contribution": sign_contribution(c, ident)}


def post(hub, tok, parts):
    return hub.http.post("/v1/updates", headers=auth(tok), files={
        "manifest": ("m.json", parts["manifest"], "application/json"),
        "payload": ("p.safetensors", parts["payload"], "application/octet-stream"),
        "contribution": ("c.json", parts["contribution"], "application/json")})


def task_for(hub, tok):
    r = hub.http.get("/v1/task", headers=auth(tok))
    assert r.status_code == 200, r.text
    return r.json()


# --- формат: только safetensors ---
def test_only_safetensors_accepted():
    spec = tiny_spec()
    ident = Identity.generate()
    good = pack_update(delta_with_norm(spec, 1.0, 0), spec=spec, base_version=1, num_examples=5, identity=ident)
    verify_update(good.envelope, good.payload, spec)
    arrays = {k: v.astype(np.float16) for k, v in delta_with_norm(spec, 1.0, 0).items()}
    for blob, what in ((pickle.dumps(arrays, protocol=4), "pickle"), (b"PK\x03\x04" + bytes(100), "zip"),
                       (b"\x93NUMPY" + bytes(100), "numpy"), (b"\x80\x02}q\x00." + bytes(64), "pickle"),
                       (good.payload[:8] + b"[" + good.payload[9:], "JSON")):
        with pytest.raises(ProtocolError) as e:
            loads_adapter(blob)
        assert e.value.code == "bad_payload" and what in e.value.message
    # a pickled payload with a correctly signed manifest is still refused
    payload = pickle.dumps(arrays, protocol=4)
    m = good.manifest.model_copy(update={"payload_sha256": hashlib.sha256(payload).hexdigest(), "payload_bytes": len(payload)})
    from protocol.package import _signing_bytes
    from protocol.schema import SignedManifest
    from protocol.identity import b64e
    env = SignedManifest(manifest=m, signature=b64e(ident.sign(_signing_bytes(m)))).model_dump_json().encode()
    with pytest.raises(ProtocolError) as e:
        verify_update(env, payload, spec)
    assert e.value.code == "bad_payload"


def test_safetensors_header_starting_with_0x80_is_not_mistaken_for_pickle():
    spec = tiny_spec()
    tensors = {t.name: np.zeros(t.shape, np.float32) for t in spec.tensors}
    data = next(d for d in (dumps_adapter(tensors, metadata={"pad": "x" * n}) for n in range(1, 600)) if d[0] == 0x80)
    assert set(loads_adapter(data)) == set(tensors)


# --- подпись сведений о вкладе ---
def test_contribution_signature():
    spec = tiny_spec()
    ident, other = Identity.generate(), Identity.generate()
    parts = signed_parts(spec, ident, 3)
    from protocol.package import parse_envelope
    m = parse_envelope(parts["manifest"]).manifest
    c = verify_contribution(parts["contribution"], m)
    assert c.training_steps == 50 and c.credit_public
    tampered = json.loads(parts["contribution"])
    tampered["contribution"]["data_seconds"] = 86000.0
    with pytest.raises(ProtocolError) as e:
        verify_contribution(json.dumps(tampered).encode(), m)
    assert e.value.code == "bad_signature"
    foreign = signed_parts(spec, other, 3)
    with pytest.raises(ProtocolError) as e:
        verify_contribution(foreign["contribution"], m)
    assert e.value.code == "bad_payload"
    with pytest.raises(ValueError):
        sign_contribution(Contribution(client_id=ident.client_id, payload_sha256="0" * 64, base_version=1, task_token="t",
                                       data_seconds=1, training_steps=1, num_clips=1), other)
    extra = json.loads(parts["contribution"])
    extra["contribution"]["video_ids"] = ["abc"]
    with pytest.raises(ProtocolError) as e:
        verify_contribution(json.dumps(extra).encode(), m)
    assert e.value.code == "bad_schema"


# --- вход через GitHub ---
def test_github_verifier_and_account_age():
    clock = [NOW]
    v = GithubVerifier(github_http({"ok": user("alice", 1), "new": user("fresh", 2, "2027-01-20T00:00:00Z")}),
                       clock=lambda: clock[0])
    assert v.verify("Bearer ok").login == "alice"
    for hdr in (None, "", "Basic abc", "Bearer "):
        with pytest.raises(ProtocolError) as e:
            v.verify(hdr)
        assert e.value.code == "unauthorized"
    with pytest.raises(ProtocolError) as e:
        v.verify("Bearer nope")
    assert e.value.code == "unauthorized"
    with pytest.raises(ProtocolError) as e:
        v.verify("Bearer new")
    assert e.value.code == "forbidden"
    assert bearer_token("token abc") == "abc"


def test_device_flow():
    calls = []

    def handler(req):
        body = dict(x.split("=") for x in req.content.decode().split("&"))
        calls.append(req.url.path)
        if req.url.path == "/login/device/code":
            assert body["client_id"] == "cid"
            return httpx.Response(200, json={"device_code": "dc", "user_code": "ABCD-1234",
                                             "verification_uri": "https://github.com/login/device", "interval": 1})
        if len(calls) < 4:
            return httpx.Response(200, json={"error": "authorization_pending"})
        return httpx.Response(200, json={"access_token": "gho_x", "token_type": "bearer"})
    http = httpx.Client(transport=httpx.MockTransport(handler))
    code = start("cid", http)
    assert code.user_code == "ABCD-1234"
    assert poll("cid", code, http, sleep=lambda s: None) == "gho_x"
    from client.github_login import fetch_login
    me = httpx.Client(transport=httpx.MockTransport(lambda r: httpx.Response(200, json={"login": "alice"})))
    assert fetch_login("gho_x", me) == "alice"
    deny = httpx.Client(transport=httpx.MockTransport(lambda r: httpx.Response(200, json={"error": "access_denied"})))
    with pytest.raises(LoginError):
        poll("cid", DeviceCode("d", "u", "v", 0, 100), deny, sleep=lambda s: None)
    with pytest.raises(LoginError):
        start("", http)


# --- задания, исключения ---
def test_pool_and_exclusions_parsing():
    lines = [json.dumps({"video_id": "abcdefghijk", "channel_id": "UC1", "segments": [
        {"start": 1, "end": 4, "text": "привет"}, {"start": 5, "end": 40, "text": "длинный"}, {"start": 6, "end": 7, "text": ""}]}),
        json.dumps({"video_id": "bad", "segments": [{"start": 1, "end": 2, "text": "x"}]}), "not json", ""]
    p = parse_pool(lines)
    assert len(p) == 1 and len(p[0].segments) == 1 and p[0].seconds == 3
    e = parse_exclusions('[{"channel_id": "UC1", "reason": "просьба автора"}, {"video_id": "zzzzzzzzzzz"}]')
    assert e.channels == {"UC1"} and e.videos == {"zzzzzzzzzzz"} and e.excludes(p[0])
    e2 = parse_exclusions('{"channel_id": "UC2"}\n{"video": "v1"}\n')
    assert e2.channels == {"UC2"} and e2.videos == {"v1"}
    e3 = parse_exclusions("# список\nchannel: UC3\nvideo:v2\n")
    assert e3.channels == {"UC3"} and e3.videos == {"v2"}
    assert parse_exclusions('{"exclusions": [{"channel": "UC4"}]}').channels == {"UC4"}
    assert parse_exclusions("") == Exclusions()
    journal = "# канал\tдата\nUCabcdefghijklmnopqrstuv\t2026-10-14\n\n"
    assert parse_exclusions(journal).channels == {"UCabcdefghijklmnopqrstuv"}
    real = ROOT / "data-governance" / "exclusions" / "channels.tsv"
    parse_exclusions(real.read_text(encoding="utf8"))


def test_task_issuer_spreads_videos_and_honours_exclusions():
    pl = pool(n=10)
    excl = Exclusions(channels=frozenset({"UCchan0"}))
    iss = TaskIssuer(pool=pl, secret=SECRET, videos_per_task=3, segments_per_video=5, exclusions=lambda: excl,
                     clock=lambda: NOW)
    seen = []
    for login in ("a", "b"):
        t = iss.issue(login, 7)
        assert len(t["videos"]) == 3 and all(len(v["segments"]) == 5 for v in t["videos"])
        for v in t["videos"]:
            src = next(p for p in pl if p.video_id == v["video_id"])
            assert src.channel_id == "UCchan1"
        seen += [v["video_id"] for v in t["videos"]]
        c = verify_token(t["token"], SECRET, login=login, base_version=7, now=NOW)
        assert c.seconds_max == t["seconds_max"] and c.steps_max == t["training"]["steps"]
    assert len(set(seen)) == 5   # 5 eligible videos: the second task gets the two never given plus one repeat
    with pytest.raises(ProtocolError):
        iss.issue("a", 7) and iss.issue("a", 7)


def test_task_token_checks():
    c = TaskClaims("t1", "Alice", 3, 120.0, 50, int(NOW) + 100)
    tok = sign_claims(c, SECRET)
    assert verify_token(tok, SECRET, login="alice", base_version=3, now=NOW).task_id == "t1"
    for kw, msg in ((dict(login="bob", base_version=3, now=NOW), "другому"),
                    (dict(login="alice", base_version=4, now=NOW), "версию"),
                    (dict(login="alice", base_version=3, now=NOW + 200), "истёк")):
        with pytest.raises(ProtocolError) as e:
            verify_token(tok, SECRET, **kw)
        assert e.value.code == "bad_task" and msg in e.value.message
    with pytest.raises(ProtocolError):
        verify_token(tok, b"x" * 32, login="alice", base_version=3, now=NOW)
    with pytest.raises(ProtocolError):
        verify_token("garbage", SECRET, login="alice", base_version=3, now=NOW)


# --- сервер Space ---
def test_space_requires_published_model_and_login(tmp_path):
    hub = Hub(tmp_path)
    assert hub.http.get("/v1/health").json()["latest_version"] is None
    assert hub.http.get("/v1/task", headers=auth("tok-alice")).status_code == 503
    hub.bootstrap()
    hub.refresh()
    assert hub.http.get("/v1/task").status_code == 401
    assert hub.http.get("/v1/task", headers=auth("wrong")).status_code == 401
    info = hub.http.get("/v1/model/latest").json()
    from protocol.schema import ModelInfo
    verify_model_info(ModelInfo.model_validate(info), public_b64(hub.key))
    assert hub.http.get(info["download_path"]).content == hub.registry.adapter_bytes(1)
    assert hub.http.get("/v1/config").json()["spec_hash"] == hub.spec.hash


def test_space_accepts_valid_update_and_enforces_limits(tmp_path):
    hub = Hub(tmp_path, banned=frozenset({"eve"}))
    hub.bootstrap()
    hub.refresh()
    ident = Identity.generate()
    t = task_for(hub, "tok-alice")
    parts = signed_parts(hub.spec, ident, 1, token=t["token"])
    r = post(hub, "tok-alice", parts)
    assert r.status_code == 200 and r.json()["status"] == "accepted"
    (e,) = hub.inbox.entries()
    meta = json.loads(hub.inbox.read(e, "meta.json"))
    assert meta["login"] == "alice" and meta["task"]["seconds_max"] == t["seconds_max"]
    assert post(hub, "tok-alice", parts).json()["status"] == "duplicate"
    other = signed_parts(hub.spec, ident, 1, seed=5, token=t["token"])
    assert post(hub, "tok-alice", other).json()["error"] == "conflict"
    # someone else's task token
    tb = task_for(hub, "tok-bob")
    r = post(hub, "tok-carol", signed_parts(hub.spec, Identity.generate(), 1, token=tb["token"]))
    assert r.status_code == 422 and r.json()["error"] == "bad_task"
    # norm bound
    tc = task_for(hub, "tok-carol")
    r = post(hub, "tok-carol", signed_parts(hub.spec, Identity.generate(), 1, norm=500.0, token=tc["token"]))
    assert r.json()["error"] == "norm_too_large"
    # stale base after a new version
    hub.registry.publish(hub.registry.adapter_bytes(1), hub.key)
    hub.refresh()
    r = post(hub, "tok-bob", signed_parts(hub.spec, Identity.generate(), 1, token=tb["token"]))
    assert r.status_code == 409 and r.json()["latest_version"] == 2
    assert hub.http.get("/v1/task", headers=auth("tok-eve")).json()["error"] == "banned"


def test_space_rate_limits_per_login(tmp_path):
    hub = Hub(tmp_path, max_tasks_per_day=2, max_updates_per_day=1)
    hub.bootstrap()
    hub.refresh()
    task_for(hub, "tok-alice")
    task_for(hub, "tok-alice")
    r = hub.http.get("/v1/task", headers=auth("tok-alice"))
    assert r.status_code == 429 and int(r.headers["Retry-After"]) > 0
    hub.clock[0] += 86401
    t = task_for(hub, "tok-alice")
    assert post(hub, "tok-alice", signed_parts(hub.spec, Identity.generate(), 1, token=t["token"])).status_code == 200
    # the per-day count also comes from the stored updates, so a restart does not reset it
    hub.registry.publish(hub.registry.adapter_bytes(1), hub.key)
    fresh = Hub(tmp_path, max_updates_per_day=1)
    fresh.key = hub.key
    fresh.clock[0] = hub.clock[0]
    t2 = task_for(fresh, "tok-alice")
    r = post(fresh, "tok-alice", signed_parts(hub.spec, Identity.generate(), 2, token=t2["token"]))
    assert r.status_code == 429


def test_space_rejects_pickle_and_extra_parts(tmp_path):
    hub = Hub(tmp_path)
    hub.bootstrap()
    hub.refresh()
    t = task_for(hub, "tok-alice")
    parts = signed_parts(hub.spec, Identity.generate(), 1, token=t["token"])
    parts["payload"] = pickle.dumps({"x": 1})
    assert post(hub, "tok-alice", parts).json()["error"] in ("bad_payload", "bad_signature")
    good = signed_parts(hub.spec, Identity.generate(), 1, token=t["token"])
    r = hub.http.post("/v1/updates", headers=auth("tok-alice"), files={
        "manifest": ("m", good["manifest"]), "payload": ("p", good["payload"]), "contribution": ("c", good["contribution"]),
        "video": ("v.mp4", b"x")})
    assert r.status_code in (400, 422) and hub.inbox.entries() == []   # starlette refuses a 4th file with 400


def test_space_fails_closed_without_exclusions(tmp_path):
    def broken():
        raise httpx.ConnectError("offline")
    hub = Hub(tmp_path, exclusions_loader=broken)
    hub.bootstrap()
    hub.refresh()
    r = hub.http.get("/v1/task", headers=auth("tok-alice"))
    assert r.status_code == 503


def test_space_settings_from_env():
    with pytest.raises(SettingsError):
        Settings.from_env({})
    s = Settings.from_env({"HF_TOKEN": "h", "FL_INBOX": "hf:o/i", "FL_MODELS": "hf:o/m", "FL_TASK_SECRET": "s" * 40,
                           "FL_BANNED_LOGINS": "Eve, mallory", "FL_TRAINING_JSON": '{"steps": 300}'})
    assert s.banned == {"eve", "mallory"} and s.training["steps"] == 300 and s.assets["venc"]["sha256"]


# --- реестр и откат ---
def test_registry_keeps_versions_and_rolls_back(tmp_path):
    hub = Hub(tmp_path)
    v1 = hub.bootstrap()
    t2 = {k: v + 1 for k, v in load_adapter_bytes(hub.registry.adapter_bytes(v1)).items()}
    v2 = hub.registry.publish(dumps_adapter(t2), hub.key, exam_wer=0.5)
    v3 = hub.registry.rollback(v1, hub.key, "хуже")
    idx = hub.registry.index()
    assert (v1, v2, v3) == (1, 2, 3) and idx.current == 3
    assert idx.record(2).status == "revoked" and idx.record(3).info.rollback_of == 1
    assert hub.registry.adapter_bytes(3) == hub.registry.adapter_bytes(1)
    with pytest.raises(RegistryError):
        hub.registry.rollback(2, hub.key)
    (tmp_path / "models" / "versions" / "v000001.safetensors").write_bytes(b"tampered")
    with pytest.raises(RegistryError):
        hub.registry.adapter_bytes(1)
    hub.refresh()
    assert hub.http.get("/v1/model/2/adapter").status_code == 404


def load_adapter_bytes(b):
    return loads_adapter(b)


# --- агрегатор ---
def submit(hub, tok, ident, *, toward=None, poison=None, seed=0):
    t = task_for(hub, tok)
    base = loads_adapter(hub.registry.adapter_bytes(t["base_version"]))
    from tests.hubkit import target_adapter
    tgt = target_adapter(hub.spec)
    rng = np.random.default_rng(seed)
    if poison is not None:
        delta = {k: (poison * rng.standard_normal(v.shape)).astype(np.float32) for k, v in base.items()}
    else:
        delta = {k: (toward * (tgt[k] - v) + 0.01 * rng.standard_normal(v.shape)).astype(np.float32) for k, v in base.items()}
    p = pack_update(delta, spec=hub.spec, base_version=t["base_version"], num_examples=40, identity=ident)
    c = Contribution(client_id=ident.client_id, payload_sha256=p.manifest.payload_sha256, base_version=t["base_version"],
                     task_token=t["token"], data_seconds=10 ** 5 // 2, training_steps=10 ** 4, num_clips=40)
    r = post(hub, tok, {"manifest": p.envelope, "payload": p.payload, "contribution": sign_contribution(c, ident)})
    assert r.status_code == 200, r.text
    return t


def test_round_rejects_worse_update_merges_rest_and_credits(tmp_path):
    hub = Hub(tmp_path)
    hub.bootstrap()
    hub.refresh()
    tasks = {}
    for i, tok in enumerate(("tok-alice", "tok-bob", "tok-carol")):
        tasks[tok] = submit(hub, tok, Identity.generate(), toward=0.3, seed=i)
    submit(hub, "tok-dave", Identity.generate(), poison=1.5, seed=9)
    base_wer = exam_fn(hub.spec)(loads_adapter(hub.registry.adapter_bytes(1)))
    out = run_round(hub.context())
    assert out.status == "published" and out.version == 2
    st = {d.login: d for d in out.decisions}
    assert st["dave"].status == "rejected" and st["dave"].reason.startswith("экзамен")
    assert all(st[x].status == "accepted" for x in ("alice", "bob", "carol"))
    assert out.new_wer < base_wer and hub.registry.index().record(2).exam_wer == pytest.approx(out.new_wer)
    assert hub.inbox.entries() == []
    reports = LocalBlobStore(tmp_path / "inbox").list("rounds/")
    assert len(reports) == 1
    # credits are capped by what the task held
    by = {c.login: c for c in out.credits}
    assert set(by) == {"alice", "bob", "carol"}
    assert by["alice"].data_seconds == pytest.approx(tasks["tok-alice"]["seconds_max"])
    assert by["alice"].training_steps == tasks["tok-alice"]["training"]["steps"]


def test_round_trimmed_mean_limits_one_participant(tmp_path):
    """Обновление в пределах нормы и не хуже на экзамене всё равно не двигает модель сильнее остальных."""
    hub = Hub(tmp_path)
    hub.bootstrap()
    hub.refresh()
    for i, tok in enumerate(("tok-alice", "tok-bob", "tok-carol", "tok-dave")):
        submit(hub, tok, Identity.generate(), toward=0.2, seed=i)
    submit(hub, "tok-eve", Identity.generate(), toward=0.9, seed=7)
    out = run_round(hub.context(trim_ratio=0.2))
    assert out.status == "published"
    base = loads_adapter(hub.registry.adapter_bytes(1))
    new = loads_adapter(hub.registry.adapter_bytes(2))
    from tests.hubkit import target_adapter
    tgt = target_adapter(hub.spec)
    moved = np.mean([np.abs(new[k] - base[k]).sum() / np.abs(tgt[k] - base[k]).sum() for k in base])
    # a plain mean of four 0.2 steps and one 0.9 step moves 0.34; clipping and trimming keep it near the honest 0.2
    assert 0.18 < moved < 0.23


def test_round_waits_for_enough_clients_and_drops_stale(tmp_path):
    hub = Hub(tmp_path)
    hub.bootstrap()
    hub.refresh()
    submit(hub, "tok-alice", Identity.generate(), toward=0.3)
    out = run_round(hub.context(min_clients=3))
    assert out.status == "waiting" and len(hub.inbox.entries()) == 1
    hub.registry.publish(hub.registry.adapter_bytes(1), hub.key)
    out = run_round(hub.context(min_clients=3))
    assert [d.status for d in out.decisions] == ["stale"] and hub.inbox.entries() == []
    hub.refresh()
    submit(hub, "tok-bob", Identity.generate(), toward=0.3)
    hub.clock[0] += 8 * 86400
    out = run_round(hub.context(min_clients=3))
    assert out.status == "waiting" and hub.registry.index().current == 2   # no forced round after a wait
    hub.clock[0] += 30 * 86400
    out = run_round(hub.context(min_clients=3))
    assert [d.status for d in out.decisions] == ["expired"] and hub.inbox.entries() == []
    assert hub.registry.index().current == 2


def test_round_needs_five_accepted_updates_by_default(tmp_path):
    names = ["alice", "bob", "carol", "dave", "eve", "frank"]
    hub = Hub(tmp_path, users={f"tok-{n}": user(n, i + 1) for i, n in enumerate(names)}, max_tasks_per_day=5)
    hub.bootstrap()
    hub.refresh()
    for i, n in enumerate(names[:4]):
        submit(hub, f"tok-{n}", Identity.generate(), toward=0.3, seed=i)
    submit(hub, "tok-frank", Identity.generate(), poison=1.5, seed=9)
    ctx = hub.context(min_clients=5, min_accepted=5)
    out = run_round(ctx)
    st = {d.login: d.status for d in out.decisions}
    assert out.status == "waiting" and hub.registry.index().current == 1
    assert st == {"alice": "waiting", "bob": "waiting", "carol": "waiting", "dave": "waiting", "frank": "rejected"}
    assert sorted(e.login for e in hub.inbox.entries()) == ["alice", "bob", "carol", "dave"]
    submit(hub, "tok-eve", Identity.generate(), toward=0.3, seed=5)
    out = run_round(ctx)
    assert out.status == "published" and out.version == 2 and len(out.credits) == 5
    assert hub.inbox.entries() == []


def test_single_update_is_never_published(tmp_path):
    hub = Hub(tmp_path)
    hub.bootstrap()
    hub.refresh()
    submit(hub, "tok-alice", Identity.generate(), toward=0.3)
    hub.clock[0] += 29 * 86400
    out = run_round(hub.context(min_clients=5, min_accepted=5))
    assert out.status == "waiting" and hub.registry.index().current == 1


def test_publish_rebuilds_the_merge_and_refuses_a_forged_plan(tmp_path):
    from aggregator.run import PlanMismatch, publish_plan, score_round
    hub = Hub(tmp_path)
    hub.bootstrap()
    hub.refresh()
    for i, tok in enumerate(("tok-alice", "tok-bob", "tok-carol")):
        submit(hub, tok, Identity.generate(), toward=0.3, seed=i)
    ctx = hub.context()
    plan = score_round(ctx)
    assert plan["kind"] == "publish"
    forged = json.loads(json.dumps(plan))
    forged["merged_sha256"] = "0" * 64
    with pytest.raises(PlanMismatch):
        publish_plan(hub.context(), forged)
    forged = json.loads(json.dumps(plan))
    next(d for d in forged["decisions"] if d["status"] == "accepted")["prefix"] = "pending/eve/v000001-1800000000-0123456789abcdef/"
    with pytest.raises((PlanMismatch, FileNotFoundError)):
        publish_plan(hub.context(), forged)
    assert hub.registry.index().current == 1
    out = publish_plan(hub.context(), plan)
    assert out.status == "published" and out.version == 2


def test_update_weight_is_capped_by_the_task(tmp_path):
    from aggregator.run import Decision, _load
    hub = Hub(tmp_path)
    hub.bootstrap()
    hub.refresh()
    t = submit(hub, "tok-alice", Identity.generate(), toward=0.3)
    (e,) = hub.inbox.entries()
    d = Decision(e.prefix, e.login, e.received_at, "pending")
    c = _load(hub.context(), e, d)
    segments = sum(len(v["segments"]) for v in t["videos"])
    assert c.weight == min(40, segments) and d.weight == c.weight


def test_registry_refuses_unsigned_base(tmp_path):
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    hub = Hub(tmp_path)
    hub.registry.publish(dumps_adapter(init_adapter_tiny()), Ed25519PrivateKey.generate())
    with pytest.raises(RegistryError):
        hub.registry.adapter_bytes(1)


def init_adapter_tiny():
    from protocol.spec import init_adapter
    return init_adapter(tiny_spec(), 0)


def test_round_merge_worse_keeps_previous_version(tmp_path):
    hub = Hub(tmp_path)
    hub.bootstrap()
    hub.refresh()
    for i, tok in enumerate(("tok-alice", "tok-bob")):
        submit(hub, tok, Identity.generate(), toward=0.3, seed=i)
    ctx = hub.context()
    calls = {"n": 0}
    real = ctx.scorer

    class WorseAfterMerge:
        def score(self, adapters):
            calls["n"] += 1
            res = real.score(adapters)
            if "merged" in adapters:
                from aggregator.exam import ExamScore
                res["merged"] = ExamScore(9.9, 0.0, 100)
            return res
    ctx.scorer = WorseAfterMerge()
    out = run_round(ctx)
    assert out.status == "merge_worse" and out.credits == [] and hub.registry.index().current == 1
    assert hub.inbox.entries() == []


def test_round_rolls_back_when_published_file_differs(tmp_path):
    hub = Hub(tmp_path)
    hub.bootstrap()
    hub.refresh()
    for i, tok in enumerate(("tok-alice", "tok-bob")):
        submit(hub, tok, Identity.generate(), toward=0.3, seed=i)
    ctx = hub.context()
    real_publish = ctx.registry.publish

    def corrupting_publish(data, key, **kw):
        v = real_publish(data, key, **kw)
        if kw.get("rollback_of") is None:
            (tmp_path / "models" / "versions" / f"v{v:06d}.safetensors").write_bytes(data[:-4] + b"\0\0\0\0")
        return v
    ctx.registry.publish = corrupting_publish
    out = run_round(ctx)
    idx = hub.registry.index()
    assert out.status == "rolled_back" and out.credits == []
    assert idx.current == 3 and idx.record(3).info.rollback_of == 1 and idx.record(2).status == "revoked"


def test_round_rejects_tampered_stored_update(tmp_path):
    hub = Hub(tmp_path)
    hub.bootstrap()
    hub.refresh()
    for i, tok in enumerate(("tok-alice", "tok-bob", "tok-carol")):
        submit(hub, tok, Identity.generate(), toward=0.3, seed=i)
    e = next(x for x in hub.inbox.entries() if x.login == "bob")
    p = tmp_path / "inbox" / e.prefix / "payload.safetensors"
    b = bytearray(p.read_bytes())
    b[-1] ^= 1
    p.write_bytes(bytes(b))
    out = run_round(hub.context())
    st = {d.login: d for d in out.decisions}
    assert st["bob"].status == "rejected" and st["bob"].reason.startswith("формат")
    assert out.status == "published"


# --- таблица вклада ---
def _render():
    spec = importlib.util.spec_from_file_location("render", ROOT / "tools" / "contributors" / "render.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def test_contributors_update(tmp_path):
    p = tmp_path / "contributors.json"
    p.write_text((ROOT / "contributors.json").read_text())
    before = json.loads(p.read_text())
    assert not update_file(p, [])
    assert update_file(p, [Credit("new-user", 5400, 120), Credit("ZIGANSH1N", 1800, 30), Credit("new-user", 1800, 10)])
    doc = json.loads(p.read_text())
    rows = {r["github"]: r for r in doc["contributors"]}
    assert rows["new-user"] == {"github": "new-user", "data_hours": 2.0, "training_steps": 130, "accepted_updates": 2}
    owner = before["contributors"][0]
    assert rows[owner["github"]]["accepted_updates"] == owner["accepted_updates"] + 1
    assert list(doc) == list(before)
    _render().load(p)   # the schema the README table is rendered from still holds
    with pytest.raises(ValueError):
        merge_credits({"contributors": []}, [Credit("bad login!", 1, 1)])


# --- клиент: приватность ---
def test_personal_folders_are_refused(tmp_path):
    home = tmp_path / "home"
    roots = personal_roots(tmp_path / "lipread", home=home)
    for bad in (home / ".velikiy-moguchiy" / "x", home / ".koe", tmp_path / "lipread" / "clips" / "w", home):
        with pytest.raises(PrivacyError):
            ensure_work_dir(bad, roots)
    assert ensure_work_dir(home / ".velikiy-moguchiy-federated" / "community" / "work", roots)
    work = tmp_path / "work"
    work.mkdir()
    (tmp_path / "secret.mp4").write_bytes(b"x")
    (work / "link.mp4").symlink_to(tmp_path / "secret.mp4")
    with pytest.raises(PrivacyError):
        ensure_inside(work / "link.mp4", work)
    with pytest.raises(PrivacyError):
        ensure_inside(tmp_path / "secret.mp4", work)


def test_outgoing_check_allows_only_three_parts():
    spec = tiny_spec()
    parts = signed_parts(spec, Identity.generate(), 1)
    check_outgoing(parts, spec)
    with pytest.raises(PrivacyError):
        check_outgoing({**parts, "video": MARKER}, spec)
    with pytest.raises(ProtocolError):
        check_outgoing({**parts, "payload": MARKER + bytes(100)}, spec)
    with pytest.raises(Exception):
        check_outgoing({**parts, "contribution": b'{"contribution": {}, "video": "x"}'}, spec)


# --- клиент: полный цикл ---
def test_client_job_sends_only_weights_and_stats(tmp_path):
    hub = Hub(tmp_path / "hub")
    hub.bootstrap()
    hub.refresh()
    home = tmp_path / "user"
    sent: list = []
    pipe = FakePipeline(hub.spec, toward=0.3)
    job = client_job(hub, home, "tok-alice", pipe, capture=sent)
    st = job.run()
    assert st["state"] == "ready_to_send", st["message"]
    assert not any(m == "POST" for m, _, _ in sent)          # nothing goes out before «Отправить»
    preview = read_preview(home)
    assert set(preview) >= {"manifest", "contribution", "payload", "not_sent"}
    assert preview["payload"]["dtype"] == "float16" and preview["contribution"]["contribution"]["training_steps"] == 50
    assert not (home / "community" / "work").exists()       # clips, faces and features are gone after training
    assert all(not p.exists() for p in pipe.downloaded)
    st = job.send()
    assert st["state"] == "done" and st["receipt"]["status"] == "accepted"
    posts = [body for m, path, body in sent if m == "POST"]
    assert len(posts) == 1 and MARKER not in posts[0]
    for _, _, body in sent:
        assert MARKER not in body
    names = sorted(n.decode() for n in re.findall(rb'; name="([^"]+)"', posts[0]))
    assert names == ["contribution", "manifest", "payload"]
    (e,) = hub.inbox.entries()
    stored = b"".join(hub.inbox.read(e, n) for n in ("manifest.json", "payload.safetensors", "contribution.json", "meta.json"))
    assert MARKER not in stored
    assert set(loads_adapter(hub.inbox.read(e, "payload.safetensors"))) == {t.name for t in hub.spec.delta_tensors}
    assert not (home / "community" / "outbox").exists()
    hist = (home / "community" / "history.jsonl").read_text().splitlines()
    assert len(hist) == 1 and json.loads(hist[0])["sent"]["payload"]["sha256"] == preview["payload"]["sha256"]


def test_client_needs_consent_login_and_stops_on_cancel(tmp_path):
    hub = Hub(tmp_path / "hub")
    hub.bootstrap()
    hub.refresh()
    home = tmp_path / "u1"
    job = client_job(hub, home, "tok-alice", FakePipeline(hub.spec), consent_on=False)
    assert job.run()["state"] == "error" and not consent.granted(home, consent.HELP_TRAIN)
    assert not consent.granted(home)        # the other consent is separate and stays off
    consent.record(home, True, kind=consent.HELP_TRAIN)
    (home / "github-token").unlink()
    assert "GitHub" in job.run()["message"]
    home2 = tmp_path / "u2"
    pipe = FakePipeline(hub.spec, cancel_at="prepare")
    job2 = client_job(hub, home2, "tok-bob", pipe)
    st = job2.run()
    assert st["state"] == "cancelled" and not (home2 / "community" / "outbox").exists()
    assert not (home2 / "community" / "work").exists()
    rep = status_report(job2.cfg)
    assert rep["consent"] and rep["logged_in"] and rep["job"]["state"] == "cancelled" and rep["login"] is None
    from client.github_login import logout, save_login
    save_login(home2, "bob")
    assert status_report(job2.cfg)["login"] == "bob"
    logout(home2)
    rep = status_report(job2.cfg)
    assert not rep["logged_in"] and rep["login"] is None


def test_client_takes_signed_versions_straight_from_the_model_repo(tmp_path):
    hub = Hub(tmp_path / "hub")
    hub.bootstrap()
    hub.refresh()
    home = tmp_path / "u"
    job = client_job(hub, home, "tok-alice", FakePipeline(hub.spec, toward=0.3), models_from=tmp_path / "hub")
    st = job.run()
    assert st["state"] == "ready_to_send", st["message"]
    assert json.loads((home / "community" / "adapters" / "index.json").read_text())["current"] == 1
    # a repo whose index is signed by another key is refused
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    other = Hub(tmp_path / "evil")
    other.key = Ed25519PrivateKey.generate()
    other.bootstrap(seed=3)
    job2 = client_job(hub, tmp_path / "u2", "tok-bob", FakePipeline(hub.spec), models_from=tmp_path / "evil")
    st = job2.run()
    assert st["state"] == "error" and "подпис" in st["message"]


def test_client_accepts_only_pinned_front_end(tmp_path):
    hub = Hub(tmp_path / "hub")
    hub.bootstrap()
    hub.refresh()
    home = tmp_path / "u"
    job = client_job(hub, home, "tok-alice", FakePipeline(hub.spec))
    job.venc_allowed = frozenset({"0" * 64})
    st = job.run()
    assert st["state"] == "error" and "визуальную часть" in st["message"]
    from client import community_defaults
    from space.settings import DEFAULT_ASSETS
    assert DEFAULT_ASSETS["venc"]["sha256"] in community_defaults.VENC_SHA256


def test_client_refuses_personal_work_dir(tmp_path, monkeypatch):
    hub = Hub(tmp_path / "hub")
    hub.bootstrap()
    hub.refresh()
    monkeypatch.setenv("HOME", str(tmp_path / "fakehome"))
    home = tmp_path / "fakehome" / ".velikiy-moguchiy" / "fed"
    job = client_job(hub, home, "tok-alice", FakePipeline(hub.spec))
    st = job.run()
    assert st["state"] == "error" and "личной папкой" in st["message"]


def test_controls_pause_and_cancel():
    c = Controls(paused=True)
    ticks = []

    def sleep(s):
        ticks.append(s)
        if len(ticks) == 3:
            c.paused = False
    c.wait_while_paused(sleep)
    assert len(ticks) == 3
    c.cancelled = True
    from client.community import Cancelled
    with pytest.raises(Cancelled):
        c.wait_while_paused(sleep)


# --- полный цикл: участники, сервер, агрегатор, новая версия у клиента ---
def test_end_to_end_simulation(tmp_path):
    hub = Hub(tmp_path / "hub")
    hub.bootstrap()
    hub.refresh()
    wer = exam_fn(hub.spec)
    wer0 = wer(loads_adapter(hub.registry.adapter_bytes(1)))
    people = [("tok-alice", 0.3), ("tok-bob", 0.25), ("tok-carol", 0.35), ("tok-dave", None)]
    for i, (tok, toward) in enumerate(people):
        pipe = FakePipeline(hub.spec, toward=toward or 0.0, poison=None if toward else 2.0, seed=i)
        job = client_job(hub, tmp_path / f"p{i}", tok, pipe, auto_send=True)
        st = job.run()
        assert st["state"] == "done", st["message"]
    out = run_round(hub.context())
    assert out.status == "published"
    assert {d.login for d in out.decisions if d.status == "accepted"} == {"alice", "bob", "carol"}
    assert {d.login for d in out.decisions if d.status == "rejected"} == {"dave"}
    wer1 = wer(loads_adapter(hub.registry.adapter_bytes(2)))
    assert wer1 < wer0
    contributors = tmp_path / "contributors.json"
    contributors.write_text('{"contributors": []}\n')
    update_file(contributors, out.credits)
    rows = {r["github"]: r for r in json.loads(contributors.read_text())["contributors"]}
    assert set(rows) == {"alice", "bob", "carol"} and all(r["accepted_updates"] == 1 for r in rows.values())
    # the next task is on the new version, and the client syncs it with the signature checked
    hub.refresh()
    job = client_job(hub, tmp_path / "p0", "tok-alice", FakePipeline(hub.spec, toward=0.3, seed=11))
    st = job.run()
    assert st["state"] == "ready_to_send" and st["task"]["base_version"] == 2
    assert json.loads((tmp_path / "p0" / "community" / "adapters" / "index.json").read_text())["current"] == 2


# --- хранилища ---
def test_hf_blob_store_with_fake_api(tmp_path):
    pytest.importorskip("huggingface_hub")
    from huggingface_hub import CommitOperationAdd, CommitOperationDelete
    from huggingface_hub.utils import EntryNotFoundError

    from hub.storage import HfBlobStore

    class FakeApi:
        def __init__(self):
            self.files, self.commits = {}, []

        def list_repo_files(self, repo_id, *, revision=None, repo_type=None, token=None):
            assert repo_type == "dataset"
            return list(self.files)

        def hf_hub_download(self, repo_id, filename, *, repo_type=None, revision=None, token=None, **kw):
            if filename not in self.files:
                raise EntryNotFoundError(filename)
            p = tmp_path / "dl" / filename
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(self.files[filename])
            return str(p)

        def super_squash_history(self, repo_id, *, branch=None, commit_message=None, repo_type=None, token=None):
            self.commits = [commit_message]

        def create_commit(self, repo_id, operations, *, commit_message, repo_type=None, revision=None, token=None):
            self.commits.append(commit_message)
            for op in operations:
                if isinstance(op, CommitOperationDelete):
                    for f in [f for f in self.files if f == op.path_in_repo or f.startswith(op.path_in_repo)]:
                        del self.files[f]
                else:
                    assert isinstance(op, CommitOperationAdd)
                    self.files[op.path_in_repo] = op.path_or_fileobj

    api = FakeApi()
    inbox = Inbox(HfBlobStore("o/inbox", "dataset", "tok", api=api))
    e = inbox.put("alice", 3, 1_800_000_000, "ab" * 32, {n: n.encode() for n in
                                                       ("manifest.json", "payload.safetensors", "contribution.json", "meta.json")})
    assert len(api.commits) == 1 and inbox.entries() == [e] and inbox.read(e, "meta.json") == b"meta.json"
    assert inbox.store.read("nope.json") is None
    inbox.write_report("v000004.json", b"{}", [e])
    assert inbox.entries() == [] and list(api.files) == ["rounds/v000004.json"] and api.commits == ["squash"]
    with pytest.raises(ValueError):
        inbox.store.commit({"../x": b""})


def test_inbox_ignores_incomplete_and_foreign_paths(tmp_path):
    store = LocalBlobStore(tmp_path)
    store.commit({"pending/alice/v000001-1800000000-0123456789abcdef/manifest.json": b"{}", "pending/readme.txt": b""})
    assert Inbox(store).entries() == []


# --- деплой Space и командная строка агрегатора ---
def test_space_folder_is_self_contained(tmp_path):
    import subprocess
    import sys

    from space.deploy import assemble, public_key_b64, write_defaults
    d = assemble(tmp_path / "space")
    assert (d / "Dockerfile").exists() and (d / "README.md").read_text().startswith("---\n")
    assert not (d / "client").exists() and not (d / "aggregator").exists()
    code = ("from space.app import create_app; from space.settings import Settings; "
            "import hub.storage, hub.registry, hub.inbox, hub.tasks; print('ok')")
    r = subprocess.run([sys.executable, "-c", code], cwd=d, capture_output=True, text=True,
                       env={"PATH": "/usr/bin:/bin", "PYTHONPATH": str(d)})
    assert r.stdout.strip() == "ok", r.stderr
    key = Ed25519PrivateKey_b64()
    defaults = tmp_path / "community_defaults.py"
    defaults.write_text('"""x"""\nSERVER_URL = ""\nMODEL_SIGNING_PUBLIC_KEY = ""\n')
    assert write_defaults("https://o-s.hf.space", public_key_b64(key), defaults)
    assert not write_defaults("https://o-s.hf.space", public_key_b64(key), defaults)
    ns: dict = {}
    exec(defaults.read_text(), ns)
    assert ns["SERVER_URL"] == "https://o-s.hf.space" and len(ns["MODEL_SIGNING_PUBLIC_KEY"]) == 44


def Ed25519PrivateKey_b64():
    import base64

    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    k = Ed25519PrivateKey.generate()
    return base64.b64encode(k.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw,
                                            serialization.NoEncryption())).decode()


def test_aggregator_cli_status_rollback_export(tmp_path, monkeypatch):
    import base64

    from aggregator import run as agg
    from cryptography.hazmat.primitives import serialization
    hub = Hub(tmp_path)
    hub.bootstrap()
    hub.registry.publish(hub.registry.adapter_bytes(1), hub.key)
    raw = hub.key.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption())
    monkeypatch.setenv("FL_INBOX", f"dir:{tmp_path / 'inbox'}")
    monkeypatch.setenv("FL_MODELS", f"dir:{tmp_path / 'models'}")
    monkeypatch.setenv("FL_MODEL_SIGNING_KEY", base64.b64encode(raw).decode())
    summary = tmp_path / "summary.md"
    monkeypatch.setenv("GITHUB_STEP_SUMMARY", str(summary))
    import protocol.spec as ps
    from client import community_defaults
    monkeypatch.setattr(ps, "load_spec", lambda p: hub.spec)   # the CLI reads the real MultiVSR spec otherwise
    monkeypatch.setattr(community_defaults, "MODEL_SIGNING_PUBLIC_KEY", public_b64(hub.key))
    assert agg.main(["status"]) == 0
    assert agg.main(["rollback", "--to", "1", "--reason", "проверка"]) == 0
    assert hub.registry.index().current == 3 and "Откат" in summary.read_text()
    assert agg.main(["export", "--version", "3", "--out", str(tmp_path / "rel")]) == 0
    assert (tmp_path / "rel" / "lips-adapter-v3.safetensors").read_bytes() == hub.registry.adapter_bytes(1)
    assert json.loads((tmp_path / "rel" / "lips-adapter-v3.json").read_text())["info"]["rollback_of"] == 1


def test_build_pool_skips_test_splits_and_excluded_channels(tmp_path):
    from space.build_pool import main as build
    rows = [{"video_id": "aaaaaaaaaaa", "t_start": 1, "t_end": 3, "transcript": "раз", "split": "train_major"},
            {"video_id": "aaaaaaaaaaa", "t_start": 4, "t_end": 6, "transcript": "два", "split": "train_major"},
            {"video_id": "bbbbbbbbbbb", "t_start": 1, "t_end": 3, "transcript": "три", "split": "test"},
            {"video_id": "ccccccccccc", "t_start": 1, "t_end": 3, "transcript": "четыре", "split": "train_minor"},
            {"video_id": "ddddddddddd", "t_start": 1, "t_end": 3, "transcript": "пять", "split": "train_minor"}]
    (tmp_path / "rows.jsonl").write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows))
    (tmp_path / "ch.tsv").write_text("aaaaaaaaaaa\tUC1\nccccccccccc\tUCbanned0000000000000000\n")
    (tmp_path / "journal.tsv").write_text("UCbanned0000000000000000\t2026-10-14\n")
    (tmp_path / "exam.txt").write_text("ddddddddddd\n")
    assert build(["--rows", str(tmp_path / "rows.jsonl"), "--out", str(tmp_path / "pool.jsonl"), "--channels",
                  str(tmp_path / "ch.tsv"), "--exclude-videos", str(tmp_path / "exam.txt"),
                  "--journal", str(tmp_path / "journal.tsv"), "--shards", str(tmp_path / "shards")]) == 0
    p = parse_pool((tmp_path / "pool.jsonl").read_text().splitlines())
    assert [v.video_id for v in p] == ["aaaaaaaaaaa"] and len(p[0].segments) == 2
    assert json.loads((tmp_path / "shards" / "index.json").read_text()) == {"shards": 1}


def test_pipeline_never_sets_the_r11_job_itself_and_needs_the_guard(tmp_path, monkeypatch):
    from client.community import JobError
    from client.config import ClientConfig, GuardCfg
    from client.lipread_pipeline import VIDEO_FORMAT, LipreadPipeline
    pipe = LipreadPipeline(ClientConfig(home=tmp_path))
    monkeypatch.delenv("VELIKIY_MOGUCHIY_APP_JOB", raising=False)
    assert "VELIKIY_MOGUCHIY_APP_JOB" not in pipe._env()
    monkeypatch.setenv("VELIKIY_MOGUCHIY_APP_JOB", "train-on-me")
    assert "VELIKIY_MOGUCHIY_APP_JOB" not in pipe._env()
    monkeypatch.setenv("VELIKIY_MOGUCHIY_APP_JOB", "help-train")
    assert pipe._env()["VELIKIY_MOGUCHIY_APP_JOB"] == "help-train"
    off = LipreadPipeline(ClientConfig(home=tmp_path, guard=GuardCfg(enabled=False)))
    with pytest.raises(JobError):
        off._guarded(["python", "train.py"])
    assert all(alt.startswith("bv[") for alt in VIDEO_FORMAT.split("/"))   # video-only streams, never bv*


def test_exam_takes_only_public_clips(tmp_path):
    from aggregator.build_exam import main as build
    rows = []
    for i, source in enumerate(["public", "silent", "voiced", "public", None]):
        f = tmp_path / f"f{i}.npy"
        np.save(f, np.zeros((30, 512), np.float16))
        rows.append({"id": f"c{i}", "text": f"фраза {i}", "feats": str(f), "split": "test", "source": source})
    (tmp_path / "m.jsonl").write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows))
    assert build(["--manifest", str(tmp_path / "m.jsonl"), "--out", str(tmp_path / "exam")]) == 0
    texts = sorted(json.loads(ln)["text"] for ln in (tmp_path / "exam" / "exam.jsonl").read_text().splitlines() if ln)
    assert texts == ["фраза 0", "фраза 3"]
    assert len(list((tmp_path / "exam" / "feats").glob("*.npy"))) == 2


def test_fetch_score_offline_then_publish_with_the_key(tmp_path):
    from aggregator.exam import FunctionScorer
    from aggregator.run import Context, RoundConfig, fetch, publish_plan, score_round
    hub = Hub(tmp_path / "hub")
    hub.bootstrap()
    hub.refresh()
    for i, tok in enumerate(("tok-alice", "tok-bob", "tok-carol")):
        submit(hub, tok, Identity.generate(), toward=0.3, seed=i)
    fetch(hub.context(), tmp_path / "round")
    offline = Context(inbox=Inbox(LocalBlobStore(tmp_path / "round" / "inbox")),
                      registry=Registry(LocalBlobStore(tmp_path / "round" / "models"), hub.spec, public_key=public_b64(hub.key)),
                      spec=hub.spec, scorer=FunctionScorer(exam_fn(hub.spec)), signing_key=None,
                      cfg=RoundConfig(min_clients=2, min_accepted=2), clock=lambda: hub.clock[0])
    plan = json.loads(json.dumps(score_round(offline)))
    assert plan["kind"] == "publish" and len(hub.inbox.entries()) == 3
    out = publish_plan(hub.context(), plan)
    assert out.status == "published" and hub.inbox.entries() == []
    # scoring refuses a base whose description is not signed by the project's key
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    stranger = Registry(LocalBlobStore(tmp_path / "round" / "models"), hub.spec,
                        public_key=public_b64(Ed25519PrivateKey.generate()))
    with pytest.raises(RegistryError):
        stranger.adapter_bytes(1)


def test_bootstrap_is_scored_and_published_from_the_same_bytes(tmp_path):
    from aggregator.run import PlanMismatch, publish_plan, score_round
    from protocol.spec import init_adapter
    hub = Hub(tmp_path)
    first = dumps_adapter(init_adapter(hub.spec, 7))
    ctx = hub.context()
    ctx.bootstrap_adapter = lambda: first
    plan = score_round(ctx)
    assert plan["kind"] == "bootstrap"
    ctx2 = hub.context()
    ctx2.bootstrap_adapter = lambda: dumps_adapter(init_adapter(hub.spec, 8))
    with pytest.raises(PlanMismatch):
        publish_plan(ctx2, plan)
    out = publish_plan(ctx, plan)
    assert out.status == "bootstrapped" and hub.registry.adapter_bytes(1) == first


def test_pipeline_finds_ffmpeg_of_the_app_environment(tmp_path, monkeypatch):
    import shutil as sh

    from client.config import ClientConfig
    from client.lipread_pipeline import LipreadPipeline
    lipread = tmp_path / "lips" / "service"
    (lipread / "bin").mkdir(parents=True)
    (lipread / "bin" / "ffmpeg").write_text("")
    monkeypatch.setattr(sh, "which", lambda name: None)
    cfg = ClientConfig(home=tmp_path / "home")
    cfg.training.lipread_ru_dir = str(lipread)
    assert LipreadPipeline(cfg).ffmpeg == str(lipread / "bin" / "ffmpeg")


def test_exam_selection_is_balanced_by_speaker():
    from aggregator.exam_features import balanced
    rows = [{"id": f"{s}{i:02d}", "speaker": s} for s in "abc" for i in range(10 if s == "a" else 3)]
    pick = balanced(rows, 7)
    assert [r["id"] for r in pick] == ["a00", "b00", "c00", "a01", "b01", "c01", "a02"]
    assert len(balanced(rows, 100)) == 16


def test_client_skips_videos_of_excluded_channels(tmp_path):
    hub = Hub(tmp_path / "hub")
    hub.bootstrap()
    hub.refresh()
    home = tmp_path / "u"
    banned = "UC" + "b" * 22
    pipe = FakePipeline(hub.spec, channels={v.video_id: banned for v in pool(n=40)})
    job = client_job(hub, home, "tok-alice", pipe)
    job.exclusions_loader = lambda: {banned}
    st = job.run()
    assert st["state"] == "error" and "Ни один ролик" in st["message"]
    pipe2 = FakePipeline(hub.spec, channels={v.video_id: banned for v in pool(n=40)})
    job2 = client_job(hub, tmp_path / "u2", "tok-bob", pipe2)
    job2.exclusions_loader = lambda: {"UC" + "c" * 22}
    assert job2.run()["state"] == "ready_to_send"

    def broken():
        from client.community import JobError
        raise JobError("Журнал исключений каналов недоступен")
    job3 = client_job(hub, tmp_path / "u3", "tok-dave", FakePipeline(hub.spec))
    job3.exclusions_loader = broken
    st = job3.run()
    assert st["state"] == "error" and "Журнал исключений" in st["message"]
