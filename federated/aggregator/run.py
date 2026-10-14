"""Раунд общего обучения (.github/workflows/federated-aggregate.yml раз в сутки), в двух заданиях без общих секретов:

  python -m aggregator.run fetch --to DIR          [токен только на чтение] копия входящих и текущей версии
  python -m aggregator.run score --out PLAN.json   [без секретов] экзамен и решения по копии (FL_INBOX/FL_MODELS=dir:)
  python -m aggregator.run publish --plan PLAN.json [ключ подписи и токен записи, без кода MultiVSR] публикация
  python -m aggregator.run rollback --to N --reason ..   новая версия с содержимым N
  python -m aggregator.run export --version N --out DIR   файл версии и подписанное описание (для релиза)
  python -m aggregator.run status

Окружение: FL_INBOX, FL_MODELS (hf:владелец/имя или dir:путь), HF_READ_TOKEN (fetch), HF_TOKEN и
FL_MODEL_SIGNING_KEY (publish, rollback), FL_EXAM_DIR и FL_LIPREAD_DIR (score).

Оценка (score): обновления на текущую версию; на старые базы, повторные и старше max_pending_days — в удаление.
Меньше min_clients — ждём. Каждое заново проверяется (только safetensors, подписи, спецификация, конечность, норма),
затем скрытый экзамен базы и базы + обновления: хуже — отклонено. Принятых меньше min_accepted — они ждут следующего
раунда (одно обновление никогда не публикуется). Принятые клиппируются и усредняются с обрезкой (вес — число
примеров, но не больше отрезков в задании); слияние, которое на экзамене хуже базы, не публикуется.

Публикация (publish) не верит оценке на слово: сверяет базу и её подпись, заново проверяет принятые обновления,
сама собирает слияние и публикует его, только если SHA-256 совпал с оценённым. Затем сверка опубликованного файла
(при расхождении — откат), вклад в contributors.json, отчёт в закрытый датасет, удаление обработанного и схлопывание
истории датасета.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import sys
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Callable

import numpy as np
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from aggregator.credits import Credit, update_file
from aggregator.exam import Scorer
from hub.inbox import ENTRY_RE, Entry, Inbox
from hub.registry import Registry, RegistryError
from protocol.adapter_io import apply_delta, dumps_adapter, loads_adapter, validate_against_spec
from protocol.contribution import verify_contribution
from protocol.errors import ProtocolError
from protocol.package import verify_update
from protocol.spec import AdapterSpec
from server.aggregate import _flatten, _unflatten, aggregate_vectors
from server.config import Aggregation, ServerConfig

DAY = 86400


@dataclass
class RoundConfig:
    min_clients: int = 5               # меньше свежих обновлений — раунд не начинается
    min_accepted: int = 5              # меньше принятых — не публикуем (усечённое среднее отбрасывает крайних)
    max_pending_days: float = 30.0     # обновление старше этого удаляется, так и не дождавшись раунда
    max_per_round: int = 10            # остальные ждут следующего раунда: одна оценка на CPU раннера ~13 мин (120 клипов)
    max_update_norm: float = 50.0
    max_wer_increase: float = 0.0      # обновление отклоняется, если WER(база+обновление) > WER(база) + это
    max_round_wer_increase: float = 0.0
    trim_ratio: float = 0.2
    clip_median_mult: float = 1.5
    server_lr: float = 1.0


@dataclass
class Decision:
    prefix: str
    login: str
    received_at: int
    status: str                         # accepted | waiting | rejected | stale | duplicate | expired
    reason: str = ""
    norm: float | None = None
    wer: float | None = None
    weight: int = 0
    data_seconds: float = 0.0
    training_steps: int = 0
    credit_public: bool = True


@dataclass
class RoundOutcome:
    status: str          # published | waiting | nothing_accepted | merge_worse | rolled_back | bootstrapped | no_base | dry_run
    base_version: int | None = None
    version: int | None = None
    base_wer: float | None = None
    new_wer: float | None = None
    decisions: list[Decision] = field(default_factory=list)
    credits: list[Credit] = field(default_factory=list)

    def summary(self) -> str:
        count = lambda *st: sum(d.status in st for d in self.decisions)  # noqa: E731
        lines = [f"Раунд: **{self.status}**; база v{self.base_version}" + (f", новая версия v{self.version}" if self.version else ""),
                 f"Обновлений: принято {count('accepted')}, ждут {count('waiting')}, отклонено {count('rejected')}, "
                 f"устаревших/повторных/просроченных {count('stale', 'duplicate', 'expired')}"]
        if self.base_wer is not None:
            lines.append(f"WER на скрытом экзамене: база {100 * self.base_wer:.2f}%"
                         + (f", после слияния {100 * self.new_wer:.2f}%" if self.new_wer is not None else ""))
        reasons: dict[str, int] = {}
        for d in self.decisions:
            if d.status == "rejected":
                key = d.reason.split(":")[0]
                reasons[key] = reasons.get(key, 0) + 1
        lines += [f"- отклонено ({r}): {n}" for r, n in sorted(reasons.items())]
        return "\n".join(lines)


@dataclass
class Context:
    inbox: Inbox
    registry: Registry
    spec: AdapterSpec
    scorer: Scorer | None = None
    signing_key: Ed25519PrivateKey | None = None
    cfg: RoundConfig = field(default_factory=RoundConfig)
    clock: Callable[[], float] = time.time
    rng: np.random.Generator = field(default_factory=lambda: np.random.default_rng(0))
    bootstrap_adapter: Callable[[], bytes] | None = None   # первая версия, когда реестр пуст


@dataclass
class Candidate:
    entry: Entry
    decision: Decision
    delta: dict
    weight: int


def entry_of(prefix: str) -> Entry:
    m = ENTRY_RE.match(prefix + "meta.json")
    if not m:
        raise ValueError(f"не запись входящих: {prefix}")
    return Entry(int(m.group(3)), m.group(1), int(m.group(2)), m.group(4))


def sha256(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def _load(ctx: Context, e: Entry, d: Decision) -> Candidate | None:
    """Повторная проверка всего, что проверил сервер приёма: в хранилище могли подменить что угодно."""
    try:
        meta = json.loads(ctx.inbox.read(e, "meta.json"))
        v = verify_update(ctx.inbox.read(e, "manifest.json"), ctx.inbox.read(e, "payload.safetensors"), ctx.spec)
        c = verify_contribution(ctx.inbox.read(e, "contribution.json"), v.manifest)
    except ProtocolError as err:
        d.status, d.reason = "rejected", f"формат: {err.code}"
        return None
    except (FileNotFoundError, ValueError, KeyError) as err:
        d.status, d.reason = "rejected", f"формат: {type(err).__name__}"
        return None
    task = meta.get("task") or {}
    segments = int(task.get("segments", 0))
    if meta.get("login", "").lower() != e.login.lower() or v.manifest.base_version != e.base_version \
            or v.manifest.payload_sha256[:16] != e.sha16 or segments <= 0:
        d.status, d.reason = "rejected", "формат: запись не совпадает с обновлением или заданием"
        return None
    d.norm = v.norm
    if v.norm > ctx.cfg.max_update_norm:
        d.status, d.reason = "rejected", f"норма: {v.norm:.3f} > {ctx.cfg.max_update_norm}"
        return None
    d.weight = min(v.manifest.num_examples, segments)
    d.data_seconds = min(c.data_seconds, float(task.get("seconds_max", 0.0)))
    d.training_steps = min(c.training_steps, int(task.get("steps_max", 0)))
    d.credit_public = c.credit_public
    return Candidate(e, d, {k: np.asarray(t, np.float32) for k, t in v.tensors.items()}, d.weight)


def merge(ctx: Context, base: dict, accepted: list[Candidate]) -> bytes:
    flats = [_flatten(c.delta, ctx.spec) for c in accepted]
    norms = [float(np.linalg.norm(f.astype(np.float64))) for f in flats]
    agg_cfg = ServerConfig(aggregation=Aggregation(method="trimmed_mean", trim_ratio=ctx.cfg.trim_ratio, min_clients=1,
                                                   clip_median_mult=ctx.cfg.clip_median_mult, server_lr=ctx.cfg.server_lr))
    agg, _stats = aggregate_vectors(flats, [c.weight for c in accepted], agg_cfg, norms, ctx.rng)
    new = apply_delta(base, _unflatten(agg, ctx.spec), ctx.cfg.server_lr)
    validate_against_spec(new, ctx.spec, delta=False, dtype=np.float32)
    return dumps_adapter(new, metadata={"spec_hash": ctx.spec.hash})


def score_round(ctx: Context) -> dict:
    """Решения раунда без публикации и без удаления. Результат — план для publish_plan (JSON)."""
    cfg, now = ctx.cfg, int(ctx.clock())
    idx = ctx.registry.index()
    cur = idx.current
    if cur is None:
        if ctx.bootstrap_adapter is None:
            return {"kind": "no_base"}
        data = ctx.bootstrap_adapter()
        t = loads_adapter(data)
        validate_against_spec(t, ctx.spec, delta=False, dtype=np.float32)
        s = ctx.scorer.score({"v1": t})["v1"]
        return {"kind": "bootstrap", "sha256": sha256(data), "wer": s.wer, "exam_n": s.n}

    decisions: list[Decision] = []
    entries = ctx.inbox.entries()
    for e in entries:
        if e.base_version != cur:
            decisions.append(Decision(e.prefix, e.login, e.received_at, "stale", f"база v{e.base_version}"))
    fresh = sorted((e for e in entries if e.base_version == cur), key=lambda e: e.received_at)
    seen, batch = set(), []
    for e in fresh:
        if now - e.received_at > cfg.max_pending_days * DAY:
            decisions.append(Decision(e.prefix, e.login, e.received_at, "expired", "не дождалось раунда"))
        elif e.login.lower() in seen:
            decisions.append(Decision(e.prefix, e.login, e.received_at, "duplicate", "второе обновление на ту же базу"))
        else:
            seen.add(e.login.lower())
            batch.append(e)
    batch = batch[:cfg.max_per_round]
    plan = {"kind": "wait", "base_version": cur, "base_sha256": None, "base_wer": None, "merged_sha256": None,
            "merged_wer": None, "exam_n": None, "decisions": decisions}
    if len(batch) < cfg.min_clients:
        return _plan_json(plan)

    base_bytes = ctx.registry.adapter_bytes(cur, idx)
    base = loads_adapter(base_bytes)
    plan["base_sha256"] = sha256(base_bytes)
    cands = []
    for e in batch:
        d = Decision(e.prefix, e.login, e.received_at, "pending")
        decisions.append(d)
        c = _load(ctx, e, d)
        if c is not None:
            cands.append(c)
    if not cands:
        return _plan_json(plan)
    scores = ctx.scorer.score({"base": base, **{f"u{i}": apply_delta(base, c.delta) for i, c in enumerate(cands)}})
    plan["base_wer"], plan["exam_n"] = scores["base"].wer, scores["base"].n
    accepted = []
    for i, c in enumerate(cands):
        c.decision.wer = scores[f"u{i}"].wer
        if c.decision.wer > plan["base_wer"] + cfg.max_wer_increase:
            c.decision.status = "rejected"
            c.decision.reason = f"экзамен: WER {100 * c.decision.wer:.2f}% > {100 * plan['base_wer']:.2f}%"
        else:
            c.decision.status = "accepted"
            accepted.append(c)
    if len(accepted) < cfg.min_accepted:
        for c in accepted:
            c.decision.status, c.decision.reason = "waiting", f"принятых {len(accepted)} < {cfg.min_accepted}"
        return _plan_json(plan)

    merged_bytes = merge(ctx, base, accepted)
    merged = ctx.scorer.score({"merged": loads_adapter(merged_bytes)})["merged"]
    plan["merged_sha256"], plan["merged_wer"] = sha256(merged_bytes), merged.wer
    if merged.wer > plan["base_wer"] + cfg.max_round_wer_increase:
        plan["kind"] = "merge_worse"
        for c in accepted:
            c.decision.status, c.decision.reason = "rejected", "экзамен после слияния хуже базы"
    else:
        plan["kind"] = "publish"
    return _plan_json(plan)


def _plan_json(plan: dict) -> dict:
    return {**plan, "decisions": [asdict(d) if isinstance(d, Decision) else d for d in plan.get("decisions", [])]}


class PlanMismatch(RuntimeError):
    pass


def publish_plan(ctx: Context, plan: dict) -> RoundOutcome:
    """Выполнить план оценки. Всё, от чего зависит публикуемый файл, проверяется здесь заново."""
    kind = plan.get("kind")
    if kind == "no_base":
        return RoundOutcome("no_base")
    idx = ctx.registry.index()
    if kind == "bootstrap":
        if idx.current is not None:
            return RoundOutcome("no_base", base_version=idx.current)
        data = ctx.bootstrap_adapter()
        if sha256(data) != plan["sha256"]:
            raise PlanMismatch("начальная версия не совпала с оценённой")
        v = ctx.registry.publish(data, ctx.signing_key, exam_wer=plan["wer"], exam_n=plan["exam_n"], note="начальная версия")
        return RoundOutcome("bootstrapped", version=v, new_wer=plan["wer"])

    cur = plan["base_version"]
    if idx.current != cur:
        raise PlanMismatch(f"версия сменилась: план для v{cur}, текущая v{idx.current}")
    decisions = [Decision(**d) for d in plan["decisions"]]
    out = RoundOutcome({"wait": "waiting", "merge_worse": "merge_worse", "publish": "published"}[kind], base_version=cur,
                       base_wer=plan.get("base_wer"), new_wer=plan.get("merged_wer"), decisions=decisions)
    drop = [entry_of(d.prefix) for d in decisions if d.status not in ("accepted", "waiting")]
    if kind == "wait" and any(d.status == "rejected" for d in decisions) and not any(d.status == "waiting" for d in decisions):
        out.status = "nothing_accepted"
    if kind != "publish":
        _finish(ctx, out, drop, f"v{cur:06d}-{int(ctx.clock())}-{kind}")
        return out

    base_bytes = ctx.registry.adapter_bytes(cur, idx)
    if sha256(base_bytes) != plan["base_sha256"]:
        raise PlanMismatch("база не совпала с оценённой")
    accepted = []
    for d in decisions:
        if d.status == "accepted":
            check = Decision(d.prefix, d.login, d.received_at, "pending")
            c = _load(ctx, entry_of(d.prefix), check)
            if c is None:
                raise PlanMismatch(f"принятое обновление {d.prefix} не прошло повторную проверку: {check.reason}")
            d.weight, d.data_seconds, d.training_steps, d.credit_public = (check.weight, check.data_seconds,
                                                                            check.training_steps, check.credit_public)
            accepted.append(c)
    if len(accepted) < ctx.cfg.min_accepted:
        raise PlanMismatch(f"в плане принято {len(accepted)} < {ctx.cfg.min_accepted}")
    data = merge(ctx, loads_adapter(base_bytes), accepted)
    if sha256(data) != plan["merged_sha256"]:
        raise PlanMismatch("слияние не совпало с оценённым")
    ver = ctx.registry.publish(data, ctx.signing_key, round_clients=len(accepted), exam_wer=plan["merged_wer"],
                               exam_n=plan["exam_n"], note=f"раунд: принято {len(accepted)}")
    out.version = ver
    drop += [c.entry for c in accepted]
    try:
        ok = ctx.registry.adapter_bytes(ver) == data
    except RegistryError:
        ok = False
    if not ok:
        ctx.registry.rollback(cur, ctx.signing_key, "опубликованный файл не совпал с проверенным")
        out.status = "rolled_back"
        for d in decisions:
            if d.status == "accepted":
                d.status, d.reason = "rejected", "публикация не удалась"
        _finish(ctx, out, drop, f"v{ver:06d}-rolled-back")
        return out
    out.credits = [Credit(d.login, d.data_seconds, d.training_steps) for d in decisions
                   if d.status == "accepted" and d.credit_public]
    _finish(ctx, out, drop, f"v{ver:06d}")
    return out


def run_round(ctx: Context, *, dry_run: bool = False) -> RoundOutcome:
    """Оценка и публикация подряд в одном процессе (тесты, локальный запуск)."""
    plan = score_round(ctx)
    if dry_run:
        decisions = [Decision(**d) for d in plan.get("decisions", [])]
        return RoundOutcome("dry_run", base_version=plan.get("base_version"), base_wer=plan.get("base_wer"),
                            new_wer=plan.get("merged_wer"), decisions=decisions)
    return publish_plan(ctx, plan)


def _finish(ctx: Context, out: RoundOutcome, drop: list[Entry], name: str) -> None:
    if not drop and out.status == "waiting":
        return
    report = {"status": out.status, "base_version": out.base_version, "version": out.version, "base_wer": out.base_wer,
              "new_wer": out.new_wer, "decisions": [asdict(d) for d in out.decisions], "at": int(ctx.clock())}
    ctx.inbox.write_report(f"{name}.json", json.dumps(report, ensure_ascii=False, indent=1).encode(), drop)


def load_signing_key(b64: str) -> Ed25519PrivateKey:
    raw = base64.b64decode(b64.strip(), validate=True)
    if len(raw) != 32:
        raise SystemExit("FL_MODEL_SIGNING_KEY: нужно 32 байта в base64")
    return Ed25519PrivateKey.from_private_bytes(raw)


def public_b64(key: Ed25519PrivateKey) -> str:
    return base64.b64encode(key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)).decode()


def _spec() -> AdapterSpec:
    from protocol.spec import load_spec
    return load_spec(Path(__file__).resolve().parent.parent / "protocol" / "specs" / "multivsr_lora_r16.json")


def _context(*, token_env: str | None, exam: bool = False, signing: bool = False) -> Context:
    from client import community_defaults
    from hub.storage import open_store

    spec = _spec()
    token = os.environ.get(token_env) if token_env else None
    pub = community_defaults.MODEL_SIGNING_PUBLIC_KEY or None
    key = load_signing_key(os.environ["FL_MODEL_SIGNING_KEY"]) if signing else None
    if key is not None and pub and public_b64(key) != pub:
        raise SystemExit("FL_MODEL_SIGNING_KEY не соответствует открытому ключу в client/community_defaults.py")
    scorer = None
    if exam:
        from aggregator.exam import LipreadScorer
        scorer = LipreadScorer(Path(os.environ["FL_EXAM_DIR"]), Path(os.environ.get("FL_LIPREAD_DIR", "../lipread")), spec,
                               limit=int(os.environ.get("FL_EXAM_LIMIT") or 0), beam=int(os.environ.get("FL_EXAM_BEAM") or 4))
    cfg = RoundConfig()
    for f in cfg.__dataclass_fields__:
        env = os.environ.get("FL_ROUND_" + f.upper())
        if env:
            setattr(cfg, f, type(getattr(cfg, f))(env))

    def bootstrap():
        from aggregator.release import lips01_adapter
        return lips01_adapter(spec)

    return Context(inbox=Inbox(open_store(os.environ["FL_INBOX"], token, "dataset")),
                   registry=Registry(open_store(os.environ["FL_MODELS"], token, "model"), spec, public_key=pub), spec=spec,
                   scorer=scorer, signing_key=key, cfg=cfg, bootstrap_adapter=bootstrap)


def fetch(ctx: Context, to: Path) -> None:
    """Копия на диск того, что нужно для оценки: входящие (pending/) и реестр с текущей версией."""
    from hub.registry import INDEX, version_path
    from hub.storage import LocalBlobStore
    inbox, models = LocalBlobStore(to / "inbox"), LocalBlobStore(to / "models")
    inbox.commit({p: ctx.inbox.store.read(p) for p in ctx.inbox.store.list("pending/")})
    raw = ctx.registry.store.read(INDEX)
    if raw is not None:
        cur = ctx.registry.index().current
        models.commit({INDEX: raw, **({version_path(cur): ctx.registry.store.read(version_path(cur))} if cur else {})})


def _summary(text: str) -> None:
    print(text)
    p = os.environ.get("GITHUB_STEP_SUMMARY")
    if p:
        with open(p, "a", encoding="utf8") as f:
            f.write(text + "\n")


def _output(**kw) -> None:
    p = os.environ.get("GITHUB_OUTPUT")
    if p:
        with open(p, "a") as f:
            for k, v in kw.items():
                f.write(f"{k}={v}\n")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("fetch").add_argument("--to", required=True)
    sub.add_parser("score").add_argument("--out", required=True)
    p = sub.add_parser("publish")
    p.add_argument("--plan", required=True)
    p.add_argument("--contributors", default="../contributors.json")
    rb = sub.add_parser("rollback")
    rb.add_argument("--to", type=int, required=True)
    rb.add_argument("--reason", default="вручную")
    ex = sub.add_parser("export")
    ex.add_argument("--version", type=int, required=True)
    ex.add_argument("--out", required=True)
    sub.add_parser("status")
    a = ap.parse_args(argv)

    if a.cmd == "fetch":
        fetch(_context(token_env="HF_READ_TOKEN"), Path(a.to))
        return 0
    if a.cmd == "score":
        plan = score_round(_context(token_env=None, exam=True))
        Path(a.out).write_text(json.dumps(plan, ensure_ascii=False, indent=1))
        _summary(f"Оценка: {plan['kind']}" + (f", база v{plan.get('base_version')}" if plan.get("base_version") else ""))
        _output(kind=plan["kind"])
        return 0
    if a.cmd == "publish":
        ctx = _context(token_env="HF_TOKEN", signing=True)
        out = publish_plan(ctx, json.loads(Path(a.plan).read_text()))
        _summary(out.summary() if out.status != "bootstrapped" else
                 f"Опубликована начальная версия v{out.version}, WER на скрытом экзамене {100 * out.new_wer:.2f}%")
        if out.version and out.status in ("published", "bootstrapped"):
            _output(version=out.version)
        if out.status == "published" and update_file(Path(a.contributors), out.credits):
            print(f"contributors.json: засчитано {len(out.credits)}")
        return 0
    if a.cmd == "rollback":
        ctx = _context(token_env="HF_TOKEN", signing=True)
        v = ctx.registry.rollback(a.to, ctx.signing_key, a.reason)
        _summary(f"Откат: опубликована v{v} с содержимым v{a.to} ({a.reason})")
        return 0
    ctx = _context(token_env=None)
    if a.cmd == "export":
        idx = ctx.registry.index()
        out_dir = Path(a.out)
        out_dir.mkdir(parents=True, exist_ok=True)
        (out_dir / f"lips-adapter-v{a.version}.safetensors").write_bytes(ctx.registry.adapter_bytes(a.version, idx))
        (out_dir / f"lips-adapter-v{a.version}.json").write_text(idx.record(a.version).model_dump_json(indent=1))
        return 0
    for h in ctx.registry.history():
        print(json.dumps(h, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
