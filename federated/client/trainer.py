"""Обёртка локального обучения. Узкий интерфейс:

    train_lora(features_dir, base_adapter, steps, out, *, should_stop=None, ...) -> TrainResult

  features_dir  каталог с локальными признаками VTP (данные пользователя, наружу не уходят)
  base_adapter  путь к глобальному адаптеру (safetensors fp32, ключи "<модуль>.A/.B"), с которого стартуем
  steps         сколько шагов оптимизатора
  out           куда записать обученный адаптер (safetensors fp32, тот же набор ключей)
  should_stop   вызывается регулярно; True -> остановиться и вернуть то, что есть (результат помечается stopped_reason)

Бэкенды: StubTrainer (случайное блуждание, только для проверки труб; НЕ учит ничего) и LipreadRuTrainer
(обучение через lipread/train.py в подпроцессе под охранником памяти; код lipread не меняется и не импортируется).
Что осталось подключить: см. README, раздел «Что осталось».
"""
from __future__ import annotations

import json
import shutil
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional, Protocol

import numpy as np

from client import guard
from client.config import ClientConfig
from client.scheduler import ActiveClock
from protocol.adapter_io import load_adapter, save_adapter

ShouldStop = Callable[[], bool]


@dataclass
class TrainResult:
    adapter_path: Path
    num_examples: int
    steps_done: int
    steps_requested: int
    stopped_reason: Optional[str] = None   # None = дошли до конца
    active_seconds: float = 0.0


class Trainer(Protocol):
    def train_lora(self, features_dir: Path, base_adapter: Path, steps: int, out: Path, *,
                   should_stop: Optional[ShouldStop] = None) -> TrainResult: ...


class StubTrainer:
    """Заглушка: двигает B и A случайным блужданием. Нужна для проверки планировщика, упаковки и сети."""

    in_process = True  # бюджет времени считает вызывающий (Monitor с ActiveClock)

    def __init__(self, step_seconds: float = 0.0, step_size: float = 1e-3, seed: int = 0):
        self.step_seconds, self.step_size, self.seed = step_seconds, step_size, seed

    def train_lora(self, features_dir, base_adapter, steps, out, *, should_stop=None) -> TrainResult:
        feats = list(Path(features_dir).glob("*.npy"))
        t = load_adapter(base_adapter)
        rng = np.random.default_rng(self.seed)
        done, reason, t0 = 0, None, time.monotonic()
        for done in range(1, steps + 1):
            for k in t:
                t[k] = t[k] + self.step_size * rng.standard_normal(t[k].shape).astype(np.float32)
            if self.step_seconds:
                time.sleep(self.step_seconds)
            if should_stop and should_stop():
                reason = "stopped"
                break
        save_adapter(t, out)
        return TrainResult(Path(out), len(feats), done, steps, reason, time.monotonic() - t0)


class LipreadRuTrainer:
    """train.py из lipread в подпроцессе под охранником памяти. Не проверено на реальных весах (см. README)."""

    def __init__(self, cfg: ClientConfig, poll_seconds: float = 2.0):
        self.cfg, self.poll = cfg, poll_seconds
        d = Path(cfg.training.lipread_ru_dir).expanduser()
        self.dir = d
        self.py = d / ".venv" / "bin" / "python"
        self.manifest = Path(cfg.training.manifest).expanduser() if cfg.training.manifest else d / "data" / "manifest.jsonl"

    def count_examples(self) -> int:
        n = 0
        for line in self.manifest.read_text(encoding="utf8").splitlines():
            if line.strip():
                r = json.loads(line)
                if r.get("split") == "train" and r.get("source") in ("silent", "voiced"):
                    n += 1
        return n

    def build_command(self, init_pt: Path, ckpt_dir: Path, run: str, steps: int) -> list[str]:
        t = self.cfg.training
        return [str(self.dir / "run.sh"), "train.py", "--run", run, "--ckpt-dir", str(ckpt_dir), "--manifest", str(self.manifest),
                "--init-lora", str(init_pt), "--max-steps", str(steps), "--mix", t.mix, "--fresh"]

    def _convert(self, *args) -> dict:
        script = Path(__file__).resolve().parent / "convert_adapter.py"
        r = subprocess.run([str(self.py), str(script), *args], capture_output=True, text=True, check=True, timeout=300)
        return json.loads(r.stdout.strip().splitlines()[-1])

    def train_lora(self, features_dir, base_adapter, steps, out, *, should_stop=None) -> TrainResult:
        # features_dir тут справочный: train.py читает признаки по пути из манифеста
        work = self.cfg.work_dir / "lipread"
        shutil.rmtree(work, ignore_errors=True)
        work.mkdir(parents=True)
        init_pt = work / "init.pt"
        self._convert("to-pt", str(base_adapter), str(init_pt))
        n_ex = self.count_examples()
        cmd = self.build_command(init_pt, work / "ckpt", "fed", steps)
        proc = guard.spawn_guarded(cmd, self.cfg.guard)
        aclock = ActiveClock(self.cfg.schedule.max_runtime_minutes * 60, expected_period=self.poll,
                             paused_probe=guard.GroupPauseProbe(proc.pid) if self.cfg.guard.enabled else None)
        reason = None
        while proc.poll() is None:
            time.sleep(self.poll)
            aclock.tick()
            if aclock.exceeded:
                reason = "budget"
            elif should_stop and should_stop():
                reason = "stopped"
            if reason:
                guard.stop_guarded(proc)
                break
        run_dir = work / "ckpt" / "fed"
        ck = next((p for p in (run_dir / "best.pt", run_dir / "last.pt") if p.exists()), None)
        if ck is None:
            raise RuntimeError(f"train.py не оставил контрольной точки (код {proc.returncode}, причина {reason})")
        info = self._convert("from-pt", str(ck), str(out))
        if reason is None and proc.returncode not in (0, None):
            reason = f"train.py вышел с кодом {proc.returncode}"
        return TrainResult(Path(out), n_ex, int(info["step"]), steps, reason, aclock.active)


def make_trainer(cfg: ClientConfig) -> Trainer:
    b = cfg.training.backend
    if b == "stub":
        return StubTrainer()
    if b == "lipread-ru":
        return LipreadRuTrainer(cfg)
    raise ValueError(f"неизвестный backend обучения: {b}")


def train_lora(features_dir, base_adapter, steps, out, *, trainer: Optional[Trainer] = None,
               should_stop: Optional[ShouldStop] = None) -> TrainResult:
    """Функциональная форма интерфейса. По умолчанию заглушка; реальный бэкенд передаётся через trainer=."""
    return (trainer or StubTrainer()).train_lora(Path(features_dir), Path(base_adapter), steps, Path(out), should_stop=should_stop)
