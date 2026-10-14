"""Общая обвязка тестов «Помочь обучить»: сервер Space на каталогах вместо Hugging Face, поддельный GitHub,
поддельный конвейер клиента (без yt-dlp, ffmpeg и torch) и экзамен-функция вместо настоящей модели."""
from __future__ import annotations

import hashlib
import json
from dataclasses import replace
from pathlib import Path

import httpx
import numpy as np
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from starlette.testclient import TestClient

from aggregator.exam import FunctionScorer
from aggregator.run import Context, RoundConfig
from client import consent
from client.community import ClipItem, Controls, Job, TrainOutcome
from client.config import ClientConfig, CommunityCfg, GuardCfg, ServerCfg
from client.github_login import save_token
from client.transport import Transport
from hub.github_auth import GithubVerifier
from hub.inbox import Inbox
from hub.registry import Registry
from hub.storage import LocalBlobStore
from hub.tasks import Exclusions, PoolVideo, Segment
from protocol.adapter_io import dumps_adapter, load_adapter, save_adapter
from protocol.modelsig import public_b64
from protocol.spec import AdapterSpec, init_adapter
from space.app import create_app
from tests.helpers import tiny_spec

SECRET = b"t" * 32
MARKER = b"VIDEO-BYTES-MUST-NOT-LEAVE"
NOW = 1_800_000_000.0
OLD = "2015-01-01T00:00:00Z"


def target_adapter(spec: AdapterSpec) -> dict:
    """«Идеальный» адаптер: экзамен-функция считает WER как расстояние до него."""
    rng = np.random.default_rng(42)
    return {t.name: rng.standard_normal(t.shape).astype(np.float32) * 0.5 for t in spec.tensors}


def exam_fn(spec: AdapterSpec):
    tgt = target_adapter(spec)

    def wer(t):
        d = sum(float(((np.asarray(t[k], np.float64) - tgt[k]) ** 2).sum()) for k in tgt)
        return float(np.sqrt(d) / 10.0)
    return wer


def github_http(users: dict[str, dict]) -> httpx.Client:
    """api.github.com/user: токен -> профиль (users[token])."""
    def handler(req: httpx.Request):
        tok = req.headers.get("authorization", "").split(" ", 1)[-1]
        if tok not in users:
            return httpx.Response(401, json={"message": "Bad credentials"})
        return httpx.Response(200, json=users[tok])
    return httpx.Client(transport=httpx.MockTransport(handler))


def user(login: str, uid: int, created: str = OLD) -> dict:
    return {"login": login, "id": uid, "created_at": created, "type": "User"}


def pool(n: int = 6, segs: int = 30, channel: str = "UCchan") -> list[PoolVideo]:
    out = []
    for i in range(n):
        vid = f"vid{i:08d}"[:11].ljust(11, "x")
        out.append(PoolVideo(vid, f"{channel}{i % 2}", tuple(Segment(2.0 * k, 2.0 * k + 1.5, f"фраза {i} {k}")
                                                            for k in range(segs))))
    return out


class Hub:
    """Сервер Space + реестр + входящие на каталогах; ключ подписи модели; часы."""

    def __init__(self, root: Path, *, users: dict[str, dict] | None = None, **app_kw):
        self.spec = tiny_spec()
        self.key = Ed25519PrivateKey.generate()
        self.inbox = Inbox(LocalBlobStore(root / "inbox"))
        self.registry = Registry(LocalBlobStore(root / "models"), self.spec, public_key=public_b64(self.key))
        self.clock = [NOW]
        self.users = users or {"tok-alice": user("alice", 1), "tok-bob": user("bob", 2), "tok-carol": user("carol", 3),
                               "tok-dave": user("dave", 4), "tok-eve": user("eve", 5)}
        self.verifier = GithubVerifier(github_http(self.users), clock=lambda: self.clock[0])
        self.venc = b"fake-venc"
        self.assets = {"venc": {"url": "https://example.invalid/venc.pth", "sha256": hashlib.sha256(self.venc).hexdigest()}}
        kw = dict(pool_loader=lambda: pool(n=40), exclusions_loader=Exclusions, videos_per_task=3, training={"steps": 50, "min_clips": 5,
                  "dev_fraction": 0.2}, assets=self.assets, max_updates_per_day=2, max_tasks_per_day=5, ip_per_minute=10_000)
        kw.update(app_kw)
        self.app = create_app(spec=self.spec, inbox=self.inbox, registry=self.registry, verifier=self.verifier,
                              task_secret=SECRET, clock=lambda: self.clock[0], **kw)
        self.http = TestClient(self.app)

    def bootstrap(self, seed: int = 0) -> int:
        t = init_adapter(self.spec, seed)
        return self.registry.publish(dumps_adapter(t), self.key, exam_wer=exam_fn(self.spec)(t), exam_n=100)

    def refresh(self) -> None:
        self.app.state.index_cache.invalidate()

    def context(self, **cfg) -> Context:
        return Context(inbox=self.inbox, registry=self.registry, spec=self.spec, scorer=FunctionScorer(exam_fn(self.spec)),
                       signing_key=self.key, cfg=RoundConfig(**{"min_clients": 2, "min_accepted": 2, **cfg}),
                       clock=lambda: self.clock[0])


