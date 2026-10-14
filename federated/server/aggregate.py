"""Задание агрегации: python -m server.aggregate --data-dir DIR [--force] [--dry-run].

Берёт все ожидающие обновления на текущую версию, клиппит по L2-норме, усечённо-усредняет по координатам с весами
min(num_examples, max_weight_examples), опционально добавляет гауссов шум (DP), пишет новую версию адаптера и запись
о раунде (нормы, множители клиппинга, доля координат, где клиент оказался «крайним»). Код возврата:
0 версия опубликована (или dry-run), 3 мало клиентов, 4 исчерпан DP-бюджет.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
import time
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from protocol.adapter_io import dumps_adapter, load_adapter, loads_adapter
from protocol.modelsig import sign_model_info
from protocol.schema import ModelInfo
from protocol.spec import AdapterSpec
from server import dp as dpmod
from server import robust
from server.config import ServerConfig, load_config
from server.store import Store

CHUNK = 262_144


@dataclass
class RoundResult:
    published: bool
    reason: str
    version: int | None = None
    stats: dict | None = None


def _flatten(t: dict, spec: AdapterSpec) -> np.ndarray:
    return np.concatenate([t[s.name].astype(np.float32).ravel() for s in spec.delta_tensors])


def _unflatten(vec: np.ndarray, spec: AdapterSpec) -> dict:
    out, o = {}, 0
    for s in spec.delta_tensors:
        out[s.name] = vec[o:o + s.numel].reshape(s.shape).astype(np.float32)
        o += s.numel
    return out


def aggregate_vectors(flats: list[np.ndarray], examples: list[int], cfg: ServerConfig, norms: list[float],
                      rng: np.random.Generator) -> tuple[np.ndarray, dict]:
    """Чистая математика раунда (без БД): клиппинг -> агрегат -> шум. Возвращает (дельта, статистика)."""
    a = cfg.aggregation
    n = len(flats)
    norms_a = np.asarray(norms, np.float64)
    c = a.clip_norm if a.clip_norm > 0 else a.clip_median_mult * float(np.median(norms_a))
    scales = np.array([robust.clip_scale(x, c) for x in norms_a])
    w = np.minimum(np.asarray(examples, np.float64), a.max_weight_examples)
    k = robust.trim_count(n, a.trim_ratio) if a.method == "trimmed_mean" else 0
    d = flats[0].size
    agg = np.empty(d, np.float64)
    trimmed = np.zeros(n, np.int64)
    for lo in range(0, d, CHUNK):
        hi = min(d, lo + CHUNK)
        X = np.stack([f[lo:hi] * s for f, s in zip(flats, scales)]).astype(np.float32)
        if a.method == "median":
            agg[lo:hi] = robust.weighted_median(X, w)
        elif a.method == "trimmed_mean":
            agg[lo:hi], tr = robust.weighted_trimmed_mean(X, w, k, with_trimmed_mask=True)
            trimmed += tr
        else:
            agg[lo:hi] = robust.weighted_mean(X, w)
    stats = {"n": n, "clip_norm": c, "clip_mode": "fixed" if a.clip_norm > 0 else "adaptive_median",
             "method": a.method, "trim_k": k, "weights": w.tolist(), "norms": norms_a.tolist(),
             "clip_scales": scales.tolist(),
             "trimmed_frac": (trimmed / d).tolist() if a.method == "trimmed_mean" else [0.0] * n}
    # trimmed_frac: доля координат, где клиент оказался среди k наименьших или k наибольших и был отброшен
    if cfg.dp.enabled:
        sigma = dpmod.gaussian_sigma(cfg.dp.noise_multiplier, c, w)
        agg = dpmod.add_noise(agg, sigma, rng)
        stats["dp_sigma"] = sigma
    return agg.astype(np.float32), stats


def run_round(store: Store, cfg: ServerConfig, *, force: bool = False, dry_run: bool = False,
              rng: np.random.Generator | None = None, now: int | None = None) -> RoundResult:
    spec = store.spec
    rng = rng or np.random.default_rng()
    now = int(time.time()) if now is None else now
    with store.db() as c:
        cur = store.current_version(c)
        rows = c.execute("SELECT * FROM updates WHERE base_version=? AND status='pending' ORDER BY received_at",
                         (cur,)).fetchall()
        s_sum = float(store.get_meta(c, "dp_s_sum", 0.0))
    n = len(rows)
    if n == 0 or (n < cfg.aggregation.min_clients and not force):
        return RoundResult(False, f"мало обновлений: {n} < min_clients={cfg.aggregation.min_clients}")

    flats = [_flatten(loads_adapter(Path(r["payload_path"]).read_bytes()), spec) for r in rows]
    # норма пересчитывается по самим данным (в БД лежит значение при приёме; сверка защищает от подмены файла)
    norms = [float(np.linalg.norm(f.astype(np.float64))) for f in flats]
    delta, stats = aggregate_vectors(flats, [r["num_examples"] for r in rows], cfg, norms, rng)
    stats["clients"] = [r["client_id"][:8] for r in rows]
    stats["dp_formal"] = cfg.dp.enabled and cfg.aggregation.method == "mean"

    if cfg.dp.enabled:
        s_sum += 1.0 / cfg.dp.noise_multiplier ** 2
        eps = dpmod.epsilon_from_rdp_sum(s_sum, cfg.dp.delta)
        stats.update(dp_epsilon=eps, dp_delta=cfg.dp.delta, dp_noise_multiplier=cfg.dp.noise_multiplier)
        if cfg.dp.max_epsilon > 0 and eps > cfg.dp.max_epsilon:
            return RoundResult(False, f"DP-бюджет исчерпан: eps={eps:.3f} > {cfg.dp.max_epsilon}", stats=stats)
    if dry_run:
        return RoundResult(False, "dry-run", stats=stats)

    base = load_adapter(store.version_path(cur))
    newt = {k: v.copy() for k, v in base.items()}
    for name, upd in _unflatten(delta, spec).items():
        newt[name] += cfg.aggregation.server_lr * upd
    data = dumps_adapter(newt, metadata={"spec_hash": spec.hash})

    with store.db() as c:
        c.execute("BEGIN IMMEDIATE")
        try:
            if store.current_version(c) != cur:
                raise RuntimeError("версия изменилась во время агрегации (параллельный откат?), раунд отменён")
            ver = (c.execute("SELECT MAX(version) m FROM versions").fetchone()["m"] or 0) + 1
            store.version_path(ver).write_bytes(data)
            info_part = dict(version=ver, spec_id=spec.spec_id, spec_hash=spec.hash, sha256=hashlib.sha256(data).hexdigest(),
                             size_bytes=len(data), created_at=now, round_clients=n, rollback_of=None,
                             download_path=f"/v1/model/{ver}/adapter")
            sig = sign_model_info(info_part, store.signing_key())
            info = ModelInfo(**info_part, signature=sig)
            c.execute("INSERT INTO versions (version, sha256, size_bytes, created_at, spec_hash, round_clients, info_json) "
                      "VALUES (?,?,?,?,?,?,?)", (ver, info.sha256, len(data), now, spec.hash, n, info.model_dump_json()))
            c.execute("INSERT INTO rounds (round_version, base_version, created_at, n_received, method, clip_norm, stats_json)"
                      " VALUES (?,?,?,?,?,?,?)", (ver, cur, now, n, cfg.aggregation.method, stats["clip_norm"], json.dumps(stats)))
            c.execute("UPDATE updates SET status='aggregated', round_version=? WHERE base_version=? AND status='pending'",
                      (ver, cur))
            if cfg.dp.enabled:
                store.set_meta(c, "dp_s_sum", s_sum)
            store.set_meta(c, "current_version", ver)
            c.execute("COMMIT")
        except BaseException:
            if c.in_transaction:
                c.execute("ROLLBACK")
            raise
    # хранение: дельты удаляются по сроку retain_payload_days (0 = сразу)
    cutoff = now - int(cfg.aggregation.retain_payload_days * 86400)
    with store.db() as c:
        for r in c.execute("SELECT update_id, payload_path FROM updates WHERE status='aggregated' AND payload_path IS NOT NULL "
                           "AND received_at <= ?", (cutoff,)).fetchall():
            Path(r["payload_path"]).unlink(missing_ok=True)
            c.execute("UPDATE updates SET payload_path=NULL WHERE update_id=?", (r["update_id"],))
    return RoundResult(True, "ok", ver, stats)


def format_stats(stats: dict) -> str:
    lines = [f"  метод={stats['method']} n={stats['n']} C={stats['clip_norm']:.4f} ({stats['clip_mode']}) trim_k={stats['trim_k']}"]
    for cid, nr, sc, tf, w in zip(stats["clients"], stats["norms"], stats["clip_scales"], stats["trimmed_frac"], stats["weights"]):
        flag = " CLIPPED" if sc < 1.0 else ""
        lines.append(f"  {cid}  норма={nr:9.4f}  множитель={sc:6.3f}  отброшен в {100 * tf:5.1f}% координат  вес={w:.0f}{flag}")
    if "dp_epsilon" in stats:
        lines.append(f"  DP: sigma={stats['dp_sigma']:.3e} eps(накоплено)={stats['dp_epsilon']:.3f} delta={stats['dp_delta']}"
                     f"{'' if stats['dp_formal'] else ' (номинально: гарантия формальна только для method=mean)'}")
    return "\n".join(lines)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--data-dir", required=True)
    ap.add_argument("--force", action="store_true", help="игнорировать min_clients")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args(argv)
    store = Store(Path(a.data_dir))
    cfg = load_config(store.dir)
    res = run_round(store, cfg, force=a.force, dry_run=a.dry_run)
    if res.stats:
        print(format_stats(res.stats))
    if res.published:
        print(f"опубликована версия v{res.version}")
        return 0
    print(res.reason)
    if res.reason.startswith("DP-бюджет"):
        return 4
    return 0 if res.reason == "dry-run" else 3


if __name__ == "__main__":
    sys.exit(main())
