"""Задания для участников: какие ролики скачать, какие отрезки вырезать, с какими настройками обучать.

Пул роликов живёт только на сервере (закрытый датасет или файл, путь в переменных окружения) и в git не попадает.
Строка пула (JSONL):

    {"video_id": "<11 символов YouTube>", "channel_id": "<канал>",
     "segments": [{"start": 12.3, "end": 17.9, "text": "расшифровка отрезка"}, ...]}

Исключения (data-governance/): ролики и каналы, авторы которых попросили их не использовать, в задания не попадают.

Задание подписывается HMAC-ключом сервера. Токен возвращается вместе с обновлением, и сервер без хранения
состояния проверяет, что задание выдано этому логину, на эту версию адаптера, ещё не просрочено, и знает, сколько
секунд видео и шагов обучения в нём было: больше этого в таблицу вклада не засчитывается.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import random
import re
import threading
import time
import uuid
from dataclasses import dataclass, field
from typing import Callable, Iterable

from protocol.canonical import canonical_json
from protocol.errors import ProtocolError

VIDEO_ID_RE = re.compile(r"^[A-Za-z0-9_-]{11}$")
MIN_SEGMENT_SECONDS, MAX_SEGMENT_SECONDS = 0.5, 15.0

DEFAULT_TRAINING = {
    "steps": 200,             # шагов оптимизатора (эффективный батч = batch * accum)
    "lr": 1e-4,
    "batch": 4,
    "accum": 4,
    "warmup": 20,
    "max_seconds": 8.0,       # отрезки длиннее в обучение не идут (как train.py --max-seconds)
    "dev_fraction": 0.1,      # доля отрезков на ранний останов, не на обучение
    "min_clips": 20,          # меньше отрезков с лицом: обновление не отправляется
}


@dataclass(frozen=True)
class Segment:
    start: float
    end: float
    text: str


@dataclass(frozen=True)
class PoolVideo:
    video_id: str
    channel_id: str
    segments: tuple[Segment, ...]

    @property
    def seconds(self) -> float:
        return sum(s.end - s.start for s in self.segments)


def parse_pool(lines: Iterable[str]) -> list[PoolVideo]:
    """Строки с ошибками пропускаются: пул готовит владелец сервера, но лучше задание без ролика, чем без заданий."""
    out, seen = [], set()
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
            vid, ch = r["video_id"], str(r.get("channel_id") or "")
            if not VIDEO_ID_RE.match(vid) or vid in seen:
                continue
            segs = tuple(Segment(float(s["start"]), float(s["end"]), str(s["text"]).strip()) for s in r["segments"])
        except (ValueError, KeyError, TypeError):
            continue
        segs = tuple(s for s in segs if s.text and len(s.text) <= 500
                     and MIN_SEGMENT_SECONDS <= s.end - s.start <= MAX_SEGMENT_SECONDS and s.start >= 0)
        if segs:
            seen.add(vid)
            out.append(PoolVideo(vid, ch, segs))
    return out


@dataclass(frozen=True)
class Exclusions:
    videos: frozenset[str] = frozenset()
    channels: frozenset[str] = frozenset()

    def excludes(self, v: PoolVideo) -> bool:
        return v.video_id in self.videos or (bool(v.channel_id) and v.channel_id in self.channels)


CHANNEL_ID_RE = re.compile(r"^UC[A-Za-z0-9_-]{22}$")


def parse_exclusions(text: str) -> Exclusions:
    """Журнал data-governance/exclusions/channels.tsv («UC…<TAB>дата», # — комментарии). Терпимо и к другим
    формам: JSON (список или {"exclusions": [...]}), JSONL, строки «channel:ID» / «video:ID»; в записи учитываются
    ключи channel_id/channel и video_id/video."""
    items: list = []
    text = text.strip()
    if not text:
        return Exclusions()
    try:
        data = json.loads(text)
        items = data.get("exclusions", data.get("items", [])) if isinstance(data, dict) else data
    except ValueError:
        for line in text.splitlines():
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            first = line.split("\t")[0].split()[0]
            if CHANNEL_ID_RE.match(first):
                items.append({"channel_id": first})
            elif line.startswith("{"):
                try:
                    items.append(json.loads(line))
                except ValueError:
                    pass
            elif ":" in line:
                kind, _, val = line.partition(":")
                items.append({kind.strip().lower(): val.strip()})
    videos, channels = set(), set()
    for it in items if isinstance(items, list) else []:
        if not isinstance(it, dict):
            continue
        ch = it.get("channel_id") or it.get("channel")
        vid = it.get("video_id") or it.get("video")
        if isinstance(ch, str) and ch.strip():
            channels.add(ch.strip())
        if isinstance(vid, str) and vid.strip():
            videos.add(vid.strip())
    return Exclusions(frozenset(videos), frozenset(channels))


def _b64(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).decode("ascii").rstrip("=")


def _unb64(s: str) -> bytes:
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


@dataclass(frozen=True)
class TaskClaims:
    task_id: str
    login: str
    base_version: int
    seconds_max: float
    steps_max: int
    expires_at: int
    segments: int = 0     # отрезков в задании: потолок num_examples обновления и его веса в среднем


def sign_claims(c: TaskClaims, secret: bytes) -> str:
    body = canonical_json({"t": c.task_id, "l": c.login, "b": c.base_version, "s": c.seconds_max,
                           "k": c.steps_max, "e": c.expires_at, "n": c.segments})
    return _b64(body) + "." + _b64(hmac.new(secret, body, hashlib.sha256).digest())


def verify_token(token: str, secret: bytes, *, login: str, base_version: int, now: float | None = None) -> TaskClaims:
    try:
        body_b64, sig_b64 = token.split(".")
        body = _unb64(body_b64)
        ok = hmac.compare_digest(_unb64(sig_b64), hmac.new(secret, body, hashlib.sha256).digest())
        d = json.loads(body) if ok else None
        c = TaskClaims(str(d["t"]), str(d["l"]), int(d["b"]), float(d["s"]), int(d["k"]), int(d["e"]),
                       int(d.get("n", 0))) if ok else None
    except (ValueError, KeyError, TypeError):
        c = None
    if c is None:
        raise ProtocolError("bad_task", "токен задания не разобран или подпись не сходится")
    if c.login.lower() != login.lower():
        raise ProtocolError("bad_task", "задание выдано другому участнику")
    if c.base_version != base_version:
        raise ProtocolError("bad_task", "задание выдано на другую версию адаптера")
    if (time.time() if now is None else now) > c.expires_at:
        raise ProtocolError("bad_task", "срок задания истёк, возьмите новое")
    return c


@dataclass
class TaskIssuer:
    pool: list[PoolVideo]
    secret: bytes
    videos_per_task: int = 8
    segments_per_video: int = 20
    ttl_hours: float = 72.0
    training: dict = field(default_factory=lambda: dict(DEFAULT_TRAINING))
    assets: dict = field(default_factory=dict)
    exclusions: Callable[[], Exclusions] = Exclusions
    clock: Callable[[], float] = time.time
    rng: random.Random = field(default_factory=random.Random)

    def __post_init__(self):
        self.assigned: dict[str, int] = {}       # сколько раз ролик выдан (в памяти: при перезапуске начинается заново)
        self.given: dict[str, set[str]] = {}     # кому что уже выдано
        self.lock = threading.Lock()

    def issue(self, login: str, base_version: int) -> dict:
        excl = self.exclusions()
        with self.lock:
            seen = self.given.setdefault(login.lower(), set())
            cands = [v for v in self.pool if v.video_id not in seen and not excl.excludes(v)]
            if not cands:
                raise ProtocolError("unavailable", "новых роликов для вас сейчас нет, загляните позже")
            self.rng.shuffle(cands)
            cands.sort(key=lambda v: self.assigned.get(v.video_id, 0))
            chosen = cands[:self.videos_per_task]
            for v in chosen:
                self.assigned[v.video_id] = self.assigned.get(v.video_id, 0) + 1
                seen.add(v.video_id)
        videos = []
        for v in chosen:
            segs = list(v.segments)
            if len(segs) > self.segments_per_video:
                segs = sorted(self.rng.sample(segs, self.segments_per_video), key=lambda s: s.start)
            videos.append({"video_id": v.video_id,
                           "segments": [{"start": s.start, "end": s.end, "text": s.text} for s in segs]})
        now = int(self.clock())
        seconds = round(sum(s["end"] - s["start"] for v in videos for s in v["segments"]), 1)
        claims = TaskClaims(uuid.uuid4().hex, login, base_version, seconds, int(self.training["steps"]),
                            now + int(self.ttl_hours * 3600), sum(len(v["segments"]) for v in videos))
        return {"task_id": claims.task_id, "login": login, "base_version": base_version, "issued_at": now,
                "expires_at": claims.expires_at, "seconds_max": seconds, "videos": videos,
                "training": dict(self.training), "assets": dict(self.assets), "token": sign_claims(claims, self.secret)}