class FakePipeline:
    """Без сети и моделей. Ролик и отрезки — файлы с маркером; обучение двигает адаптер к цели (или портит его)."""

    def __init__(self, spec: AdapterSpec, *, toward: float = 0.5, poison: float | None = None, seed: int = 0,
                 cancel_at: str | None = None, controls: Controls | None = None, channels: dict | None = None):
        self.spec, self.toward, self.poison, self.seed = spec, toward, poison, seed
        self.cancel_at, self.controls = cancel_at, controls
        self.downloaded: list[Path] = []
        self.channels = channels or {}

    def _maybe_cancel(self, stage: str, controls: Controls):
        if self.cancel_at == stage:
            controls.cancelled = True
        controls.check()

    def download(self, video_id, out_dir, controls):
        out_dir.mkdir(parents=True, exist_ok=True)
        p = out_dir / f"{video_id}.mp4"
        p.write_bytes(MARKER + video_id.encode() + bytes(256))
        if video_id in self.channels:
            p.with_suffix(".channel").write_text(self.channels[video_id] + "\n")
        self.downloaded.append(p)
        self._maybe_cancel("download", controls)
        return p

    def cut(self, video, segments, out_dir, prefix, controls):
        out_dir.mkdir(parents=True, exist_ok=True)
        res = []
        for k, _s in enumerate(segments):
            p = out_dir / f"{prefix}_{k:03d}.mp4"
            p.write_bytes(MARKER + f"{prefix}{k}".encode() + video.read_bytes()[:32])
            res.append((k, p))
        return res

    def prepare(self, clips: list[ClipItem], venc, work, controls):
        (work / "features").mkdir(parents=True, exist_ok=True)
        (work / "faces").mkdir(parents=True, exist_ok=True)
        out = {}
        for c in clips:
            f = work / "features" / f"{c.hash}.npy"
            np.save(f, np.zeros((40, 4), np.float16))
            out[c.id] = {"feats": str(f), "frames": 40, "face": str(work / "faces" / "x.avi"), "skip": None}
        self._maybe_cancel("prepare", controls)
        return out

    def train(self, manifest, base_adapter, out, training, work, controls) -> TrainOutcome:
        self._maybe_cancel("train", controls)
        base = load_adapter(base_adapter)
        tgt = target_adapter(self.spec)
        rng = np.random.default_rng(self.seed)
        new = {}
        for k, v in base.items():
            if self.poison is not None:
                new[k] = v + self.poison * rng.standard_normal(v.shape).astype(np.float32)
            else:
                new[k] = v + self.toward * (tgt[k] - v) + 0.01 * rng.standard_normal(v.shape).astype(np.float32)
        save_adapter(new, out)
        return TrainOutcome(Path(out), int(training["steps"]))


def models_http(root: Path) -> httpx.Client:
    """The public model repo as a static file host: <root>/models/<path>."""
    def handler(req: httpx.Request):
        p = root / "models" / req.url.path.removeprefix("/repo/")
        return httpx.Response(200, content=p.read_bytes()) if p.is_file() else httpx.Response(404)
    return httpx.Client(transport=httpx.MockTransport(handler))


def client_job(hub: Hub, home: Path, token: str, pipeline: FakePipeline, *, auto_send: bool = False,
               capture: list | None = None, consent_on: bool = True, models_from: Path | None = None) -> Job:
    cfg = ClientConfig(home=home, guard=GuardCfg(enabled=False),
                       community=CommunityCfg(server_url="http://127.0.0.1:1", signing_public_key=public_b64(hub.key),
                                              auto_send=auto_send,
                                              models_url="https://models.invalid/repo" if models_from else "server"))
    cfg.training.lipread_ru_dir = str(home / "lipread")
    if consent_on:
        consent.record(home, True, kind=consent.HELP_TRAIN)
    save_token(home, token)
    cache = home / "community" / "cache"
    cache.mkdir(parents=True, exist_ok=True)
    (cache / f"venc-{hub.assets['venc']['sha256'][:16]}.pth").write_bytes(hub.venc)
    http = hub.http
    if capture is not None:
        def hook(req: httpx.Request):
            capture.append((req.method, req.url.path, req.read()))
        http = TestClient(hub.app)
        http.event_hooks = {"request": [hook], "response": []}
    scfg = replace(ServerCfg(), url="http://127.0.0.1:1", allow_insecure_localhost=True,
                   signing_public_key=public_b64(hub.key), retry_attempts=1)
    job = Job(cfg, pipeline=pipeline, transport=Transport(scfg, client=http, sleep=lambda s: None),
              spec=hub.spec, clock=lambda: hub.clock[0])
    job.venc_allowed = frozenset({hub.assets["venc"]["sha256"]})
    job.exclusions_loader = lambda: set()
    if models_from:
        job.models_http = models_http(models_from)
    return job


def read_preview(home: Path) -> dict:
    return json.loads((home / "community" / "outbox" / "preview.json").read_text())
