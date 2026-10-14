"""«Обучить на мне»: the one-click personal fine-tune of the lip-reading model, started by the Mac app's settings.

  python train_on_me.py scan [--app-data DIR] [--clips-dir DIR]     JSON for the settings card (no ML)
  python train_on_me.py run --mode light|full [--app-data DIR] [--clips-dir DIR]
  python train_on_me.py status | cancel | rollback [--app-data DIR]

`run` detaches into its own session, holds lips_training/job.lock and keeps lips_training/status.json current
(stage, progress, ETA, guard pauses, result). The steps:
  1. clips: the app's camera dictations (personal.discover_clips); the labels are their ASR texts; 10% of the
     phrases are held out and never trained on (personal.holdout_split);
  2. prepare: face crops made like the lips service makes them, plus VTP features of the installed front-end
     (light) or the start checkpoint for train_e2e.py (full);
  3. train, from the installed model: light = train.py on the frozen features (minutes); full = train_e2e.py with
     the visual front-end (hours; preceded by the 30-step short run R4 asks for when its stamp is missing);
  4. eval_old / eval_new: WER of the installed and of the new model on the held-out clips, decoded like the service;
  5. install only when the new model is better (personal.decide); the previous model stays for «Вернуть прежнюю».
Every model step runs under ../tools/mem_guard.py (budget cap, pause when swap grows or free memory drops) at nice 10.
This process itself loads no model. On a Mac the model steps run only with VELIKIY_MOGUCHIY_APP_JOB=train-on-me,
which the app sets for this job alone (RULES.md R11). Cancel: SIGTERM or SIGINT (what `cancel` sends) stops the
running step through the guard; nothing is installed. The job outlives the app; the app re-attaches through
status.json when it starts again.
"""
from __future__ import annotations

import argparse
import collections
import hashlib
import json
import os
import platform
import shutil
import signal
import subprocess
import sys
import threading
import time
import traceback
from pathlib import Path

import personal as P

ROOT = P.ROOT
MEM_GUARD = ROOT.parent / "tools" / "mem_guard.py"
WORKER = ROOT / "train_on_me_worker.py"
TRAIN_PY = ROOT / "train.py"
TRAIN_E2E_PY = ROOT / "train_e2e.py"
STOP_GRACE_SEC = 90.0      # how long a stopped step may take to save and exit before it is killed


class Cancelled(Exception):
    pass


class JobError(Exception):
    """A failure with a message for the settings card (Russian)."""


def last_error(tail: str) -> str:
    """The most telling line of a step's output: the last exception or refusal, else the last line."""
    lines = [ln.strip() for ln in tail.splitlines() if ln.strip() and not ln.startswith("[mem_guard]")]
    for ln in reversed(lines):
        if ln.startswith(("[R", "ОТКАЗ", "SystemExit")) or "Error" in ln or "error" in ln:
            return ln[:300]
    return lines[-1][:300] if lines else "нет вывода"


