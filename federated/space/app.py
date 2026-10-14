"""HTTP API сервера на Hugging Face Space (uvicorn space.app:app, порт 7860).

  GET  /                        короткая страница о сервере
  GET  /v1/health               {"status": "ok", "protocol": 2, "latest_version": N}
  GET  /v1/config               открытые настройки: Client ID для входа через GitHub, спецификация, лимиты
  GET  /v1/model/latest         подписанное описание текущей версии адаптера (подпись делает агрегатор)
  GET  /v1/model/{v}/adapter    файл версии (safetensors fp32)
  GET  /v1/task                 [вход через GitHub] задание: ролики, отрезки, настройки обучения, токен
  POST /v1/updates              [вход через GitHub] multipart: manifest, payload, contribution

Сервер ничего не хранит у себя: обновления уходят в закрытый датасет (hub/inbox.py), версии читаются из
репозитория модели (hub/registry.py). Токен GitHub не сохраняется и не пишется в журнал.
"""
from __future__ import annotations

import collections
import json
import threading
import time
from typing import Callable

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, JSONResponse, Response
from starlette.concurrency import run_in_threadpool

from protocol import PROTOCOL_VERSION
from protocol.contribution import MAX_CONTRIBUTION_BYTES, verify_contribution
from protocol.errors import ProtocolError
from protocol.package import MAX_ENVELOPE_BYTES, verify_update
from protocol.schema import UpdateReceipt
from protocol.spec import AdapterSpec
from hub.github_auth import GithubVerifier
from hub.inbox import Inbox
from hub.registry import Registry, RegistryError, RegistryIndex
from hub.tasks import Exclusions, TaskIssuer, parse_exclusions, parse_pool, verify_token
from server.ratelimit import IpLimiter

MULTIPART_OVERHEAD = 16 * 1024
DAY = 86400

PAGE = """<!doctype html><meta charset="utf-8"><title>«Великий & Могучий»: обучение силами участников</title>
<body style="font-family:system-ui;max-width:40em;margin:3em auto;line-height:1.5">
<h1>«Великий & Могучий»: обучение силами участников</h1>
<p>Сюда приложение участника отправляет обновление весов модели чтения по губам после обучения у себя на компьютере.
Видео, звук и кадры лица сюда не попадают: только обновление весов (safetensors) и числа о вкладе.</p>
<p>Код и правила: <a href="https://github.com/zigansh1n/velikiy-moguchiy/tree/main/federated">github.com/zigansh1n/velikiy-moguchiy</a>.</p>
</body>"""


class TTL:
    """Значение, которое перечитывается не чаще раза в ttl секунд; при ошибке остаётся прежнее."""

    def __init__(self, load: Callable[[], object], ttl: float, clock: Callable[[], float] = time.monotonic):
        self.load, self.ttl, self.clock = load, ttl, clock
        self.value, self.at, self.lock = None, None, threading.Lock()

    def get(self):
        with self.lock:
            fresh = self.at is not None and self.clock() - self.at < self.ttl
            if fresh:
                return self.value
        try:
            v = self.load()
        except Exception:
            if self.value is None:
                raise
            return self.value
        with self.lock:
            self.value, self.at = v, self.clock()
        return v

    def invalidate(self) -> None:
        with self.lock:
            self.at = None


class LoginLimiter:
    """Сколько раз логин сделал что-то за 24 часа (в памяти; для обновлений ещё и по датасету — см. ниже)."""

    def __init__(self, per_day: int, what: str, clock: Callable[[], float] = time.time):
        self.per_day, self.what, self.clock = per_day, what, clock
        self.hits: dict[str, collections.deque] = {}
        self.lock = threading.Lock()

    def check(self, login: str, recorded: list[float] = ()) -> None:
        now = self.clock()
        with self.lock:
            q = self.hits.setdefault(login.lower(), collections.deque())
            while q and now - q[0] > DAY:
                q.popleft()
            # the in-memory log is empty after a restart, the stored updates are not: the longer list counts
            stored = sorted(t for t in recorded if now - t <= DAY)
            times = list(q) if len(q) >= len(stored) else stored
            if len(times) >= self.per_day:
                raise ProtocolError("rate_limited", f"не больше {self.per_day} {self.what} за 24 часа",
                                    retry_after=max(1, int(times[0] + DAY - now)))
            q.append(now)


def fetch_exclusions(urls: list[str], http: httpx.Client) -> Exclusions:
    """Fails closed: an unreachable list raises, so no task goes out without the exclusions. 404 = no such file."""
    videos, channels = set(), set()
    for u in urls:
        r = http.get(u)
        if r.status_code == 404:
            continue
        r.raise_for_status()
        e = parse_exclusions(r.text)
        videos |= e.videos
        channels |= e.channels
    return Exclusions(frozenset(videos), frozenset(channels))


