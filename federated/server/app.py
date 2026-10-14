"""FastAPI-приложение: POST /v1/updates, GET /v1/model/latest, GET /v1/model/{v}/adapter, GET /v1/health.

Запуск только через server.run (привязка к loopback). Тела ответов об ошибках: {"error": код, "message": ...}.
"""
from __future__ import annotations

import time
import uuid
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response

from protocol.errors import ProtocolError
from protocol.package import MAX_ENVELOPE_BYTES, verify_update
from protocol.schema import ModelInfo, UpdateReceipt
from server.config import ServerConfig, load_config
from server.ratelimit import IpLimiter, check_client_quota
from server.store import Store

MULTIPART_OVERHEAD = 16 * 1024


def create_app(data_dir: Path, config: ServerConfig | None = None) -> FastAPI:
    store = Store(data_dir)
    if not store.initialized:
        raise SystemExit(f"{data_dir}: не инициализировано. Сначала: python -m server.admin init --data-dir {data_dir} --spec ...")
    cfg = config or load_config(data_dir)
    spec = store.spec
    ip_limiter = IpLimiter(cfg.limits.ip_requests_per_minute)
    app = FastAPI(title="Velikiy Moguchiy federated", docs_url=None, redoc_url=None, openapi_url=None)
    app.state.store, app.state.cfg = store, cfg

    @app.exception_handler(ProtocolError)
    async def _perr(_: Request, e: ProtocolError):
        headers = {"Retry-After": str(int(e.extra["retry_after"]))} if "retry_after" in e.extra else None
        body = e.to_body()
        body.pop("retry_after", None)
        return JSONResponse(body, status_code=e.status, headers=headers)

    @app.middleware("http")
    async def _guard(request: Request, call_next):
        try:
            ip_limiter.check(request.client.host if request.client else "?")
        except ProtocolError as e:
            return await _perr(request, e)
        return await call_next(request)

    @app.get("/v1/health")
    def health():
        return {"status": "ok", "protocol": 1, "latest_version": store.current_version()}

    def _info(conn, version: int) -> ModelInfo:
        r = conn.execute("SELECT info_json, status FROM versions WHERE version=?", (version,)).fetchone()
        if not r or r["status"] != "active":
            raise ProtocolError("not_found", f"версии {version} нет или она отозвана")
        return ModelInfo.model_validate_json(r["info_json"])

    @app.get("/v1/model/latest")
    def model_latest():
        with store.db() as c:
            v = store.current_version(c)
            return _info(c, v).model_dump(mode="json")

    @app.get("/v1/model/{version}/adapter")
    def model_adapter(version: int):
        with store.db() as c:
            info = _info(c, version)
        data = store.version_path(version).read_bytes()
        return Response(data, media_type="application/octet-stream", headers={"ETag": info.sha256})

    @app.post("/v1/updates")
    async def post_update(request: Request):
        # 1. лимит размера ДО чтения тела (Content-Length обязателен: chunked не принимаем)
        cl = request.headers.get("content-length")
        if cl is None:
            raise ProtocolError("length_required", "нужен Content-Length")
        limit = spec.max_payload_bytes() + MAX_ENVELOPE_BYTES + MULTIPART_OVERHEAD
        if not cl.isdigit() or int(cl) > limit:
            raise ProtocolError("too_large", f"тело запроса больше {limit} байт")
        form = await request.form(max_files=2, max_fields=2)
        m_part, p_part = form.get("manifest"), form.get("payload")
        if m_part is None or p_part is None or not hasattr(m_part, "read") or not hasattr(p_part, "read"):
            raise ProtocolError("bad_schema", "нужны файловые части manifest и payload")
        envelope, payload = await m_part.read(), await p_part.read()
        return _handle_update(envelope, payload)

    def _handle_update(envelope: bytes, payload: bytes):
        v = verify_update(envelope, payload, spec)  # схема, подпись, хэш, форма, конечность, норма
        m = v.manifest
        now = int(time.time())
        with store.db() as c:
            c.execute("BEGIN IMMEDIATE")
            try:
                row = c.execute("SELECT banned FROM clients WHERE client_id=?", (m.client_id,)).fetchone()
                if row is None:
                    c.execute("INSERT INTO clients (client_id, public_key, first_seen) VALUES (?,?,?)",
                              (m.client_id, m.public_key, now))
                elif row["banned"]:
                    raise ProtocolError("banned", "установка заблокирована")
                # повтор того же обновления (клиент не получил ответ): идемпотентно, даже если база уже устарела
                dup = c.execute("SELECT update_id, payload_sha256, norm, base_version FROM updates "
                                "WHERE client_id=? AND base_version=?", (m.client_id, m.base_version)).fetchone()
                if dup is not None:
                    if dup["payload_sha256"] != m.payload_sha256:
                        raise ProtocolError("conflict", "для этой базовой версии уже принято другое обновление")
                    n = c.execute("SELECT COUNT(*) n FROM updates WHERE base_version=? AND status='pending'",
                                  (m.base_version,)).fetchone()["n"]
                    c.execute("COMMIT")
                    return UpdateReceipt(status="duplicate", update_id=dup["update_id"], base_version=m.base_version,
                                         update_norm=dup["norm"], pending_in_round=n).model_dump()
                cur = store.current_version(c)
                if m.base_version != cur:
                    known = c.execute("SELECT 1 FROM versions WHERE version=?", (m.base_version,)).fetchone()
                    store.event(c, m.client_id, "stale_base" if known else "unknown_base", f"base={m.base_version} cur={cur}")
                    c.execute("COMMIT")
                    raise ProtocolError("stale_base" if known else "unknown_base",
                                        f"база v{m.base_version} устарела, актуальна v{cur}", latest_version=cur)
                try:
                    check_client_quota(c, m.client_id, cfg.limits.max_updates_per_client_per_day, now)
                except ProtocolError:
                    c.execute("COMMIT")
                    raise
                if v.norm > cfg.limits.max_update_norm:
                    store.event(c, m.client_id, "norm_too_large", f"norm={v.norm:.3f} max={cfg.limits.max_update_norm}")
                    c.execute("COMMIT")
                    raise ProtocolError("norm_too_large",
                                        f"L2-норма {v.norm:.3f} больше допустимой {cfg.limits.max_update_norm}")
                uid = uuid.uuid4().hex
                path = store.incoming_dir / f"{uid}.safetensors"
                path.write_bytes(payload)
                c.execute("INSERT INTO updates (update_id, client_id, base_version, num_examples, norm, payload_sha256,"
                          " payload_path, received_at) VALUES (?,?,?,?,?,?,?,?)",
                          (uid, m.client_id, m.base_version, m.num_examples, v.norm, m.payload_sha256, str(path), now))
                n = c.execute("SELECT COUNT(*) n FROM updates WHERE base_version=? AND status='pending'",
                              (m.base_version,)).fetchone()["n"]
                c.execute("COMMIT")
            except BaseException:
                if c.in_transaction:
                    c.execute("ROLLBACK")
                raise
        return UpdateReceipt(status="accepted", update_id=uid, base_version=m.base_version, update_norm=v.norm,
                             pending_in_round=n).model_dump()

    return app