def _group_alive(pgid: int) -> bool:
    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def stop_guarded(proc: subprocess.Popen, grace: float = STOP_GRACE_SEC):
    """Stops a step started under mem_guard: SIGINT makes the guard resume the step's group and SIGTERM it (train.py
    saves and exits). Whatever is still running after `grace` (the step's group, even if the guard itself is gone,
    and the guard) is killed. The guard starts the step as the leader of its own group, found before the signal."""
    out = subprocess.run(["pgrep", "-P", str(proc.pid)], capture_output=True, text=True).stdout
    groups = [int(k) for k in out.split() if k.isdigit()]
    deadline = time.monotonic() + grace
    try:
        proc.send_signal(signal.SIGINT)
        proc.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        pass
    except ProcessLookupError:
        pass
    for g in groups:
        while _group_alive(g) and time.monotonic() < deadline:
            time.sleep(0.5)
        if _group_alive(g):
            try:
                os.killpg(g, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
    if proc.poll() is None:
        proc.kill()


class HashCache:
    """sha1 of file contents, cached by (size, mtime) in lips_training/cache/hashes.json."""

    def __init__(self, path: Path):
        self.path = path
        d = P.read_json(path, {})
        self.d = d if isinstance(d, dict) else {}

    def get(self, p: Path) -> str:
        st = p.stat()
        key = str(p.resolve())
        e = self.d.get(key)
        if isinstance(e, list) and len(e) == 3 and e[0] == st.st_size and e[1] == st.st_mtime_ns:
            return e[2]
        h = hashlib.sha1()
        with open(p, "rb") as f:
            for blk in iter(lambda: f.read(1 << 20), b""):
                h.update(blk)
        self.d[key] = [st.st_size, st.st_mtime_ns, h.hexdigest()]
        return h.hexdigest()

    def save(self):
        P.write_json_atomic(self.path, self.d)


class Job:
    def __init__(self, mode: str, app_data: Path, clips_dir: Path, min_clips: int = P.MIN_CLIPS,
                 lipread_root: Path = ROOT):
        self.mode, self.app_data, self.clips_dir, self.min_clips = mode, Path(app_data), Path(clips_dir), min_clips
        self.root = Path(lipread_root)
        self.paths = P.JobPaths(app_data)
        self.store = P.ModelStore(app_data, lipread_root)
        self.job_id = time.strftime("%Y%m%d-%H%M%S")
        self.work = self.paths.work / self.job_id
        self.progress: P.Progress | None = None
        self.cancel_reason: str | None = None
        self.child: subprocess.Popen | None = None
        self.lock = threading.Lock()
        self.last_write = 0.0
        self.ram = P.total_ram_gb()
        self.python = sys.executable
        self.env = dict(os.environ, PYTHONUNBUFFERED="1", PYTHONIOENCODING="utf-8", PYTORCH_ENABLE_MPS_FALLBACK="1",
                        TOKENIZERS_PARALLELISM="false")
        self.status = dict(version=1, job_id=self.job_id, state="running", mode=mode, pid=os.getpid(), stage=None,
                           stage_label="Запуск", progress=0.0, eta_sec=None, paused=False, message="",
                           started_at=time.time(), updated_at=time.time(), clips=None, result=None,
                           budget_gb=P.guard_budget_gb(self.ram))
        self.log_f = None

    # --- status and log ---
    def write(self, force: bool = False, **kw):
        with self.lock:
            self.status.update(kw)
            pr = self.progress
            if pr is not None and self.status["state"] == "running":
                eta = pr.eta()
                self.status.update(stage=pr.cur or self.status["stage"], stage_label=pr.label() or self.status["stage_label"],
                                   progress=round(pr.fraction(), 4), eta_sec=None if eta is None else round(eta),
                                   paused=pr.paused)
            now = time.monotonic()
            if not force and now - self.last_write < 1.0:
                return
            self.last_write = now
            self.status["updated_at"] = time.time()
            P.write_json_atomic(self.paths.status, self.status)

    def log(self, msg: str):
        if self.log_f:
            self.log_f.write(f"{time.strftime('%H:%M:%S')} {msg}\n")
            self.log_f.flush()

    def heartbeat(self):
        while self.status["state"] == "running":
            time.sleep(5)
            if self.status["state"] == "running":
                self.write(force=True)

    def cancel(self, reason: str = "Обучение отменено"):
        self.cancel_reason = reason
        child = self.child
        if child is not None and child.poll() is None:
            threading.Thread(target=stop_guarded, args=(child,), daemon=True).start()

    # --- steps ---
    def run_stage(self, name: str, cmd: list[str]) -> tuple[int, str]:
        """One model step under the memory guard; its output goes to the log and drives the progress."""
        if self.cancel_reason:
            raise Cancelled()
        with self.lock:
            self.progress.start(name)
        self.write(force=True)
        full = P.guard_command([str(c) for c in cmd], MEM_GUARD, self.ram, self.python)
        self.log(f"[{name}] " + " ".join(full))
        tail: collections.deque[str] = collections.deque(maxlen=60)
        proc = subprocess.Popen(full, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1,
                                errors="replace", cwd=str(self.root), env=self.env)
        self.child = proc
        if self.cancel_reason:  # cancelled between the check above and Popen
            self.cancel(self.cancel_reason)
        for line in proc.stdout:
            self.log_f.write(line)
            tail.append(line)
            ev = P.parse_line(line)
            if ev is None:
                continue
            with self.lock:  # the heartbeat thread reads the progress too
                if ev[0] == "paused":
                    self.progress.pause()
                elif ev[0] == "resumed":
                    self.progress.resume()
                elif ev[0] == "stage" and ev[1] in P.STAGE_LABELS:
                    self.progress.start(ev[1])
                elif ev[0] == "steps":
                    self.progress.update(ev[1] / ev[2])
            if ev[0] == "paused":
                self.write(force=True, message="Пауза: не хватает памяти, продолжу сам")
            elif ev[0] == "resumed":
                self.write(force=True, message="")
            else:
                self.write(force=ev[0] == "stage")
        rc = proc.wait()
        self.child = None
        self.log_f.flush()
        self.log(f"[{name}] exit {rc}")
        if self.cancel_reason:
            raise Cancelled()
        return rc, "".join(tail)

    def worker(self, *args) -> list[str]:
        return [self.python, str(WORKER), *map(str, args)]

    def prepare(self, clips: list[P.Clip], hashes: dict, base: P.ModelRef, feats_for: set[str]) -> dict:
        """Face crops of all clips; light mode: VTP features of `feats_for` (the training clips) too."""
        venc_id = self.hc.get(base.venc)[:16] if base.venc.exists() else "missing"
        job = dict(clips=[dict(id=c.id, mp4=str(c.mp4), hash=hashes[c.id], feats=c.id in feats_for) for c in clips],
                   faces_dir=str(self.paths.cache / "faces"),
                   feats_dir=str(self.paths.cache / "features" / venc_id) if self.mode == "light" else None,
                   venc=str(base.venc), lora=str(base.lora) if base.lora else None,
                   init_e2e=str(self.work / "init_e2e.pt") if self.mode == "full" and base.lora else None)
        P.write_json_atomic(self.work / "prepare_job.json", job)
        out = self.work / "prepare.json"
        rc, tail = self.run_stage("prepare", self.worker("prepare", "--job", self.work / "prepare_job.json",
                                                         "--out", out))
        res = P.read_json(out)
        if rc != 0 or not isinstance(res, dict):
            raise JobError("Не удалось подготовить клипы: " + last_error(tail))
        return res

    def train_light(self, pool: list[P.Clip], prep: dict, hashes: dict, base: P.ModelRef) -> tuple[Path, Path]:
        train, dev = P.dev_split(pool)
        rows = []
        for split, cs in (("train", train), ("dev", dev)):
            for c in cs:
                p = prep[c.id]
                rows.append(dict(id=f"voiced/{c.id}", video=str(c.mp4), text=c.text, source="voiced", split=split,
                                 hash=hashes[c.id], frames=p["frames"], feats=p["feats"], face=p["face"]))
        manifest = self.work / "manifest.jsonl"
        manifest.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows), encoding="utf8")
        steps = P.light_steps(len(train))
        with self.lock:
            self.progress.set_prior("train", P.SEC_LOAD + P.SEC_LIGHT_STEP * steps)
        L = P.LIGHT
        cmd = [self.python, TRAIN_PY, "--run", "light", "--manifest", manifest, "--ckpt-dir", self.work / "checkpoints",
               "--clips-dir", self.root / "clips", "--mix", "voiced=1", "--max-steps", steps,
               "--warmup", P.warmup_steps(steps), "--batch", L["batch"],
               "--accum", L["accum"], "--max-seconds", P.MAX_SECONDS, "--eval-every", L["eval_every"],
               "--patience", L["patience"], "--min-train", 20, "--target-format", "norm"]
        if base.lora:
            cmd += ["--init-lora", base.lora]
        rc, tail = self.run_stage("train", cmd)
        best = self.work / "checkpoints" / "light" / "best.pt"
        if rc != 0 or not best.exists():
            raise JobError("Обучение не удалось: " + last_error(tail))
        return best, base.venc

    def train_full(self, pool: list[P.Clip], prep: dict, base: P.ModelRef) -> tuple[Path, Path] | None:
        max_frames = int(P.MAX_SECONDS * 25)
        clips = [c for c in pool if 10 <= prep[c.id]["frames"] <= max_frames]
        try:
            folder, n_train, n_dev = P.e2e_personal_folder([c.id for c in clips])
        except ValueError:
            raise JobError(f"Мало клипов с лицом для полного режима: {len(clips)}")
        pdir = self.work / folder
        pdir.mkdir(parents=True, exist_ok=True)
        for c in clips:
            dst = pdir / f"{c.id}.avi"
            try:
                dst.symlink_to(prep[c.id]["face"])
            except OSError:
                shutil.copyfile(prep[c.id]["face"], dst)
            (pdir / f"{c.id}.txt").write_text(c.text + "\n", encoding="utf8")
        empty = self.work / "no_public.jsonl"
        empty.write_text("")
        steps = P.full_steps(n_train)
        with self.lock:
            self.progress.set_prior("train", 2 * P.SEC_LOAD + P.SEC_FULL_STEP * steps)
        F = P.FULL
        common = [self.python, TRAIN_E2E_PY, "--manifest", empty, "--video-dir", self.work / "no_public",
                  "--personal-dir", pdir, "--personal-repeat", P.e2e_personal_repeat(n_train),
                  "--ckpt-dir", self.work / "checkpoints", "--clips-dir", self.root / "clips", "--batch", F["batch"],
                  "--accum", F["accum"], "--chunk-batch", F["chunk_batch"], "--max-seconds", P.MAX_SECONDS,
                  "--workers", F["workers"], "--lr", F["lr"], "--venc-lr", F["venc_lr"], "--eval-every", F["eval_every"],
                  "--target-format", "norm"]
        if base.lora:
            common += ["--init", self.work / "init_e2e.pt"]

        def smoke():
            with self.lock:
                self.progress.ensure(P.Stage("smoke", P.STAGE_LABELS["smoke"],
                                             2 * P.SEC_LOAD + P.SEC_FULL_STEP * P.SMOKE_STEPS), before="train")
            rc, tail = self.run_stage("smoke", common + ["--run", "smoke", "--max-steps", P.SMOKE_STEPS,
                                                         "--warmup", P.warmup_steps(P.SMOKE_STEPS)])
            if rc != 0:
                raise JobError("Проверочный прогон не прошёл: " + last_error(tail))

        if not P.e2e_smoke_stamp(self.root).exists():
            smoke()
        long_run = common + ["--run", "full", "--max-steps", steps, "--warmup", P.warmup_steps(steps)]
        rc, tail = self.run_stage("train", long_run)
        if rc != 0 and "[R4]" in tail:  # the stamp copy disagreed with train_e2e.py: do the short run now
            smoke()
            rc, tail = self.run_stage("train", long_run)
        if rc != 0:
            raise JobError("Обучение не удалось: " + last_error(tail))
        best, venc = self.work / "checkpoints" / "full" / "best.pt", self.work / "checkpoints" / "full" / "best_venc.pth"
        if not best.exists() or not venc.exists():
            return None  # train_e2e.py saves best.pt only when the dev loss improved
        return best, venc

    def evaluate(self, name: str, lora: Path | None, venc: Path, items: Path) -> dict:
        out = self.work / f"{name}.json"
        args = ["evaluate", "--clips", items, "--venc", venc, "--out", out] + (["--lora", lora] if lora else [])
        rc, tail = self.run_stage(name, self.worker(*args))
        res = P.read_json(out)
        if rc != 0 or not isinstance(res, dict):
            raise JobError("Не удалось проверить модель на отложенных клипах: " + last_error(tail))
        return res

    # --- the job ---
    def run(self):
        disc = P.discover_clips(self.clips_dir, P.test_phrase_keys(self.root / "clips"))
        n = len(disc.usable)
        if n < self.min_clips:
            raise JobError(f"Мало клипов для обучения: {n}, нужно не меньше {self.min_clips}")
        problems = P.check_setup(self.root)
        if problems:
            raise JobError("Не готово: " + "; ".join(problems))
        self.hc = HashCache(self.paths.cache / "hashes.json")
        hashes, seen, clips = {}, set(), []
        for c in disc.usable:
            h = self.hc.get(c.mp4)
            if h not in seen:  # the same video twice counts once
                seen.add(h)
                hashes[c.id] = h
                clips.append(c)
        pool, hold = P.holdout_split(clips)
        base = self.store.current()
        smoke = self.mode == "full" and not P.e2e_smoke_stamp(self.root).exists()
        self.progress = P.Progress(P.plan(self.mode, len(clips), len(hold), smoke=smoke))
        self.log(f"clips {len(clips)} (train pool {len(pool)}, held out {len(hold)}), base {base.describe()}")
        self.write(force=True, clips=dict(usable=len(clips), pool=len(pool), holdout=len(hold)),
                   base=base.describe())

        prep = self.prepare(clips, hashes, base, {c.id for c in pool})["clips"]
        self.hc.save()
        has_face = lambda c: bool((prep.get(c.id) or {}).get("face"))  # noqa: E731
        pool_f, hold_f = [c for c in pool if has_face(c)], [c for c in hold if has_face(c)]
        if self.mode == "light":
            pool_f = [c for c in pool_f if prep[c.id].get("feats")]
        no_face = len(clips) - sum(map(has_face, clips))
        self.write(force=True, clips=dict(usable=len(clips), pool=len(pool_f), holdout=len(hold_f), no_face=no_face))
        if len(hold_f) < P.MIN_HOLDOUT:
            raise JobError(f"На отложенных клипах лицо нашлось только в {len(hold_f)}: сравнить модели не на чем")
        if len(pool_f) < max(30, self.min_clips // 2):
            raise JobError(f"Лицо нашлось только в {len(pool_f)} обучающих клипах: мало для обучения")

        if self.mode == "light":
            new = self.train_light(pool_f, prep, hashes, base)
        else:
            new = self.train_full(pool_f, prep, base)
        result = dict(holdout=len(hold_f), train_clips=len(pool_f), old_wer=None, old_cer=None, new_wer=None,
                      new_cer=None, installed=False, model_id=None)
        if new is None:
            result["message"] = "Обучение не улучшило модель даже на проверочных фразах. Оставлена прежняя модель."
            return result
        holdout_items = self.work / "holdout.json"
        P.write_json_atomic(holdout_items, [dict(id=c.id, face=prep[c.id]["face"], text=c.text) for c in hold_f])
        old_eval = self.evaluate("eval_old", base.lora, base.venc, holdout_items)
        result.update(old_wer=old_eval.get("wer"), old_cer=old_eval.get("cer"))
        new_eval = self.evaluate("eval_new", new[0], new[1], holdout_items)
        result.update(new_wer=new_eval.get("wer"), new_cer=new_eval.get("cer"))
        ok, msg = P.decide(old_eval, new_eval)
        result["message"] = msg
        if ok:
            if self.cancel_reason:
                raise Cancelled()
            with self.lock:
                self.progress.start("install")
            self.write(force=True)
            info = dict(mode=self.mode, job_id=self.job_id, base=base.describe(), holdout=len(hold_f),
                        train_clips=len(pool_f), old_wer=old_eval["wer"], new_wer=new_eval["wer"],
                        old_cer=old_eval.get("cer"), new_cer=new_eval.get("cer"))
            result.update(installed=True, model_id=self.store.install(new[0], new[1], info))
        return result

    def main(self) -> int:
        self.paths.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        lock = P.JobLock(self.paths.lock)
        try:
            lock.acquire()
        except P.AlreadyRunning:
            print(json.dumps({"ok": False, "reason": "обучение уже идёт"}, ensure_ascii=False))
            return 1
        try:
            self.log_f = open(self.paths.log, "w", encoding="utf8")
            os.chmod(self.paths.log, 0o600)
            for old in (self.paths.work.iterdir() if self.paths.work.is_dir() else []):
                shutil.rmtree(old, ignore_errors=True)  # only the last job's work folder is kept
            self.work.mkdir(parents=True, exist_ok=True)
            handlers = {sg: signal.signal(sg, lambda *_: self.cancel()) for sg in (signal.SIGTERM, signal.SIGINT,
                                                                                   signal.SIGHUP)}
            self.write(force=True)
            threading.Thread(target=self.heartbeat, daemon=True).start()
            try:
                result = self.run()
                self.write(force=True, state="done", progress=1.0, eta_sec=0, paused=False, stage=None,
                           stage_label="Готово", message=result["message"], result=result)
                self.log("done: " + json.dumps(result, ensure_ascii=False))
                return 0
            except Cancelled:
                self.write(force=True, state="cancelled", eta_sec=None, paused=False,
                           message=f"{self.cancel_reason}. Модель не менялась.")
                self.log("cancelled")
                return 1
            except JobError as e:
                self.write(force=True, state="failed", eta_sec=None, paused=False, message=str(e))
                self.log(f"failed: {e}")
                return 1
            except Exception as e:  # noqa: BLE001
                self.log(traceback.format_exc())
                self.write(force=True, state="failed", eta_sec=None, paused=False,
                           message=f"Ошибка: {type(e).__name__}: {e}"[:400])
                return 1
            finally:
                shutil.rmtree(self.work / "checkpoints", ignore_errors=True)  # the installed model is copied out
                for sg, h in handlers.items():
                    signal.signal(sg, h)
        finally:
            if self.log_f:
                self.log_f.close()
            lock.release()


def detach():
    """Own session (the app's quit or its process group's signals do not reach the job), lower priority and, on a
    Mac, no idle sleep while the job runs."""
    try:
        os.setsid()
    except OSError:
        pass  # already a session leader
    try:
        os.nice(P.NICE)
    except OSError:
        pass
    if platform.system() == "Darwin" and shutil.which("caffeinate"):
        subprocess.Popen(["caffeinate", "-i", "-w", str(os.getpid())], stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=["scan", "run", "status", "cancel", "rollback"])
    ap.add_argument("--mode", choices=["light", "full"], default="light")
    ap.add_argument("--app-data", default=None, help="the app's data directory (default ~/.velikiy-moguchiy or ~/.koe)")
    ap.add_argument("--clips-dir", default=None, help="the app's lipdata.dir (default <app data>/lipdata/voiced)")
    ap.add_argument("--min-clips", type=int, default=P.MIN_CLIPS, help=argparse.SUPPRESS)
    a = ap.parse_args(argv)
    app_data = Path(a.app_data).expanduser() if a.app_data else P.app_data_dir()
    clips_dir = Path(a.clips_dir).expanduser() if a.clips_dir else P.default_clips_dir(app_data)
    paths = P.JobPaths(app_data)
    out = lambda d: print(json.dumps(d, ensure_ascii=False))  # noqa: E731

    if a.cmd == "scan":
        out(P.scan(app_data, clips_dir, ROOT, a.min_clips))
        return 0
    if a.cmd == "status":
        out(P.read_status(paths) or {})
        return 0
    if a.cmd == "cancel":
        pid = P.job_running(paths)
        if not pid or pid <= 1:
            out({"ok": False, "reason": "обучение не идёт"})
            return 1
        os.kill(pid, signal.SIGTERM)
        out({"ok": True, "pid": pid})
        return 0
    if a.cmd == "rollback":
        if P.job_running(paths):
            out({"ok": False, "reason": "идёт обучение: дождитесь конца или отмените его"})
            return 1
        store = P.ModelStore(app_data, ROOT)
        try:
            store.rollback()
        except P.NothingToRollBack as e:
            out({"ok": False, "reason": str(e)})
            return 1
        prev = store.previous()
        out({"ok": True, "model": store.current().describe(), "previous": prev.describe() if prev else None})
        return 0

    # run
    if platform.system() == "Darwin" and os.environ.get(P.APP_JOB_ENV) != P.APP_JOB:
        print(f"[R11] «Обучить на мне» запускается из приложения (оно ставит {P.APP_JOB_ENV}={P.APP_JOB}); "
              f"другие ML-запуски на маке запрещены (RULES.md R11)", file=sys.stderr)
        return 2
    detach()
    return Job(a.mode, app_data, clips_dir, a.min_clips).main()


if __name__ == "__main__":
    sys.exit(main())
