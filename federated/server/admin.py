"""Админ-CLI: python -m server.admin <команда> --data-dir DIR

  init --spec SPEC.json [--seed N | --from-adapter F.safetensors]   создать хранилище, ключ подписи, версию v1
  status                       текущая версия, ожидающие обновления, события
  versions                     все версии (active/revoked)
  rounds                       все раунды: сколько клиентов, норма клиппинга, кого клиппили/отбросили
  keys                         публичный ключ подписи моделей (его закрепляют в клиенте)
  rollback --to N              откат: публикуется НОВАЯ версия с содержимым N; версии после N отзываются
  ban CLIENT_ID / unban CLIENT_ID
  prune [--older-than-days 180]   удалить старые служебные записи (хранение)
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
import time
from pathlib import Path

from protocol.adapter_io import dumps_adapter, load_adapter, validate_against_spec
from protocol.modelsig import public_b64, sign_model_info
from protocol.schema import ModelInfo
from protocol.spec import init_adapter, load_spec, save_spec
from server.store import Store

import numpy as np


def _publish(store: Store, conn, data: bytes, *, round_clients=None, rollback_of=None, now=None) -> int:
    spec = store.spec
    now = int(time.time()) if now is None else now
    ver = (conn.execute("SELECT MAX(version) m FROM versions").fetchone()["m"] or 0) + 1
    store.version_path(ver).write_bytes(data)
    part = dict(version=ver, spec_id=spec.spec_id, spec_hash=spec.hash, sha256=hashlib.sha256(data).hexdigest(),
                size_bytes=len(data), created_at=now, round_clients=round_clients, rollback_of=rollback_of,
                download_path=f"/v1/model/{ver}/adapter")
    info = ModelInfo(**part, signature=sign_model_info(part, store.signing_key()))
    conn.execute("INSERT INTO versions (version, sha256, size_bytes, created_at, spec_hash, round_clients, rollback_of, info_json)"
                 " VALUES (?,?,?,?,?,?,?,?)", (ver, info.sha256, len(data), now, spec.hash, round_clients, rollback_of,
                                                info.model_dump_json()))
    store.set_meta(conn, "current_version", ver)
    return ver


def cmd_init(a) -> int:
    store = Store(Path(a.data_dir))
    if (store.dir / "spec.json").exists():
        print("уже инициализировано", file=sys.stderr)
        return 1
    store.init_dirs()
    spec = load_spec(a.spec)
    save_spec(spec, store.dir / "spec.json")
    key = store.create_signing_key()
    if a.from_adapter:
        tensors = load_adapter(a.from_adapter)
        validate_against_spec(tensors, spec, delta=False, dtype=np.float32)
    else:
        tensors = init_adapter(spec, a.seed)
    with store.db() as c:
        c.execute("BEGIN IMMEDIATE")
        v = _publish(store, c, dumps_adapter(tensors, {"spec_hash": spec.hash}))
        c.execute("COMMIT")
    print(f"создано {store.dir}, версия v{v}, спецификация {spec.spec_id} ({spec.num_params} параметров)")
    print(f"публичный ключ подписи моделей (base64): {public_b64(key)}")
    return 0


def cmd_status(a) -> int:
    store = Store(Path(a.data_dir))
    with store.db() as c:
        cur = store.current_version(c)
        pend = c.execute("SELECT COUNT(*) n FROM updates WHERE base_version=? AND status='pending'", (cur,)).fetchone()["n"]
        nclients = c.execute("SELECT COUNT(*) n FROM clients").fetchone()["n"]
        ev = c.execute("SELECT kind, COUNT(*) n FROM events GROUP BY kind").fetchall()
    print(f"текущая версия: v{cur}; ожидают агрегации: {pend}; установок известно: {nclients}")
    for r in ev:
        print(f"  событий {r['kind']}: {r['n']}")
    return 0


def cmd_versions(a) -> int:
    store = Store(Path(a.data_dir))
    with store.db() as c:
        cur = store.current_version(c)
        print("версия  статус   клиентов  откат_к  размер     sha256        создана")
        for r in c.execute("SELECT * FROM versions ORDER BY version"):
            t = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(r["created_at"]))
            print(f"v{r['version']:<5} {r['status']:<8} {str(r['round_clients'] or '-'):>8}  {str(r['rollback_of'] or '-'):>7}  "
                  f"{r['size_bytes']:>9}  {r['sha256'][:12]}  {t}{'  <- текущая' if r['version'] == cur else ''}")
    return 0


def cmd_rounds(a) -> int:
    store = Store(Path(a.data_dir))
    with store.db() as c:
        rows = c.execute("SELECT * FROM rounds ORDER BY round_version").fetchall()
    if not rows:
        print("раундов нет")
    for r in rows:
        st = json.loads(r["stats_json"])
        clipped = sum(1 for s in st["clip_scales"] if s < 1.0)
        top = max(range(st["n"]), key=lambda i: st["trimmed_frac"][i]) if st["n"] else 0
        print(f"раунд -> v{r['round_version']} (база v{r['base_version']}) клиентов {r['n_received']} метод {r['method']} "
              f"C={r['clip_norm']:.4f} заклиплено {clipped}; max доля отброшенных координат {100 * st['trimmed_frac'][top]:.1f}% "
              f"у {st['clients'][top]} [{r['status']}]")
    return 0


def cmd_keys(a) -> int:
    print(public_b64(Store(Path(a.data_dir)).signing_key()))
    return 0


def cmd_rollback(a) -> int:
    store = Store(Path(a.data_dir))
    with store.db() as c:
        c.execute("BEGIN IMMEDIATE")
        try:
            cur = store.current_version(c)
            r = c.execute("SELECT status, sha256 FROM versions WHERE version=?", (a.to,)).fetchone()
            if r is None or r["status"] != "active":
                print(f"версии v{a.to} нет или она отозвана", file=sys.stderr)
                c.execute("ROLLBACK")
                return 1
            if a.to == cur:
                print("это уже текущая версия", file=sys.stderr)
                c.execute("ROLLBACK")
                return 1
            data = store.version_path(a.to).read_bytes()
            if hashlib.sha256(data).hexdigest() != r["sha256"]:
                print("файл версии повреждён (sha256 не сходится)", file=sys.stderr)
                c.execute("ROLLBACK")
                return 1
            c.execute("UPDATE versions SET status='revoked' WHERE version>? AND status='active'", (a.to,))
            c.execute("UPDATE rounds SET status='rolled_back' WHERE round_version>?", (a.to,))
            discarded = c.execute("UPDATE updates SET status='discarded' WHERE status='pending' AND base_version>?", (a.to,)).rowcount
            newv = _publish(store, c, data, rollback_of=a.to)
            store.event(c, None, "rollback", f"to={a.to} from={cur} new={newv} reason={a.reason}")
            c.execute("COMMIT")
        except BaseException:
            if c.in_transaction:
                c.execute("ROLLBACK")
            raise
    print(f"откат: опубликована v{newv} с содержимым v{a.to}; отозваны версии > v{a.to}; отброшено ожидающих обновлений: {discarded}")
    return 0


def cmd_ban(a, flag: int) -> int:
    store = Store(Path(a.data_dir))
    with store.db() as c:
        n = c.execute("UPDATE clients SET banned=? WHERE client_id=?", (flag, a.client_id)).rowcount
        store.event(c, a.client_id, "ban" if flag else "unban")
    print("готово" if n else "такой установки нет")
    return 0 if n else 1


def cmd_prune(a) -> int:
    """Хранение: служебные записи об уже агрегированных/отброшенных обновлениях, события и журнал лимитов старше N дней."""
    store = Store(Path(a.data_dir))
    cutoff = int(time.time()) - int(a.older_than_days * 86400)
    with store.db() as c:
        u = c.execute("DELETE FROM updates WHERE status != 'pending' AND received_at < ?", (cutoff,)).rowcount
        e = c.execute("DELETE FROM events WHERE ts < ?", (cutoff,)).rowcount
        c.execute("DELETE FROM request_log WHERE ts < ?", (cutoff,))
        k = c.execute("DELETE FROM clients WHERE banned=0 AND first_seen < ? AND client_id NOT IN (SELECT client_id FROM updates)",
                      (cutoff,)).rowcount
    print(f"удалено: обновлений {u}, событий {e}, установок {k} (старше {a.older_than_days:g} дн.)")
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("init", "status", "versions", "rounds", "keys", "rollback", "ban", "unban", "prune"):
        sp = sub.add_parser(name)
        sp.add_argument("--data-dir", required=True)
        if name == "init":
            sp.add_argument("--spec", required=True)
            sp.add_argument("--seed", type=int, default=0)
            sp.add_argument("--from-adapter")
        if name == "rollback":
            sp.add_argument("--to", type=int, required=True)
            sp.add_argument("--reason", default="")
        if name == "prune":
            sp.add_argument("--older-than-days", type=float, default=180.0)
        if name in ("ban", "unban"):
            sp.add_argument("client_id")
    a = ap.parse_args(argv)
    if a.cmd == "ban":
        return cmd_ban(a, 1)
    if a.cmd == "unban":
        return cmd_ban(a, 0)
    return globals()[f"cmd_{a.cmd}"](a)


if __name__ == "__main__":
    sys.exit(main())
