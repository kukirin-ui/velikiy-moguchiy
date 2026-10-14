"""«Обучить на мне»: the rules of the personal lip-reading fine-tune that the Mac app starts, without torch and
without memguard, so all of them are testable on Linux (tests/test_train_on_me.py). The job itself is
train_on_me.py; the model steps are train_on_me_worker.py, train.py and train_e2e.py.

Everything lives in the app's data directory (~/.velikiy-moguchiy, or ~/.koe from before the rename: the same rule as
SPAppDataDirectory() in the app and velikiy_moguchiy_asr::app_dir in the Rust core):

  lipdata/voiced/<unix-ms>.mp4 + .txt + .json   camera clips the app keeps from dictations (lipdata.capture_video);
                                                 .txt is the ASR text of the clean audio: the training label
  lips_model/active.json                         {"current": id | null, "previous": id | "factory" | null}
  lips_model/models/<id>/                        best.pt (LoRA) + best_venc.pth (visual front-end) + model.json
  lips_training/status.json                      progress of the running or the last job (the settings card reads it)
  lips_training/job.lock, job.log                one job at a time, and its log
  lips_training/cache/                           face crops and VTP features, keyed by the video's sha1
  lips_training/work/<job>/                      manifest, checkpoints and evaluations of one job

"current": null is the factory model: results/pod_runs/t1/checkpoints/me1 when it is there, else the authors' base
MultiVSR. Install and rollback rewrite only active.json (one os.replace), so switching models is atomic.
"""
from __future__ import annotations

import fcntl
import hashlib
import json
import math
import os
import platform
import re
import shutil
import subprocess
import sys
import time
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
from metrics import normalize  # noqa: E402  (pure Python)

# R11 exception: the app starts this job with the variable set; memguard.py and tools/mem_guard.py let only the
# scripts of this job through with it (APP_JOB_SCRIPTS), everything else still refuses to run on the Mac.
APP_JOB_ENV = "VELIKIY_MOGUCHIY_APP_JOB"
APP_JOB = "train-on-me"
APP_JOB_SCRIPTS = ("train_on_me_worker.py", "train.py", "train_e2e.py", "mem_guard.py")

MIN_CLIPS = 100            # the button is enabled from this many usable clips
HOLDOUT_FRAC = 0.10        # share of clips held out for the old-vs-new comparison, never trained on
MIN_HOLDOUT = 5            # fewer held-out clips with a face: no comparison, nothing is installed
MIN_SECONDS = 1.0          # as the app's SPLipDataMinDurationSec
MAX_SECONDS = 12.0         # longer clips are not trained on (train.py / train_e2e.py --max-seconds)
DEV_PCT = 15               # light mode: share of the training phrases train.py picks best.pt on
HOLDOUT_SALT = "velikiy-moguchiy-holdout-v1"
DEV_SALT = "velikiy-moguchiy-dev-v1"
FACTORY = "factory"
FACTORY_RUN = ROOT / "results" / "pod_runs" / "t1" / "checkpoints" / "me1"   # lips_service.py's DEFAULT_RUN
BASE_CKPT = ROOT / "weights" / "model.pth"
BASE_VENC = ROOT / "weights" / "feature_extractor.pth"

# Memory guard of the job (tools/mem_guard.py): a reserve and a hard budget cap that scale with the Mac's RAM, because
# the user keeps working on this Mac while it trains. Pausing below 15% free and resuming at 25% (the guard adds 10)
# is the repository default; a stricter threshold could keep a paused step (which holds its memory) paused for good.
GUARD_RESERVE_SHARE = 0.20
GUARD_RESERVE_CAP_GB = 8.0
GUARD_MIN_FREE_PCT = 15
GUARD_MAX_SWAP_GROWTH_MB = 256
GUARD_BUDGET_SHARE = 0.45
GUARD_BUDGET_CAP_GB = 16.0
MIN_BUDGET_GB = 6.0        # below this the decoder alone (about 4.2 GB for an 8 s phrase) leaves no room: refuse
NICE = 10

