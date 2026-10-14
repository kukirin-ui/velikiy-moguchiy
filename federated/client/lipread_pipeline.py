"""Шаги «Помочь обучить» на настоящих инструментах: yt-dlp, ffmpeg и lipread (кадры лица, признаки, train.py).

Модельные шаги идут через lipread/train_on_me_worker.py prepare (тот же кроп лица и признаки VTP, что у «Обучить на
мне») и lipread/train.py под tools/mem_guard.py с теми же лимитами, что у «Обучить на мне» (lipread/personal.py:
потолок бюджета, пауза при росте свопа и нехватке памяти), и с VELIKIY_MOGUCHIY_APP_JOB=help-train: на Mac lipread
пропускает модельные шаги только для заданий, запущенных кнопкой в приложении (lipread/RULES.md, R11).
Пауза останавливает охранника и группу шага (SIGSTOP), продолжение их будит; отмена сначала будит, затем
останавливает шаг через охранника (train.py сохраняет точку и выходит).
"""
from __future__ import annotations

import collections
import json
import os
import shutil
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

from client import guard
from client.community import Cancelled, ClipItem, Controls, JobError, TrainOutcome
from client.config import ClientConfig

APP_JOB = "help-train"
YOUTUBE = "https://www.youtube.com/watch?v="
# video-only streams at most 720p ("bv", not "bv*", which may pick a stream with audio)
VIDEO_FORMAT = "bv[height<=720][ext=mp4]/bv[height<=720]"
CONVERT = Path(__file__).resolve().parent / "convert_adapter.py"


def _children(pid: int) -> list[int]:
    out = subprocess.run(["pgrep", "-P", str(pid)], capture_output=True, text=True).stdout
    return [int(x) for x in out.split() if x.isdigit()]


def _signal_groups(pids: list[int], sig: int) -> None:
    for p in pids:
        try:
            os.killpg(p, sig)
        except (ProcessLookupError, PermissionError):
            pass


