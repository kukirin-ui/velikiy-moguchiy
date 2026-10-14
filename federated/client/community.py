"""«Помочь обучить»: участник обучает общую модель чтения по губам на публичных роликах у себя на компьютере.

  python -m client.community status               JSON для карточки приложения
  python -m client.community consent on|off       отдельное согласие (по умолчанию выключено)
  python -m client.community login | logout       вход через GitHub с устройства (печатает код JSON-строками)
  python -m client.community run                  выполнить задание (приложение запускает это в фоне)
  python -m client.community pause | resume | cancel
  python -m client.community preview              что именно будет отправлено
  python -m client.community send | discard       отправить готовое обновление или выбросить его

Задание (сервер, hub/tasks.py): несколько роликов YouTube и отрезки с расшифровкой. Шаги:
  1. согласие, вход, проверка, что рабочая папка не задевает личные папки (client/privacy.py);
  2. задание и общий адаптер (подпись проверяется закреплённым ключом), визуальная часть lips-0.1 по SHA-256;
  3. ролики качаются yt-dlp с адреса участника, только видео без звука; из каждого вырезаются отрезки задания,
     сам ролик сразу удаляется;
  4. кадры лица и признаки VTP (как «Обучить на мне»), обучение LoRA от общего адаптера; всё под охранником
     памяти, с паузой и отменой;
  5. дельта весов (safetensors fp16) + подписанные сведения о вкладе. Обновление ждёт, пока пользователь не
     посмотрит, что уходит, и не нажмёт «Отправить» (если не включено auto_send). Отрезки, кадры и признаки
     удаляются после обучения.
Состояние для приложения: <каталог установки>/community/status.json.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import signal
import sys
import threading
import time
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Callable, Optional, Protocol

import httpx

from client import community_defaults, consent
from client.config import ClientConfig, ServerCfg, load_config
from client.downloader import HubModelSync, ModelSync
from client.github_login import (LoginError, fetch_login, load_login, load_token, logout, poll, save_login,
                                 save_token, start)
from client.privacy import PrivacyError, check_outgoing, describe_outgoing, ensure_inside, ensure_work_dir, personal_roots
from client.transport import Transport
from protocol.adapter_io import compute_delta, load_adapter
from protocol.contribution import Contribution, sign_contribution
from protocol.errors import ProtocolError
from protocol.identity import Identity
from protocol.package import pack_update
from protocol.spec import AdapterSpec, load_spec

BUNDLED_SPEC = Path(__file__).resolve().parent.parent / "protocol" / "specs" / "multivsr_lora_r16.json"
VIDEO_ID_RE = re.compile(r"^[A-Za-z0-9_-]{11}$")
STAGES = {"task": "Задание", "model": "Общая модель", "download": "Скачивание роликов", "prepare": "Кадры лица и признаки",
          "train": "Обучение", "pack": "Упаковка обновления", "send": "Отправка"}
OUTBOX_FILES = {"manifest": "manifest.json", "payload": "payload.safetensors", "contribution": "contribution.json"}


class Cancelled(Exception):
    pass


class JobError(Exception):
    """Сообщение для карточки приложения (по-русски)."""


@dataclass
class Controls:
    """Флаги от сигналов: SIGTERM/SIGINT — отмена, SIGUSR1/SIGUSR2 — пауза/продолжение. report(доля) — ход шага."""
    cancelled: bool = False
    paused: bool = False
    report: Callable[[float], None] = lambda _f: None

    def check(self) -> None:
        if self.cancelled:
            raise Cancelled()

    def wait_while_paused(self, sleep: Callable[[float], None] = time.sleep) -> None:
        while self.paused and not self.cancelled:
            sleep(0.5)
        self.check()


@dataclass
class ClipItem:
    id: str
    mp4: Path
    text: str
    seconds: float
    hash: str = ""
    feats: Optional[str] = None
    frames: int = 0


@dataclass
class TrainOutcome:
    adapter: Path
    steps_done: int


class Pipeline(Protocol):
    def download(self, video_id: str, out_dir: Path, controls: Controls) -> Path: ...
    def cut(self, video: Path, segments: list[dict], out_dir: Path, prefix: str, controls: Controls) -> list[tuple[int, Path]]: ...
    def prepare(self, clips: list[ClipItem], venc: Path, work: Path, controls: Controls) -> dict[str, dict]: ...
    def train(self, manifest: Path, base_adapter: Path, out: Path, training: dict, work: Path, controls: Controls) -> TrainOutcome: ...


@dataclass
class Paths:
    root: Path

    @property
    def work(self) -> Path:
        return self.root / "work"

    @property
    def status(self) -> Path:
        return self.root / "status.json"

    @property
    def outbox(self) -> Path:
        return self.root / "outbox"

    @property
    def cache(self) -> Path:
        return self.root / "cache"

    @property
    def history(self) -> Path:
        return self.root / "history.jsonl"


def write_json(path: Path, obj) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(obj, ensure_ascii=False, indent=1), encoding="utf8")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def read_json(path: Path, default=None):
    try:
        return json.loads(path.read_text(encoding="utf8"))
    except (OSError, ValueError):
        return default


def server_cfg(cfg: ClientConfig) -> ServerCfg:
    c = cfg.community
    url = c.server_url or community_defaults.SERVER_URL
    key = c.signing_public_key or community_defaults.MODEL_SIGNING_PUBLIC_KEY
    if not url or not key:
        raise JobError("Сервер обучения ещё не настроен: адрес и ключ появятся в следующем выпуске приложения")
    local = url.startswith("http://")
    return replace(cfg.server, url=url, signing_public_key=key, tls_spki_sha256="", tls_ca_file="",
                   tls_system_trust=not local, allow_insecure_localhost=local, retry_attempts=3)


def validate_task(task: dict, max_videos: int = 50) -> dict:
    try:
        videos = task["videos"]
        if not isinstance(videos, list) or not 0 < len(videos) <= max_videos:
            raise ValueError
        for v in videos:
            if not VIDEO_ID_RE.match(v["video_id"]):
                raise ValueError
            for s in v["segments"]:
                if not (0 <= float(s["start"]) < float(s["end"]) <= float(s["start"]) + 15) or not str(s["text"]).strip():
                    raise ValueError
        int(task["base_version"]), str(task["token"]), dict(task["training"])
    except (KeyError, TypeError, ValueError) as e:
        raise JobError("Сервер прислал задание, которое не удалось разобрать") from e
    return task


class Job:
    def __init__(self, cfg: ClientConfig, *, pipeline: Pipeline, http: httpx.Client | None = None,
                 transport: Transport | None = None, spec: AdapterSpec | None = None, controls: Controls | None = None,
                 clock: Callable[[], float] = time.time):
        self.cfg = cfg
        self.paths = Paths(cfg.home / "community")
        self.spec = spec or load_spec(BUNDLED_SPEC)
        self.pipeline = pipeline
        self.controls = controls or Controls()
        self.clock = clock
        self._transport, self._http = transport, http
        self.status: dict = {}
        self.venc_allowed = community_defaults.VENC_SHA256
        self.exclusions_loader: Callable[[], set[str]] = self.fetch_exclusions
        self.models_http: httpx.Client | None = None
        self.lock = threading.Lock()
        self.controls.report = lambda f: self.write(progress=round(max(0.0, min(1.0, f)), 4))

    # --- status for the app ---
    def write(self, **kw) -> None:
        # pipeline output readers report progress from their own threads
        with self.lock:
            self.status.update(kw, updated_at=self.clock(), pid=os.getpid(), paused=self.controls.paused)
            if "stage" in kw:
                self.status["stage_label"] = STAGES.get(kw["stage"], "")
            write_json(self.paths.status, self.status)

    def transport(self) -> Transport:
        if self._transport is None:
            self._transport = Transport(server_cfg(self.cfg), client=self._http)
        return self._transport

    def auth(self) -> dict:
        token = load_token(self.cfg.home)
        if not token:
            raise JobError("Войдите через GitHub: по логину сервер считает лимиты и ваш вклад")
        return {"Authorization": f"Bearer {token}"}

    def roots(self) -> list[Path]:
        return personal_roots(Path(self.cfg.training.lipread_ru_dir).expanduser())

    # --- the job ---
    def run(self) -> dict:
        self.status = {"version": 1, "state": "running", "stage": None, "progress": 0.0, "message": "",
                       "started_at": self.clock(), "task": None, "counts": {}, "preview": None, "receipt": None}
        try:
            if not consent.granted(self.cfg.home, consent.HELP_TRAIN):
                raise JobError("«Помочь обучить» выключено: сначала дайте согласие")
            if any((self.paths.outbox / n).exists() for n in OUTBOX_FILES.values()):
                raise JobError("Есть неотправленное обновление: отправьте или выбросьте его")
            ensure_work_dir(self.paths.root, self.roots())
            work = ensure_work_dir(self.paths.work, self.roots())
            if hasattr(self.pipeline, "preflight"):
                self.pipeline.preflight()
            shutil.rmtree(work, ignore_errors=True)
            work.mkdir(parents=True, mode=0o700)
            self.write(stage="task")
            task = self.fetch_task()
            self.write(stage="model", task={"videos": len(task["videos"]), "seconds_max": task.get("seconds_max"),
                                            "segments": sum(len(v["segments"]) for v in task["videos"]),
                                            "base_version": task["base_version"]})
            base_path = self.sync_model(task["base_version"])
            venc = self.fetch_asset(task.get("assets", {}).get("venc"))
            clips = self.collect_clips(task, work)
            self.write(stage="prepare", progress=0.0)
            prepared = self.pipeline.prepare(clips, venc, work, self.controls)
            ready = [c for c in clips if prepared.get(c.id, {}).get("feats")]
            for c in ready:
                c.feats, c.frames = prepared[c.id]["feats"], int(prepared[c.id]["frames"])
                ensure_inside(Path(c.feats), work)
            for c in clips:
                c.mp4.unlink(missing_ok=True)       # only the features are needed from here on
            shutil.rmtree(work / "faces", ignore_errors=True)
            self.write(counts={**self.status["counts"], "with_face": len(ready)})
            training = task["training"]
            if len(ready) < int(training.get("min_clips", 20)):
                raise JobError(f"Лицо нашлось только в {len(ready)} отрезках, нужно хотя бы {training.get('min_clips', 20)}")
            manifest, train_seconds = self.write_manifest(ready, training, work)
            self.write(stage="train", progress=0.0)
            out = self.pipeline.train(manifest, base_path, work / "trained.safetensors", training, work, self.controls)
            self.controls.check()
            self.write(stage="pack", progress=0.0)
            preview = self.pack(task, base_path, ensure_inside(out.adapter, work), train_seconds, out.steps_done, len(ready))
            if not self.cfg.community.keep_work:
                shutil.rmtree(work, ignore_errors=True)
            self.write(state="ready_to_send", progress=1.0, preview=preview,
                       message="Обновление готово. Посмотрите, что уйдёт на сервер, и нажмите «Отправить»")
            if self.cfg.community.auto_send:
                return self.send()
        except Cancelled:
            self.cleanup()
            self.write(state="cancelled", message="Обучение отменено, ничего не отправлено")
        except (JobError, PrivacyError) as e:
            self.cleanup()
            self.write(state="error", message=str(e))
        except ProtocolError as e:
            self.cleanup()
            self.write(state="error", message=f"Сервер: {e.message or e.code}")
        except httpx.HTTPError:
            self.cleanup()
            self.write(state="error", message="Нет связи с сервером или с YouTube: проверьте интернет и попробуйте позже")
        except Exception:  # noqa: BLE001
            self.cleanup()
            self._log_traceback()
            self.write(state="error", message="Неожиданная ошибка задания; подробности в community/job.log")
        return self.status

    def _log_traceback(self) -> None:
        import traceback
        with (self.paths.root / "job.log").open("a", encoding="utf8") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + traceback.format_exc() + "\n")

    def cleanup(self) -> None:
        if not self.cfg.community.keep_work:
            shutil.rmtree(self.paths.work, ignore_errors=True)

    def fetch_task(self) -> dict:
        return validate_task(self.transport().request("GET", "/v1/task", headers=self.auth()).json())

    def sync_model(self, base_version: int) -> Path:
        ccfg = replace(self.cfg, server=server_cfg(self.cfg), home=self.paths.root)
        models = self.cfg.community.models_url or community_defaults.MODELS_URL
        if models and models != "server":
            if not models.startswith("https://") and not models.startswith("http://127.0.0.1"):
                raise JobError("Адрес репозитория модели должен быть https://")
            sync = HubModelSync(ccfg, self.spec, models, self.models_http or httpx.Client(timeout=120.0)).sync()
        else:
            sync = ModelSync(ccfg, self.spec, self.transport()).sync()
        if sync.version != base_version:
            raise JobError("Общая модель обновилась, пока выдавалось задание: запустите ещё раз")
        return sync.path

    def fetch_asset(self, asset: dict | None) -> Path:
        if not asset or not re.fullmatch(r"[0-9a-f]{64}", str(asset.get("sha256", ""))):
            raise JobError("В задании нет визуальной части модели")
        if asset["sha256"] not in self.venc_allowed:
            raise JobError("Сервер предлагает незнакомую визуальную часть модели: обновите приложение")
        dst = self.paths.cache / f"venc-{asset['sha256'][:16]}.pth"
        if dst.exists() and _sha256(dst) == asset["sha256"]:
            return dst
        if not str(asset.get("url", "")).startswith("https://"):
            raise JobError("Адрес визуальной части модели должен быть https://")
        dst.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        tmp = dst.with_suffix(".part")
        h = hashlib.sha256()
        with httpx.stream("GET", asset["url"], follow_redirects=True, timeout=300.0) as r:
            r.raise_for_status()
            with open(tmp, "wb") as f:
                for chunk in r.iter_bytes(1 << 20):
                    self.controls.check()
                    h.update(chunk)
                    f.write(chunk)
        if h.hexdigest() != asset["sha256"]:
            tmp.unlink(missing_ok=True)
            raise JobError("Визуальная часть модели скачалась с другой контрольной суммой")
        os.replace(tmp, dst)
        return dst

    def fetch_exclusions(self) -> set[str]:
        """Каналы из журнала data-governance. Журнал недоступен — задание не идёт (как и задания на сервере)."""
        try:
            r = httpx.get(community_defaults.EXCLUSIONS_URL, timeout=30.0, follow_redirects=True)
        except httpx.HTTPError as e:
            raise JobError("Журнал исключений каналов недоступен: проверьте интернет") from e
        if r.status_code == 404:
            return set()
        if r.status_code != 200:
            raise JobError("Журнал исключений каналов недоступен, попробуйте позже")
        return {ln.split()[0] for ln in r.text.splitlines()
                if ln.strip() and not ln.startswith("#") and re.match(r"^UC[A-Za-z0-9_-]{22}\b", ln)}

    def collect_clips(self, task: dict, work: Path) -> list[ClipItem]:
        videos_dir, clips_dir = work / "videos", work / "clips"
        excluded = self.exclusions_loader()
        clips, failed = [], 0
        n = len(task["videos"])
        for i, v in enumerate(task["videos"]):
            self.controls.wait_while_paused()
            self.write(stage="download", progress=i / n)
            try:
                video = ensure_inside(self.pipeline.download(v["video_id"], videos_dir, self.controls), work)
                channel = video.with_suffix(".channel")
                if channel.exists() and channel.read_text().strip() in excluded:
                    raise JobError("канал попросил исключить свои ролики")
                cut = self.pipeline.cut(video, v["segments"], clips_dir, f"{i:02d}", self.controls)
            except Cancelled:
                raise
            except Exception:  # noqa: BLE001  (a removed or region-locked video skips, the others go on)
                failed += 1
                cut = []
            finally:
                shutil.rmtree(videos_dir, ignore_errors=True)    # the whole video never outlives its cutting
            for k, path in cut:
                seg = v["segments"][k]
                p = ensure_inside(path, work)
                clips.append(ClipItem(id=f"{i:02d}_{k:03d}", mp4=p, text=str(seg["text"]).strip(),
                                      seconds=float(seg["end"]) - float(seg["start"]), hash=_sha1(p)))
            self.write(counts={"videos_ok": i + 1 - failed, "videos_failed": failed, "clips": len(clips)})
        if not clips:
            raise JobError("Ни один ролик задания не скачался: проверьте интернет и yt-dlp")
        return clips

    def write_manifest(self, ready: list[ClipItem], training: dict, work: Path) -> tuple[Path, float]:
        dev_frac = float(training.get("dev_fraction", 0.1))
        rows, train_seconds = [], 0.0
        for c in ready:
            split = "dev" if int(c.hash[:8], 16) / 0xFFFFFFFF < dev_frac else "train"
            if split == "train":
                train_seconds += c.seconds
            rows.append({"id": f"public/{c.id}", "video": None, "text": c.text, "source": "public", "split": split,
                         "hash": c.hash, "frames": c.frames, "feats": c.feats})
        if not any(r["split"] == "dev" for r in rows):
            rows[-1]["split"] = "dev"
            train_seconds -= ready[-1].seconds
        m = work / "manifest.jsonl"
        m.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows), encoding="utf8")
        return m, round(train_seconds, 1)

    def pack(self, task: dict, base_path: Path, trained: Path, train_seconds: float, steps: int, n_clips: int) -> dict:
        identity = Identity.load_or_create(self.cfg.home)
        base = load_adapter(base_path)
        delta = compute_delta(load_adapter(trained), base, self.spec)
        packed = pack_update(delta, spec=self.spec, base_version=int(task["base_version"]), num_examples=n_clips,
                             identity=identity)
        contrib = Contribution(client_id=identity.client_id, payload_sha256=packed.manifest.payload_sha256,
                               base_version=packed.manifest.base_version, task_token=task["token"],
                               data_seconds=max(0.0, train_seconds), training_steps=steps, num_clips=n_clips,
                               credit_public=self.cfg.community.credit_public)
        parts = {"manifest": packed.envelope, "payload": packed.payload, "contribution": sign_contribution(contrib, identity)}
        preview = describe_outgoing(parts, self.spec)
        for k, name in OUTBOX_FILES.items():
            p = self.paths.outbox / name
            p.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            p.write_bytes(parts[k])
        write_json(self.paths.outbox / "preview.json", preview)
        return preview

    def outbox_parts(self) -> dict[str, bytes] | None:
        files = {k: self.paths.outbox / n for k, n in OUTBOX_FILES.items()}
        if not all(p.exists() for p in files.values()):
            return None
        return {k: p.read_bytes() for k, p in files.items()}

    def send(self) -> dict:
        self.status = read_json(self.paths.status, {}) or {"version": 1}
        parts = self.outbox_parts()
        if parts is None:
            self.write(state="error", message="Нечего отправлять")
            return self.status
        try:
            check_outgoing(parts, self.spec)
            self.write(state="sending", stage="send")
            r = self.transport().request("POST", "/v1/updates", headers=self.auth(), files={
                "manifest": ("manifest.json", parts["manifest"], "application/json"),
                "payload": ("update.safetensors", parts["payload"], "application/octet-stream"),
                "contribution": ("contribution.json", parts["contribution"], "application/json")})
            receipt = r.json()
        except ProtocolError as e:
            if e.code in ("stale_base", "unknown_base", "bad_task", "conflict", "norm_too_large", "bad_payload",
                          "spec_mismatch", "bad_signature", "bad_schema"):
                self.discard(log=False)
                self.write(state="error", message=f"Сервер не принял обновление ({e.code}): {e.message}. Оно выброшено")
            else:
                self.write(state="ready_to_send", message=f"Отправка не удалась ({e.message or e.code}), можно повторить")
            return self.status
        except (JobError, PrivacyError) as e:
            self.write(state="error", message=str(e))
            return self.status
        with self.paths.history.open("a", encoding="utf8") as f:
            f.write(json.dumps({"ts": int(self.clock()), "sent": read_json(self.paths.outbox / "preview.json"),
                                "receipt": receipt}, ensure_ascii=False) + "\n")
        self.discard(log=False)
        self.write(state="done", receipt=receipt, message="Обновление принято сервером. Спасибо! Оно войдёт в общую "
                   "модель, если пройдёт проверку на скрытом экзамене")
        return self.status

    def discard(self, log: bool = True) -> None:
        shutil.rmtree(self.paths.outbox, ignore_errors=True)
        if log:
            self.status = read_json(self.paths.status, {}) or {"version": 1}
            self.write(state="idle", preview=None, message="Обновление выброшено, ничего не отправлено")


def _sha256(p: Path) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def _sha1(p: Path) -> str:
    h = hashlib.sha1()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def status_report(cfg: ClientConfig) -> dict:
    paths = Paths(cfg.home / "community")
    st = read_json(paths.status, {}) or {}
    pid = st.get("pid")
    if st.get("state") in ("running", "sending") and pid and not _alive(pid):
        st["state"], st["message"] = "error", "Задание прервалось (приложение или компьютер выключались)"
    try:
        server_cfg(cfg)
        configured = True
    except JobError:
        configured = False
    logged_in = load_token(cfg.home) is not None
    return {"consent": consent.granted(cfg.home, consent.HELP_TRAIN), "logged_in": logged_in,
            "login": load_login(cfg.home) if logged_in else None,
            "server_configured": configured, "credit_public": cfg.community.credit_public, "job": st,
            "has_outbox": all((paths.outbox / n).exists() for n in OUTBOX_FILES.values())}


def _alive(pid: int) -> bool:
    try:
        os.kill(int(pid), 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def _signal_job(cfg: ClientConfig, sig: int) -> bool:
    st = read_json(Paths(cfg.home / "community").status, {}) or {}
    if st.get("state") == "running" and st.get("pid") and _alive(st["pid"]):
        os.kill(int(st["pid"]), sig)
        return True
    return False


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=["status", "consent", "login", "logout", "run", "pause", "resume", "cancel",
                                    "preview", "send", "discard"])
    ap.add_argument("value", nargs="?", choices=["on", "off"])
    ap.add_argument("--home")
    ap.add_argument("--lipread-dir", help="папка lipread, из которой работает чтение по губам (приложение передаёт свою)")
    a = ap.parse_args(argv)
    cfg = load_config(Path(a.home) if a.home else None)
    if a.lipread_dir:
        cfg.training.lipread_ru_dir = a.lipread_dir
    out = lambda obj: print(json.dumps(obj, ensure_ascii=False), flush=True)  # noqa: E731
    if a.cmd == "status":
        out(status_report(cfg))
        return 0
    if a.cmd == "consent":
        if a.value:
            consent.record(cfg.home, a.value == "on", kind=consent.HELP_TRAIN)
            if a.value == "off":
                _signal_job(cfg, signal.SIGTERM)
        out({"consent": consent.granted(cfg.home, consent.HELP_TRAIN)})
        return 0
    if a.cmd == "logout":
        logout(cfg.home)
        out({"logged_in": False})
        return 0
    if a.cmd == "login":
        return login_cli(cfg, out)
    if a.cmd in ("pause", "resume", "cancel"):
        sig = {"pause": signal.SIGUSR1, "resume": signal.SIGUSR2, "cancel": signal.SIGTERM}[a.cmd]
        out({"signalled": _signal_job(cfg, sig)})
        return 0
    if a.cmd == "preview":
        out(read_json(Paths(cfg.home / "community").outbox / "preview.json"))
        return 0
    from client.lipread_pipeline import LipreadPipeline
    job = Job(cfg, pipeline=LipreadPipeline(cfg))
    if a.cmd == "discard":
        job.discard()
        out(job.status)
        return 0
    if a.cmd == "send":
        st = job.send()
        out(st)
        return 0 if st.get("state") == "done" else 1
    controls = job.controls
    signal.signal(signal.SIGTERM, lambda *_: setattr(controls, "cancelled", True))
    signal.signal(signal.SIGINT, lambda *_: setattr(controls, "cancelled", True))
    signal.signal(signal.SIGUSR1, lambda *_: setattr(controls, "paused", True))
    signal.signal(signal.SIGUSR2, lambda *_: setattr(controls, "paused", False))
    st = job.run()
    out({"state": st.get("state"), "message": st.get("message")})
    return 0 if st.get("state") in ("ready_to_send", "done") else 1


def login_cli(cfg: ClientConfig, out: Callable[[dict], None]) -> int:
    try:
        scfg = server_cfg(cfg)
        tr = Transport(scfg)
        client_id = tr.request("GET", "/v1/config").json().get("github_client_id", "")
        with httpx.Client(timeout=30.0, trust_env=False) as gh:
            code = start(client_id, gh)
            out({"user_code": code.user_code, "verification_uri": code.verification_uri, "expires_in": code.expires_in})
            token = poll(client_id, code, gh)
            login = fetch_login(token, gh)
        save_token(cfg.home, token)
        save_login(cfg.home, login)
        out({"logged_in": True, "login": login})
        return 0
    except (JobError, LoginError) as e:
        out({"logged_in": False, "error": str(e)})
        return 1
    except ProtocolError as e:
        out({"logged_in": False, "error": e.message or "сервер обучения отказал во входе"})
        return 1
    except httpx.HTTPError:
        out({"logged_in": False, "error": "нет связи с GitHub или сервером обучения"})
        return 1


if __name__ == "__main__":
    sys.exit(main())