def create_app(*, spec: AdapterSpec, inbox: Inbox, registry: Registry, verifier: GithubVerifier, task_secret: bytes,
               pool_loader: Callable[[], list], exclusions_loader: Callable[[], Exclusions] = Exclusions,
               github_client_id: str = "", max_updates_per_day: int = 2, max_tasks_per_day: int = 3,
               max_update_norm: float = 50.0, videos_per_task: int = 8, ip_per_minute: int = 60,
               banned: frozenset[str] = frozenset(), training: dict | None = None, assets: dict | None = None,
               clock: Callable[[], float] = time.time) -> FastAPI:
    app = FastAPI(title="Velikiy Moguchiy community training", docs_url=None, redoc_url=None, openapi_url=None)
    ip_limiter = IpLimiter(ip_per_minute)
    task_limiter = LoginLimiter(max_tasks_per_day, "заданий", clock)
    update_limiter = LoginLimiter(max_updates_per_day, "обновлений", clock)
    index_cache = TTL(registry.index, 60.0)
    pool_cache = TTL(pool_loader, 3600.0)
    excl_cache = TTL(exclusions_loader, 900.0)
    adapters: collections.OrderedDict[int, bytes] = collections.OrderedDict()
    issuer = TaskIssuer(pool=[], secret=task_secret, videos_per_task=videos_per_task, exclusions=excl_cache.get,
                        clock=clock, **({"training": dict(training)} if training else {}), **({"assets": dict(assets)} if assets else {}))
    issue_lock, update_lock = threading.Lock(), threading.Lock()

    @app.exception_handler(ProtocolError)
    async def _perr(_: Request, e: ProtocolError):
        headers = {"Retry-After": str(int(e.extra["retry_after"]))} if "retry_after" in e.extra else None
        body = e.to_body()
        body.pop("retry_after", None)
        return JSONResponse(body, status_code=e.status, headers=headers)

    @app.exception_handler(RegistryError)
    async def _rerr(_: Request, e: RegistryError):
        return JSONResponse({"error": "unavailable", "message": str(e)}, status_code=503)

    @app.middleware("http")
    async def _guard(request: Request, call_next):
        # Spaces sit behind a proxy that appends the client address to X-Forwarded-For; earlier hops are the
        # client's own and can be forged, so the last one counts
        fwd = request.headers.get("x-forwarded-for", "")
        ip = fwd.split(",")[-1].strip() or (request.client.host if request.client else "?")
        try:
            ip_limiter.check(ip)
        except ProtocolError as e:
            return await _perr(request, e)
        return await call_next(request)

    def current() -> tuple[RegistryIndex, int]:
        idx = index_cache.get()
        if not idx.current:
            raise ProtocolError("unavailable", "общий адаптер ещё не опубликован")
        return idx, idx.current

    def user_of(request: Request):
        user = verifier.verify(request.headers.get("authorization"))
        if user.login.lower() in banned:
            raise ProtocolError("banned", "участие для этого аккаунта закрыто")
        return user

    @app.get("/", response_class=HTMLResponse)
    def root():
        return PAGE

    @app.get("/v1/health")
    def health():
        try:
            latest = index_cache.get().current
        except Exception:  # noqa: BLE001
            latest = None
        return {"status": "ok", "protocol": PROTOCOL_VERSION, "latest_version": latest}

    @app.get("/v1/config")
    def config():
        return {"protocol": PROTOCOL_VERSION, "github_client_id": github_client_id, "spec_id": spec.spec_id,
                "spec_hash": spec.hash, "max_updates_per_day": max_updates_per_day,
                "max_tasks_per_day": max_tasks_per_day, "max_update_norm": max_update_norm}

    @app.get("/v1/model/latest")
    def model_latest():
        idx, v = current()
        return idx.record(v).info.model_dump(mode="json")

    @app.get("/v1/model/{version}/adapter")
    def model_adapter(version: int):
        idx = index_cache.get()
        try:
            rec = idx.record(version)
        except KeyError:
            rec = None
        if rec is None or rec.status != "active":
            raise ProtocolError("not_found", f"версии {version} нет или она отозвана")
        data = adapters.get(version)
        if data is None:
            data = registry.adapter_bytes(version, idx)
            adapters[version] = data
            while len(adapters) > 3:
                adapters.popitem(last=False)
        return Response(data, media_type="application/octet-stream", headers={"ETag": rec.info.sha256})

    @app.get("/v1/task")
    def task(request: Request):
        user = user_of(request)
        _, base = current()
        try:
            pool = pool_cache.get()
            excl_cache.get()
        except Exception as e:  # noqa: BLE001
            raise ProtocolError("unavailable", f"список роликов или исключений недоступен: {type(e).__name__}") from e
        task_limiter.check(user.login)
        with issue_lock:
            issuer.pool = pool
            return issuer.issue(user.login, base)

    @app.post("/v1/updates")
    async def post_update(request: Request):
        cl = request.headers.get("content-length")
        if cl is None:
            raise ProtocolError("length_required", "нужен Content-Length")
        limit = spec.max_payload_bytes() + MAX_ENVELOPE_BYTES + MAX_CONTRIBUTION_BYTES + MULTIPART_OVERHEAD
        if not cl.isdigit() or int(cl) > limit:
            raise ProtocolError("too_large", f"тело запроса больше {limit} байт")
        user = await run_in_threadpool(user_of, request)
        form = await request.form(max_files=3, max_fields=3)
        parts = {k: form.get(k) for k in ("manifest", "payload", "contribution")}
        if any(p is None or not hasattr(p, "read") for p in parts.values()) or len(form) != 3:
            raise ProtocolError("bad_schema", "нужны ровно три файловые части: manifest, payload, contribution")
        envelope, payload, contribution = [await parts[k].read() for k in ("manifest", "payload", "contribution")]
        return await run_in_threadpool(handle_update, user, envelope, payload, contribution)

    def handle_update(user, envelope: bytes, payload: bytes, contribution: bytes) -> dict:
        # one process serves the Space: the lock makes "one update per login and version" a real check
        with update_lock:
            return _handle_update(user, envelope, payload, contribution)

    def _handle_update(user, envelope: bytes, payload: bytes, contribution: bytes) -> dict:
        v = verify_update(envelope, payload, spec)          # только safetensors; подпись, хэш, формы, конечность
        m = v.manifest
        c = verify_contribution(contribution, m)
        idx, cur = current()
        if m.base_version != cur:
            known = any(r.version == m.base_version for r in idx.versions)
            raise ProtocolError("stale_base" if known else "unknown_base",
                                f"база v{m.base_version} устарела, актуальна v{cur}", latest_version=cur)
        claims = verify_token(c.task_token, task_secret, login=user.login, base_version=cur, now=clock())
        if m.num_examples > claims.segments:
            raise ProtocolError("bad_task", f"примеров {m.num_examples}, а в задании {claims.segments} отрезков")
        mine = inbox.entries(user.login)
        for e in mine:
            if e.base_version == cur:
                if e.sha16 == m.payload_sha256[:16]:
                    return UpdateReceipt(status="duplicate", update_id=e.prefix, base_version=cur, update_norm=v.norm,
                                         pending_in_round=sum(1 for x in inbox.entries() if x.base_version == cur)).model_dump()
                raise ProtocolError("conflict", "на эту версию адаптера от вас уже принято другое обновление")
        update_limiter.check(user.login, [e.received_at for e in mine])
        if v.norm > max_update_norm:
            raise ProtocolError("norm_too_large", f"L2-норма {v.norm:.3f} больше допустимой {max_update_norm}")
        now = int(clock())
        meta = {"protocol": PROTOCOL_VERSION, "login": user.login, "github_id": user.id, "client_id": m.client_id,
                "received_at": now, "base_version": cur, "norm": v.norm, "num_examples": m.num_examples,
                "task": {"task_id": claims.task_id, "seconds_max": claims.seconds_max, "steps_max": claims.steps_max,
                         "segments": claims.segments}}
        e = inbox.put(user.login, cur, now, m.payload_sha256, {
            "manifest.json": envelope, "payload.safetensors": payload, "contribution.json": contribution,
            "meta.json": json.dumps(meta, ensure_ascii=False).encode()})
        pending = sum(1 for x in inbox.entries() if x.base_version == cur)
        return UpdateReceipt(status="accepted", update_id=e.prefix, base_version=cur, update_norm=v.norm,
                             pending_in_round=pending).model_dump()

    app.state.index_cache = index_cache
    return app