# Training recipes. light: train.py on frozen VTP features; full: train_e2e.py, the front-end learns too.
LIGHT = dict(batch=4, accum=4, epochs=20, max_steps=400, eval_every=10, patience=6)
FULL = dict(batch=2, accum=8, chunk_batch=4, epochs=20, min_steps=100, max_steps=600, eval_every=25, workers=3,
            lr=2e-4, venc_lr=3e-5)
SMOKE_STEPS = 30           # train_e2e.py R4: a short run of the same code and batch layout before a long one
E2E_MIN_TRAIN_ROWS = 100   # train_e2e.py refuses fewer train rows (personal clips are repeated up to this)
E2E_MIN_DEV = 10           # and fewer dev clips
E2E_DEV_PCT = 15           # train_e2e.py rows_personal: split_for("me:<folder>/<stem>", 15)

# Seconds on an Apple M3 Max (30-core GPU, 36 GB): ESTIMATES. Measured: train.py 0.44 s per 4-clip microbatch
# (results/smoke-train.md), face crop 1.0-1.8 s per clip with det_every 5 and a model load of ~10 s (lips service).
# Not measured on a Mac: the train_e2e.py step and the beam-20 decode, both guessed.
SEC_LOAD = 15.0
SEC_CROP = 0.6             # per clip, 3 crop processes
SEC_FEATURE = 0.3
SEC_LIGHT_STEP = 2.0       # 4 microbatches of 4 clips up to 12 s
SEC_FULL_STEP = 20.0       # 8 microbatches of 2 clips through VTP with backward
SEC_DECODE = 3.0

SHARE = {
    "available": False,
    "note": "Пока недоступно: общий сервер обучения ещё не запущен (federated/ работает только на localhost). "
            "Когда заработает, после удачного обучения на сервер уйдёт только изменение весов адаптера LoRA "
            "(около 3,5 МБ) — никогда видео, кадры, звук или тексты; понадобится и согласие «Участвовать в общем "
            "обучении».",
}


# --- where things are ----------------------------------------------------------------------------------------
def app_data_dir(home: Path | None = None) -> Path:
    """~/.velikiy-moguchiy, or ~/.koe while only that one exists (never creates either)."""
    home = Path(home) if home else Path.home()
    current, legacy = home / ".velikiy-moguchiy", home / ".koe"
    if not current.exists() and legacy.is_dir():
        return legacy
    return current


def default_clips_dir(app_data: Path) -> Path:
    """Default of the app's lipdata.dir (SPLipDataDefaultDirectory)."""
    return Path(app_data) / "lipdata" / "voiced"


class JobPaths:
    def __init__(self, app_data: Path):
        self.root = Path(app_data) / "lips_training"
        self.status = self.root / "status.json"
        self.lock = self.root / "job.lock"
        self.log = self.root / "job.log"
        self.cache = self.root / "cache"
        self.work = self.root / "work"


def write_json_atomic(path: Path, obj, mode: int = 0o600):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    tmp.write_text(json.dumps(obj, ensure_ascii=False, indent=1), encoding="utf8")
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def read_json(path: Path, default=None):
    try:
        return json.loads(Path(path).read_text(encoding="utf8"))
    except (OSError, ValueError):
        return default


# --- clips -----------------------------------------------------------------------------------------------------
@dataclass
class Clip:
    id: str                 # <unix-ms>: the file stem
    mp4: Path
    text: str
    duration: float
    key: str = ""           # normalised text: phrases, not clips, are split between train and hold-out

    def __post_init__(self):
        if not self.key:
            self.key = normalize(self.text)


@dataclass
class Discovery:
    usable: list[Clip]
    total: int              # clips the app counts in «Собрано»: a sidecar with a duration and its video
    total_seconds: float
    skipped: Counter = field(default_factory=Counter)

    @property
    def usable_seconds(self) -> float:
        return sum(c.duration for c in self.usable)


def read_text(p: Path) -> str:
    return " ".join(p.read_text(encoding="utf8").split()).strip()


def test_phrase_keys(clips_dir: Path) -> set[str]:
    """Normalised texts of the owner's test phrases (lipread/clips/*.txt, R10): a clip saying one is never used."""
    out = set()
    for t in sorted(Path(clips_dir).glob("*.txt")):
        try:
            out.add(normalize(read_text(t)))
        except (OSError, UnicodeDecodeError):
            pass
    return out