class LipreadPipeline:
    def __init__(self, cfg: ClientConfig):
        self.cfg = cfg
        self.lipread = Path(cfg.training.lipread_ru_dir).expanduser()
        self.py = self.lipread / ".venv" / "bin" / "python"
        bundled = self.lipread / "bin" / "ffmpeg"     # the app's lips environment links imageio-ffmpeg here
        self.ffmpeg = cfg.community.ffmpeg or shutil.which("ffmpeg") or (str(bundled) if bundled.exists() else "ffmpeg")

    def yt_dlp(self) -> list[str]:
        if self.cfg.community.yt_dlp:
            return [self.cfg.community.yt_dlp]
        exe = shutil.which("yt-dlp")
        return [exe] if exe else [sys.executable, "-m", "yt_dlp"]

    def _env(self) -> dict:
        # the app sets VELIKIY_MOGUCHIY_APP_JOB=help-train when the user presses «Помочь обучить»; the client only
        # passes it on and never sets it, so a run not started from the button stays under R11
        env = {k: v for k, v in os.environ.items() if k != "VELIKIY_MOGUCHIY_APP_JOB"}
        if os.environ.get("VELIKIY_MOGUCHIY_APP_JOB") == APP_JOB:
            env["VELIKIY_MOGUCHIY_APP_JOB"] = APP_JOB
        return dict(env, PYTHONUNBUFFERED="1", PYTHONIOENCODING="utf-8", PYTORCH_ENABLE_MPS_FALLBACK="1",
                    TOKENIZERS_PARALLELISM="false")

    def _run(self, cmd: list[str], controls: Controls, *, guarded: bool = False, cwd: Path | None = None,
             on_line=None, timeout: float | None = None) -> str:
        """Подпроцесс с паузой и отменой. Возвращает хвост вывода; ненулевой код -> JobError с последней строкой."""
        full = self._guarded(cmd) if guarded else cmd
        proc = subprocess.Popen(full, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1,
                                errors="replace", cwd=str(cwd) if cwd else None, env=self._env(), start_new_session=True)
        tail: collections.deque[str] = collections.deque(maxlen=40)

        def reader():
            for line in proc.stdout:
                tail.append(line.rstrip())
                if on_line:
                    on_line(line.rstrip())
        t = threading.Thread(target=reader, daemon=True)
        t.start()
        paused, t0 = False, time.monotonic()
        while proc.poll() is None:
            time.sleep(0.5)
            groups = [proc.pid] + _children(proc.pid)
            if controls.cancelled or (timeout and time.monotonic() - t0 > timeout):
                _signal_groups(groups, signal.SIGCONT)
                if guarded:
                    guard.stop_guarded(proc)
                else:
                    _signal_groups(groups, signal.SIGTERM)
                    try:
                        proc.wait(timeout=30)
                    except subprocess.TimeoutExpired:
                        _signal_groups(groups, signal.SIGKILL)
                t.join(timeout=5)
                if controls.cancelled:
                    raise Cancelled()
                raise JobError(f"Шаг не уложился во время: {' '.join(cmd[:2])}")
            if controls.paused != paused:
                paused = controls.paused
                _signal_groups(groups, signal.SIGSTOP if paused else signal.SIGCONT)
            if paused:
                t0 += 0.5  # a paused step does not run out of time
        t.join(timeout=5)
        if proc.returncode != 0:
            last = next((ln for ln in reversed(tail) if ln and not ln.startswith("[mem_guard]")), "нет вывода")
            raise JobError(f"{Path(cmd[1] if len(cmd) > 1 else cmd[0]).name}: {last[:300]}")
        return "\n".join(tail)

    def _personal(self):
        """lipread/personal.py (standard library only): the guard limits and setup checks of «Обучить на мне»."""
        if str(self.lipread) not in sys.path:
            sys.path.insert(0, str(self.lipread))
        import personal
        return personal

    def _guarded(self, cmd: list[str]) -> list[str]:
        if not self.cfg.guard.enabled:
            raise JobError("«Помочь обучить» работает только под охранником памяти (guard.enabled = true)")
        p = self._personal()
        mem_guard = self.lipread.parent / "tools" / "mem_guard.py"
        if not mem_guard.exists():
            raise JobError(f"нет охранника памяти {mem_guard}")
        return p.guard_command(cmd, mem_guard, p.total_ram_gb(), sys.executable)

    def check_setup(self) -> None:
        problems = self._personal().check_setup(self.lipread)
        if problems:
            raise JobError("; ".join(problems))

    def preflight(self) -> None:
        """Before anything is downloaded: the guard is on and the Mac can run the job."""
        if not self.cfg.guard.enabled:
            raise JobError("«Помочь обучить» работает только под охранником памяти (guard.enabled = true)")
        self.check_setup()

    def download(self, video_id: str, out_dir: Path, controls: Controls) -> Path:
        out_dir.mkdir(parents=True, exist_ok=True)
        # the channel id lets the job skip channels of the data-governance journal (the pool may not know them)
        self._run([*self.yt_dlp(), "--no-playlist", "--no-progress", "--quiet", "--no-warnings", "-f", VIDEO_FORMAT,
                   "--max-filesize", "1500M", "-o", str(out_dir / f"{video_id}.%(ext)s"),
                   "--print-to-file", "%(channel_id)s", str(out_dir / f"{video_id}.channel"), "--", YOUTUBE + video_id],
                  controls, timeout=3600)
        files = [p for p in out_dir.glob(f"{video_id}.*") if not p.name.endswith((".part", ".ytdl", ".channel"))]
        if not files:
            raise JobError(f"yt-dlp не сохранил ролик {video_id}")
        return files[0]

    def cut(self, video: Path, segments: list[dict], out_dir: Path, prefix: str, controls: Controls) -> list[tuple[int, Path]]:
        out_dir.mkdir(parents=True, exist_ok=True)
        done = []
        for k, s in enumerate(segments):
            controls.wait_while_paused()
            dst = out_dir / f"{prefix}_{k:03d}.mp4"
            start, dur = float(s["start"]), float(s["end"]) - float(s["start"])
            try:
                self._run([self.ffmpeg, "-nostdin", "-loglevel", "error", "-y", "-ss", f"{start:.3f}", "-i", str(video),
                           "-t", f"{dur:.3f}", "-an", "-r", "25", "-c:v", "libx264", "-preset", "veryfast", "-crf", "18",
                           "-pix_fmt", "yuv420p", str(dst)], controls, timeout=300)
            except JobError:
                continue
            if dst.exists() and dst.stat().st_size > 0:
                done.append((k, dst))
        return done

    def _worker(self) -> Path:
        w = self.lipread / "train_on_me_worker.py"
        if not w.exists():
            raise JobError("В установленной папке lipread нет train_on_me_worker.py: обновите приложение")
        return w

    def prepare(self, clips: list[ClipItem], venc: Path, work: Path, controls: Controls) -> dict[str, dict]:
        self.check_setup()
        job = {"clips": [{"id": c.id, "hash": c.hash, "mp4": str(c.mp4), "feats": True} for c in clips],
               "faces_dir": str(work / "faces"), "feats_dir": str(work / "features"), "venc": str(venc)}
        jp, op = work / "prepare.json", work / "prepared.json"
        jp.write_text(json.dumps(job, ensure_ascii=False))
        stage = {"name": "prepare"}

        def on_line(ln: str):
            if ln.startswith("@@stage "):
                stage["name"] = ln.split()[1]
            elif ln.startswith("@@progress "):
                done, total = (int(x) for x in ln.split()[1:3])
                half = 0.0 if stage["name"] == "prepare" else 0.5
                controls.report(half + 0.5 * done / max(1, total))
        self._run([str(self.py), str(self._worker()), "prepare", "--job", str(jp), "--out", str(op)], controls,
                  guarded=True, cwd=self.lipread, on_line=on_line)
        return json.loads(op.read_text(encoding="utf8"))["clips"]

    def _convert(self, *args: str) -> dict:
        r = subprocess.run([str(self.py), str(CONVERT), *args], capture_output=True, text=True, timeout=300)
        if r.returncode != 0:
            raise JobError(f"конвертер адаптера: {(r.stderr or r.stdout).strip()[-300:]}")
        return json.loads(r.stdout.strip().splitlines()[-1])

    def train(self, manifest: Path, base_adapter: Path, out: Path, training: dict, work: Path, controls: Controls) -> TrainOutcome:
        init_pt = work / "init.pt"
        self._convert("to-pt", str(base_adapter), str(init_pt))
        (work / "no_clips").mkdir(exist_ok=True)   # train.py's leak guard reads test clips from here: none
        steps = int(training["steps"])
        cmd = [str(self.py), str(self.lipread / "train.py"), "--run", "help", "--manifest", str(manifest),
               "--ckpt-dir", str(work / "ckpt"), "--clips-dir", str(work / "no_clips"), "--mix", "public=1",
               "--init-lora", str(init_pt), "--max-steps", str(steps), "--lr", str(training.get("lr", 1e-4)),
               "--batch", str(training.get("batch", 4)), "--accum", str(training.get("accum", 4)),
               "--warmup", str(training.get("warmup", max(5, steps // 10))),
               "--max-seconds", str(training.get("max_seconds", 8.0)), "--early-stop-on", "public",
               "--min-train", str(max(1, int(training.get("min_clips", 20)) // 2)), "--fresh"]

        def on_line(ln: str):
            # train.py prints "шаг N/M ..." lines; anything else is ignored
            parts = ln.replace("/", " ").split()
            if len(parts) >= 3 and parts[0] == "шаг" and parts[1].isdigit():
                controls.report(int(parts[1]) / max(1, steps))
        self._run(cmd, controls, guarded=True, cwd=self.lipread, on_line=on_line)
        run_dir = work / "ckpt" / "help"
        ck = next((p for p in (run_dir / "best.pt", run_dir / "last.pt") if p.exists()), None)
        if ck is None:
            raise JobError("train.py не оставил контрольной точки")
        info = self._convert("from-pt", str(ck), str(out))
        return TrainOutcome(out, int(info["step"]))
