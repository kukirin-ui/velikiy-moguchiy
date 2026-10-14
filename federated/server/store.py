"""Хранилище сервера: SQLite (метаданные) и файлы на диске (адаптеры, входящие дельты)."""
from __future__ import annotations

import contextlib
import json
import sqlite3
import time
from pathlib import Path
from typing import Iterator, Optional

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from protocol.spec import AdapterSpec, load_spec

SCHEMA = """
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS versions (
  version INTEGER PRIMARY KEY, sha256 TEXT NOT NULL, size_bytes INTEGER NOT NULL, created_at INTEGER NOT NULL,
  spec_hash TEXT NOT NULL, round_clients INTEGER, rollback_of INTEGER,
  status TEXT NOT NULL DEFAULT 'active', info_json TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS clients (
  client_id TEXT PRIMARY KEY, public_key TEXT NOT NULL, first_seen INTEGER NOT NULL, banned INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS updates (
  update_id TEXT PRIMARY KEY, client_id TEXT NOT NULL, base_version INTEGER NOT NULL, num_examples INTEGER NOT NULL,
  norm REAL NOT NULL, payload_sha256 TEXT NOT NULL, payload_path TEXT, received_at INTEGER NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending', round_version INTEGER,
  UNIQUE (client_id, base_version));
CREATE INDEX IF NOT EXISTS updates_base ON updates (base_version, status);
CREATE TABLE IF NOT EXISTS rounds (
  round_version INTEGER PRIMARY KEY, base_version INTEGER NOT NULL, created_at INTEGER NOT NULL,
  n_received INTEGER NOT NULL, method TEXT NOT NULL, clip_norm REAL, stats_json TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'ok');
CREATE TABLE IF NOT EXISTS request_log (client_id TEXT NOT NULL, ts INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS request_log_c ON request_log (client_id, ts);
CREATE TABLE IF NOT EXISTS events (ts INTEGER NOT NULL, client_id TEXT, kind TEXT NOT NULL, detail TEXT);
"""


class Store:
    def __init__(self, data_dir: Path):
        self.dir = Path(data_dir)
        self.versions_dir = self.dir / "versions"
        self.incoming_dir = self.dir / "incoming"
        self.keys_dir = self.dir / "keys"
        self.db_path = self.dir / "fl.sqlite"

    # --- подготовка ---
    def init_dirs(self) -> None:
        for d in (self.dir, self.versions_dir, self.incoming_dir, self.keys_dir):
            d.mkdir(parents=True, exist_ok=True)
        self.keys_dir.chmod(0o700)
        with self.db() as c:
            c.executescript(SCHEMA)

    @property
    def initialized(self) -> bool:
        return self.db_path.exists() and (self.dir / "spec.json").exists()

    @contextlib.contextmanager
    def db(self) -> Iterator[sqlite3.Connection]:
        conn = sqlite3.connect(self.db_path, timeout=30, isolation_level=None)  # autocommit; транзакции явно
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA busy_timeout=30000")
        try:
            yield conn
        finally:
            conn.close()

    # --- спецификация и ключи ---
    @property
    def spec(self) -> AdapterSpec:
        if not hasattr(self, "_spec"):
            self._spec = load_spec(self.dir / "spec.json")
        return self._spec

    def signing_key(self) -> Ed25519PrivateKey:
        raw = (self.keys_dir / "model_signing.key").read_bytes()
        return Ed25519PrivateKey.from_private_bytes(raw)

    def create_signing_key(self) -> Ed25519PrivateKey:
        p = self.keys_dir / "model_signing.key"
        if p.exists():
            return self.signing_key()
        key = Ed25519PrivateKey.generate()
        raw = key.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption())
        p.write_bytes(raw)
        p.chmod(0o600)
        return key

    # --- версии ---
    def version_path(self, v: int) -> Path:
        return self.versions_dir / f"v{v:06d}.safetensors"

    def current_version(self, conn: Optional[sqlite3.Connection] = None) -> Optional[int]:
        def q(c):
            r = c.execute("SELECT value FROM meta WHERE key='current_version'").fetchone()
            return int(r["value"]) if r else None
        if conn is not None:
            return q(conn)
        with self.db() as c:
            return q(c)

    def event(self, conn, client_id: Optional[str], kind: str, detail: str = "") -> None:
        conn.execute("INSERT INTO events (ts, client_id, kind, detail) VALUES (?,?,?,?)",
                     (int(time.time()), client_id, kind, detail[:500]))

    def get_meta(self, conn, key: str, default=None):
        r = conn.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
        return json.loads(r["value"]) if r else default

    def set_meta(self, conn, key: str, value) -> None:
        conn.execute("INSERT INTO meta (key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                     (key, json.dumps(value)))