def discover_clips(clips_dir: Path, test_keys=frozenset(), min_seconds: float = MIN_SECONDS,
                   max_seconds: float = MAX_SECONDS) -> Discovery:
    """The app's clips usable for training. A clip counts as recorded when its sidecar has a duration and its
    video is there (as SPLipDataPolicy statsForDirectory:; the app writes the video last); it is usable when its
    label is not empty, it lasts min..max seconds and it does not say a test phrase."""
    usable, skipped = [], Counter()
    total, total_sec = 0, 0.0
    d = Path(clips_dir)
    if not d.is_dir():
        return Discovery([], 0, 0.0, skipped)
    for js in sorted(d.glob("*.json")):
        if js.name.startswith("."):
            continue
        mp4 = js.with_suffix(".mp4")
        meta = read_json(js)
        if not mp4.exists() or not isinstance(meta, dict):
            continue
        dur = meta.get("duration_s")
        if isinstance(dur, bool) or not isinstance(dur, (int, float)):
            continue
        total += 1
        total_sec += float(dur)
        txt = js.with_suffix(".txt")
        if not txt.exists():
            skipped["нет текста"] += 1
            continue
        try:
            text = read_text(txt)
        except (OSError, UnicodeDecodeError):
            skipped["нет текста"] += 1
            continue
        clip = Clip(js.stem, mp4, text, float(dur))
        if not clip.key:
            skipped["пустой текст"] += 1
        elif dur < min_seconds:
            skipped[f"короче {min_seconds:g} с"] += 1
        elif dur > max_seconds:
            skipped[f"длиннее {max_seconds:g} с"] += 1
        elif clip.key in test_keys:
            skipped["фраза из теста"] += 1
        else:
            usable.append(clip)
    return Discovery(usable, total, total_sec, skipped)


def _order(salt: str, key: str) -> str:
    return hashlib.sha1((salt + key).encode("utf8")).hexdigest()


def split_by_phrase(clips: list[Clip], need: int, salt: str) -> tuple[list[Clip], list[Clip]]:
    """-> (rest, picked): whole phrases, in a fixed pseudo-random order of their normalised text, until `need`
    clips are picked. A phrase that would take more than twice `need` is passed over, so one phrase said many
    times cannot swallow the set. Deterministic: the same clips give the same split, and a phrase keeps its side
    while clips are added (the picked phrases are always the first ones in the fixed order)."""
    groups: dict[str, list[Clip]] = {}
    for c in clips:
        groups.setdefault(c.key, []).append(c)
    picked, n = set(), 0
    for key in sorted(groups, key=lambda k: _order(salt, k)):
        if n >= need:
            break
        if n + len(groups[key]) > max(2 * need, 1):
            continue
        picked.add(key)
        n += len(groups[key])
    return [c for c in clips if c.key not in picked], [c for c in clips if c.key in picked]


def holdout_split(clips: list[Clip], frac: float = HOLDOUT_FRAC) -> tuple[list[Clip], list[Clip]]:
    """-> (train pool, hold-out): 10% of the clips are held out for the old-vs-new comparison and never trained on."""
    if not clips:
        return [], []
    return split_by_phrase(clips, math.ceil(frac * len(clips)), HOLDOUT_SALT)


def dev_split(clips: list[Clip], pct: int = DEV_PCT, min_dev: int = 5) -> tuple[list[Clip], list[Clip]]:
    """Light mode: -> (train, dev); train.py picks best.pt on the dev phrases (early stopping)."""
    if not clips:
        return [], []
    return split_by_phrase(clips, max(min_dev, math.ceil(pct / 100 * len(clips))), DEV_SALT)


def e2e_personal_folder(stems: list[str], min_dev: int = E2E_MIN_DEV, tries: int = 100) -> tuple[str, int, int]:
    """Full mode: train_e2e.py splits personal clips itself, by split_for("me:<folder>/<stem>", 15), and refuses
    fewer than 10 dev clips. -> (folder name, train, dev): the first folder name personal<k> that gives enough dev
    clips and still leaves train clips. Deterministic for the same clips."""
    from split import split_for
    for k in range(tries):
        name = f"personal{k}"
        dev = sum(split_for(f"me:{name}/{s}", E2E_DEV_PCT) == "dev" for s in stems)
        if dev >= min_dev and len(stems) - dev > 0:
            return name, len(stems) - dev, dev
    raise ValueError(f"{len(stems)} clips are too few for {min_dev} dev clips")