def build_from_env():
    from pathlib import Path

    from hub.storage import open_store
    from protocol.spec import load_spec
    from space.settings import Settings

    s = Settings.from_env()
    spec = load_spec(Path(__file__).resolve().parent.parent / "protocol" / "specs" / "multivsr_lora_r16.json")
    inbox_store = open_store(s.inbox, s.hf_token, "dataset")
    http = httpx.Client(timeout=15.0, trust_env=False, follow_redirects=True)

    def load_pool():
        raw = inbox_store.read(s.pool_path)
        return parse_pool((raw or b"").decode("utf8").splitlines())

    return create_app(spec=spec, inbox=Inbox(inbox_store), registry=Registry(open_store(s.models, s.hf_token, "model"), spec),
                      verifier=GithubVerifier(min_account_age_days=s.min_account_age_days), task_secret=s.task_secret,
                      pool_loader=load_pool, exclusions_loader=lambda: fetch_exclusions(s.exclusion_urls, http),
                      github_client_id=s.github_client_id, max_updates_per_day=s.max_updates_per_day,
                      max_tasks_per_day=s.max_tasks_per_day, max_update_norm=s.max_update_norm,
                      videos_per_task=s.videos_per_task, ip_per_minute=s.ip_per_minute, banned=s.banned,
                      training=s.training, assets=s.assets)


def __getattr__(name: str):
    # `uvicorn space.app:app` builds the app from the environment on first access; tests call create_app directly
    if name == "app":
        a = build_from_env()
        globals()["app"] = a
        return a
    raise AttributeError(name)