def e2e_personal_repeat(n_train: int) -> int:
    """train_e2e.py needs 100 train rows; personal clips are repeated to reach them."""
    return max(1, math.ceil(E2E_MIN_TRAIN_ROWS / max(1, n_train)))


def warmup_steps(steps: int) -> int:
    """Learning-rate warm-up for a run of `steps`; the trainers' default of 100 is longer than a short personal run."""
    return max(5, steps // 10)


def light_steps(n_train: int) -> int:
    """train.py's own count with --mix voiced=1, ceil(epochs * clips / (batch * accum)), capped so the light mode
    stays minutes with many clips; passed to train.py as --max-steps."""
    eff = LIGHT["batch"] * LIGHT["accum"]
    return max(1, min(LIGHT["max_steps"], math.ceil(LIGHT["epochs"] * n_train / eff)))


def full_steps(n_train: int) -> int:
    eff = FULL["batch"] * FULL["accum"]
    return min(FULL["max_steps"], max(FULL["min_steps"], math.ceil(FULL["epochs"] * n_train / eff)))


def e2e_smoke_stamp(lipread_root: Path = ROOT, device: str | None = None) -> Path:
    """The stamp train_e2e.py writes after a short run (smoke_key there, R4); the full mode runs that short run
    first when it is missing. If this copy ever disagrees, train_e2e.py refuses with [R4] and the job runs the
    short run then, so the copy only saves time."""
    device = device or ("mps" if platform.system() == "Darwin" else "cpu")
    h = hashlib.sha1()
    for f in ("train_e2e.py", "train.py", "mvsr.py", "lora.py"):
        h.update((Path(lipread_root) / f).read_bytes())
    tag = (f"{h.hexdigest()[:12]}|{device}|b{FULL['batch']}a{FULL['accum']}c{FULL['chunk_batch']}"
           f"s{float(MAX_SECONDS)}")
    return Path(lipread_root) / "checkpoints" / ".smoke" / (hashlib.sha1(tag.encode()).hexdigest()[:16] + ".ok")


# --- installed model -------------------------------------------------------------------------------------------
@dataclass
class ModelRef:
    kind: str               # personal | factory | base
    lora: Path | None       # best.pt; None: the authors' base model without adapters
    venc: Path              # visual front-end checkpoint
    id: str | None = None
    info: dict = field(default_factory=dict)

    def label(self) -> str:
        if self.kind == "personal":
            when = _date_ru(self.info.get("installed_at"))
            mode = {"light": "лёгкий режим", "full": "полный режим"}.get(self.info.get("mode"), "")
            return "Ваша модель" + (f" от {when}" if when else "") + (f" ({mode})" if mode else "")
        if self.kind == "factory":
            return "Исходная модель"
        return "Базовая модель MultiVSR"

    def describe(self) -> dict:
        return dict(kind=self.kind, id=self.id, label=self.label(), info=self.info,
                    lora=str(self.lora) if self.lora else None, venc=str(self.venc))


def _date_ru(iso: str | None) -> str:
    m = re.match(r"(\d{4})-(\d{2})-(\d{2})", iso or "")
    return f"{m.group(3)}.{m.group(2)}.{m.group(1)}" if m else ""


class NothingToRollBack(Exception):
    pass


class ModelStore:
    """The personal models and which one the lips service reads. Two slots: current and previous; installing a
    new model moves current to previous, rollback swaps them. Older models are deleted."""

    def __init__(self, app_data: Path, lipread_root: Path = ROOT):
        self.root = Path(app_data) / "lips_model"
        self.models = self.root / "models"
        self.active_path = self.root / "active.json"
        self.lipread_root = Path(lipread_root)

    def _exists(self, mid) -> bool:
        return isinstance(mid, str) and bool(mid) and "/" not in mid and \
            (self.models / mid / "best.pt").is_file() and (self.models / mid / "best_venc.pth").is_file()

    def active(self) -> dict:
        a = read_json(self.active_path, {})
        a = a if isinstance(a, dict) else {}
        cur = a.get("current") if self._exists(a.get("current")) else None
        prev = a.get("previous")
        if prev != FACTORY and not self._exists(prev):
            prev = None
        if prev == FACTORY and cur is None:
            prev = None  # the factory model is in use: there is nothing before it
        return {"current": cur, "previous": prev}

    def factory_ref(self) -> ModelRef:
        run = self.lipread_root / FACTORY_RUN.relative_to(ROOT)
        if (run / "best.pt").is_file() and (run / "best_venc.pth").is_file():
            return ModelRef("factory", run / "best.pt", run / "best_venc.pth", None, {"run": str(run)})
        return ModelRef("base", None, self.lipread_root / BASE_VENC.relative_to(ROOT))

    def ref(self, mid: str | None) -> ModelRef:
        if mid in (None, FACTORY):
            return self.factory_ref()
        d = self.models / mid
        info = read_json(d / "model.json", {})
        return ModelRef("personal", d / "best.pt", d / "best_venc.pth", mid, info if isinstance(info, dict) else {})

    def current(self) -> ModelRef:
        return self.ref(self.active()["current"])

    def previous(self) -> ModelRef | None:
        prev = self.active()["previous"]
        return None if prev is None else self.ref(prev)

    def service_run_dir(self) -> Path | None:
        """The folder with best.pt + best_venc.pth the lips service should read; None: its built-in default."""
        cur = self.active()["current"]
        return (self.models / cur) if cur else None

    def _write(self, cur, prev):
        write_json_atomic(self.active_path, {"current": cur, "previous": prev, "changed_at": _now_iso()})

    def install(self, lora: Path, venc: Path, info: dict) -> str:
        """Copies the model in, makes it current and the current one previous. -> the new model's id."""
        self.models.mkdir(parents=True, exist_ok=True, mode=0o700)
        base = time.strftime("%Y%m%d-%H%M%S") + "-" + str(info.get("mode") or "model")
        mid, k = base, 1
        while (self.models / mid).exists():
            k += 1
            mid = f"{base}-{k}"
        staging = self.models / f".staging-{mid}"
        shutil.rmtree(staging, ignore_errors=True)
        staging.mkdir(mode=0o700)
        shutil.copy2(lora, staging / "best.pt")
        shutil.copy2(venc, staging / "best_venc.pth")
        write_json_atomic(staging / "model.json", dict(info, id=mid, installed_at=_now_iso()))
        os.replace(staging, self.models / mid)
        a = self.active()
        self._write(mid, a["current"] or FACTORY)
        self.gc()
        return mid

    def rollback(self) -> dict:
        """Swaps current and previous (so a second rollback undoes the first)."""
        a = self.active()
        if a["previous"] is None:
            raise NothingToRollBack("прежней модели нет")
        cur = None if a["previous"] == FACTORY else a["previous"]
        self._write(cur, a["current"] or FACTORY)
        return self.active()

    def gc(self):
        a = self.active()
        keep = {a["current"], a["previous"]}
        if not self.models.is_dir():
            return
        for d in self.models.iterdir():
            if d.is_dir() and d.name not in keep:
                shutil.rmtree(d, ignore_errors=True)


def _now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S%z")


def service_run_dir(app_data: Path | None = None) -> Path | None:
    """For lips_service.py: the installed personal model's folder, None for the factory model."""
    try:
        return ModelStore(app_data or app_data_dir()).service_run_dir()
    except OSError:
        return None


# --- one job at a time -----------------------------------------------------------------------------------------
class AlreadyRunning(Exception):
    pass


class JobLock:
    """flock on lips_training/job.lock, held by the job for its whole life (released by the kernel if it dies)."""

    def __init__(self, path: Path):
        self.path = Path(path)
        self.fd = None

    def acquire(self):
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        fd = os.open(self.path, os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            os.close(fd)
            raise AlreadyRunning("обучение уже идёт")
        os.ftruncate(fd, 0)
        os.write(fd, f"{os.getpid()}\n".encode())
        self.fd = fd
        return self

    def release(self):
        if self.fd is not None:
            fcntl.flock(self.fd, fcntl.LOCK_UN)
            os.close(self.fd)
            self.fd = None

    __enter__ = acquire

    def __exit__(self, *exc):
        self.release()


def job_running(paths: JobPaths) -> int | None:
    """pid of the running job, None when no job holds the lock."""
    if not paths.lock.exists():
        return None
    fd = os.open(paths.lock, os.O_RDONLY)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
        except OSError:
            txt = os.read(fd, 32).decode(errors="replace").strip()
            return int(txt) if txt.isdigit() else -1
        fcntl.flock(fd, fcntl.LOCK_UN)
        return None
    finally:
        os.close(fd)


def read_status(paths: JobPaths) -> dict | None:
    """status.json; a job that says it is running but holds no lock died without writing its end."""
    st = read_json(paths.status)
    if not isinstance(st, dict):
        return None
    if st.get("state") == "running" and job_running(paths) is None:
        st = dict(st, state="failed", paused=False, eta_sec=None,
                  message="Обучение прервалось: процесс завершился, не дописав итог (см. lips_training/job.log)")
    return st


# --- progress ------------------------------------------------------------------------------------------------
@dataclass
class Stage:
    name: str
    label: str              # Russian, for the settings card
    prior: float            # expected seconds (estimate), weighs the stage in the progress bar


STAGE_LABELS = {
    "prepare": "Готовлю кадры лица",
    "features": "Считаю признаки губ",
    "smoke": "Проверочный прогон",
    "train": "Обучение",
    "eval_old": "Проверяю прежнюю модель",
    "eval_new": "Проверяю новую модель",
    "install": "Устанавливаю",
}


def plan(mode: str, n_clips: int, n_holdout: int, smoke: bool = True) -> list[Stage]:
    """Stages of a job with their expected durations (estimates, see the SEC_* constants)."""
    n_train = max(1, round((n_clips - n_holdout) * (1 - DEV_PCT / 100)))
    st = [("prepare", SEC_LOAD + SEC_CROP * n_clips)]
    if mode == "light":
        st += [("features", SEC_LOAD + SEC_FEATURE * n_clips),
               ("train", SEC_LOAD + SEC_LIGHT_STEP * light_steps(n_train))]
    else:
        if smoke:
            st += [("smoke", 2 * SEC_LOAD + SEC_FULL_STEP * SMOKE_STEPS)]
        st += [("train", 2 * SEC_LOAD + SEC_FULL_STEP * full_steps(n_train))]
    st += [("eval_old", SEC_LOAD + SEC_DECODE * n_holdout), ("eval_new", SEC_LOAD + SEC_DECODE * n_holdout),
           ("install", 2.0)]
    return [Stage(n, STAGE_LABELS[n], p) for n, p in st]


def estimate_seconds(mode: str, n_clips: int) -> float:
    n_hold = math.ceil(HOLDOUT_FRAC * n_clips)
    return sum(s.prior for s in plan(mode, n_clips, n_hold))


class Progress:
    """Overall fraction and ETA. Stages are weighed by their expected durations; the ETA uses the measured speed of
    the running stage once it is 5% done, and scales the remaining stages by how far the finished ones were off.
    Pauses of the memory guard do not count as time spent."""

    def __init__(self, stages: list[Stage], clock=time.monotonic):
        self.stages = list(stages)
        self.clock = clock
        self.done: dict[str, float] = {}     # stage -> active seconds it took
        self.cur: str | None = None
        self.frac = 0.0
        self.t0 = 0.0
        self.paused_at: float | None = None
        self.paused_total = 0.0

    def _stage(self, name) -> Stage:
        return next((s for s in self.stages if s.name == name), Stage(name, STAGE_LABELS.get(name, ""), 1.0))

    def ensure(self, stage: Stage, before: str):
        """Adds a stage the plan did not expect (the R4 short run after all) in front of `before`."""
        if any(s.name == stage.name for s in self.stages):
            return
        i = next((k for k, s in enumerate(self.stages) if s.name == before), len(self.stages))
        self.stages.insert(i, stage)

    def set_prior(self, name, seconds: float):
        for s in self.stages:
            if s.name == name:
                s.prior = max(1.0, seconds)

    def start(self, name):
        if self.cur and self.cur != name:
            self.done[self.cur] = self.active()
        self.t0, self.paused_at, self.paused_total = self.clock(), None, 0.0
        self.frac, self.cur = 0.0, name

    def update(self, frac: float):
        self.frac = min(1.0, max(self.frac, frac))

    def pause(self):
        if self.paused_at is None:
            self.paused_at = self.clock()

    def resume(self):
        if self.paused_at is not None:
            self.paused_total += self.clock() - self.paused_at
            self.paused_at = None

    @property
    def paused(self) -> bool:
        return self.paused_at is not None

    def active(self) -> float:
        now = self.paused_at if self.paused_at is not None else self.clock()
        return max(0.0, now - self.t0 - self.paused_total)

    def finish(self):
        if self.cur:
            self.done[self.cur] = self.active()
        self.cur, self.frac = None, 0.0

    # The readers below take `cur` and `frac` once: the job's heartbeat thread reads while the main thread moves on.
    def label(self) -> str:
        cur = self.cur
        return self._stage(cur).label if cur else ""

    def fraction(self) -> float:
        cur, frac, stages, done = self.cur, self.frac, list(self.stages), dict(self.done)
        total = sum(s.prior for s in stages) or 1.0
        got = sum(s.prior for s in stages if s.name in done)
        if cur:
            got += self._stage(cur).prior * frac
        return min(1.0, got / total)

    def eta(self) -> float | None:
        cur, frac, stages, done = self.cur, self.frac, list(self.stages), dict(self.done)
        done_prior = sum(s.prior for s in stages if s.name in done)
        k = (sum(done[s.name] for s in stages if s.name in done) / done_prior) if done_prior else 1.0
        k = min(10.0, max(0.1, k))
        rest = sum(s.prior for s in stages if s.name not in done and s.name != cur) * k
        if cur:
            act = self.active()
            if frac >= 0.05 and act >= 5:
                rest += act / frac * (1 - frac)
            else:
                rest += max(0.0, self._stage(cur).prior * k - act)
        return rest


_STEP_LINES = (re.compile(r"^@@progress (\d+) (\d+)"), re.compile(r"^шаг (\d+)/(\d+)"),
               re.compile(r"^step (\d+)/(\d+)"))


def parse_line(line: str):
    """A line of a stage's output -> ("steps", done, total) | ("stage", name) | ("paused",) | ("resumed",) | None.
    train.py prints `шаг 5/97 ...`, train_e2e.py `step 10/150 ...`, the worker `@@progress 3/40` and `@@stage x`,
    tools/mem_guard.py `[mem_guard] paused: ...` / `[mem_guard] resumed: ...`."""
    line = line.strip()
    if line.startswith("[mem_guard] paused"):
        return ("paused",)
    if line.startswith("[mem_guard] resumed"):
        return ("resumed",)
    if line.startswith("@@stage "):
        return ("stage", line.split()[1])
    for rx in _STEP_LINES:
        m = rx.match(line)
        if m:
            return ("steps", int(m.group(1)), max(1, int(m.group(2))))
    return None


# --- memory guard ----------------------------------------------------------------------------------------------
def total_ram_gb() -> float:
    if platform.system() == "Darwin":
        out = subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True, text=True).stdout.strip()
        return int(out) / 2**30 if out.isdigit() else 16.0
    return os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES") / 2**30


def guard_budget_gb(ram_gb: float) -> float:
    """The job's memory budget never exceeds 45% of the Mac's RAM nor 16 GB (16 GB on a 36 GB M3 Max)."""
    return round(min(GUARD_BUDGET_CAP_GB, GUARD_BUDGET_SHARE * ram_gb), 1)


def guard_reserve_gb(ram_gb: float) -> float:
    """Memory the guard keeps free for the user's apps: 20% of RAM, at most 8 GB (7.2 GB on 36 GB, 3.2 GB on 16 GB)."""
    return round(min(GUARD_RESERVE_CAP_GB, GUARD_RESERVE_SHARE * ram_gb), 1)


def guard_command(cmd: list[str], mem_guard: Path, ram_gb: float, python: str | None = None) -> list[str]:
    """`cmd` under tools/mem_guard.py with this job's limits: it pauses the stage (SIGSTOP) when swap grows or free
    memory drops below 15%, and caps the MPS budget at guard_budget_gb."""
    return [python or sys.executable, str(mem_guard), "--reserve-gb", f"{guard_reserve_gb(ram_gb):g}",
            "--max-budget-gb", f"{guard_budget_gb(ram_gb):g}", "--min-free-pct", str(GUARD_MIN_FREE_PCT),
            "--max-swap-growth-mb", f"{GUARD_MAX_SWAP_GROWTH_MB:g}", "--", *cmd]


def check_setup(lipread_root: Path = ROOT, ram_gb: float | None = None) -> list[str]:
    """What is missing for a job (the lipread checkout, enough memory), in Russian; empty when it can run."""
    r = Path(lipread_root)
    problems = []
    ram = total_ram_gb() if ram_gb is None else ram_gb
    if guard_budget_gb(ram) < MIN_BUDGET_GB:
        problems.append(f"на этом Mac {ram:.0f} ГБ памяти, для обучения нужно не меньше 16 ГБ")
    if not (r.parent / "tools" / "mem_guard.py").is_file():
        problems.append("нет охранника памяти tools/mem_guard.py рядом с lipread/")
    if not (r / "multivsr" / "models.py").is_file():
        problems.append("нет кода MultiVSR (запустите lipread/setup.sh)")
    if not (r / BASE_CKPT.relative_to(ROOT)).is_file() or not (r / BASE_VENC.relative_to(ROOT)).is_file():
        problems.append("нет весов MultiVSR (запустите lipread/download_weights.sh)")
    return problems


# --- result ----------------------------------------------------------------------------------------------------
def pct(x: float) -> str:
    """0.741 -> «74,1%»."""
    return f"{x * 100:.1f}".replace(".", ",") + "%"


def decide(old: dict | None, new: dict | None) -> tuple[bool, str]:
    """Install only when the new model makes fewer word errors than the installed one on the same held-out
    clips; a tie keeps the installed model."""
    if not old or not new or not old.get("n") or old.get("n") != new.get("n"):
        return False, "Сравнить модели не удалось: нет оценки на отложенных клипах. Оставлена прежняя модель."
    n = old["n"]
    if new["wer"] < old["wer"]:
        return True, (f"Новая модель лучше: ошибка в словах {pct(new['wer'])} вместо {pct(old['wer'])} "
                      f"на {n} отложенных клипах. Установлена.")
    return False, (f"Новая модель не лучше: {pct(new['wer'])} против {pct(old['wer'])} на {n} отложенных клипах. "
                   f"Оставлена прежняя.")


def scan(app_data: Path, clips_dir: Path | None = None, lipread_root: Path = ROOT, min_clips: int = MIN_CLIPS) -> dict:
    """Everything the settings card shows, without ML: clips, readiness, estimates, model, rollback, job."""
    clips_dir = Path(clips_dir) if clips_dir else default_clips_dir(app_data)
    d = discover_clips(clips_dir, test_phrase_keys(Path(lipread_root) / "clips"))
    _, hold = holdout_split(d.usable)
    store = ModelStore(app_data, lipread_root)
    prev = store.previous()
    problems = check_setup(lipread_root)
    n = len(d.usable)
    return {
        "clips_dir": str(clips_dir),
        "total": d.total,
        "total_minutes": round(d.total_seconds / 60, 1),
        "usable": n,
        "usable_minutes": round(d.usable_seconds / 60, 1),
        "min_clips": min_clips,
        "ready": n >= min_clips and not problems,
        "holdout": len(hold),
        "skipped": dict(d.skipped),
        "estimates": {"light": round(estimate_seconds("light", max(n, min_clips))),
                      "full": round(estimate_seconds("full", max(n, min_clips)))},
        "model": store.current().describe(),
        "rollback": {"available": prev is not None, "to": prev.describe() if prev else None},
        "setup_problems": problems,
        "share": SHARE,
        "job": read_status(JobPaths(app_data)),
    }
