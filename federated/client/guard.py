"""Запуск тяжёлого локального обучения под охранником памяти (client/vendor/mem_guard.py).

Охранник: бюджет памяти = доступная минус резерв (6 ГБ по умолчанию), пауза всей группы процессов (SIGSTOP) при росте
свопа или нехватке свободной памяти, возобновление (SIGCONT). Из-за этого тренер должен переживать паузы:
 * бюджет времени считается по активному времени (scheduler.ActiveClock + GroupPauseProbe);
 * сетевых соединений во время обучения нет (сначала обучение, потом упаковка и отправка);
 * остановка делается SIGINT охранника: он сам снимает паузу и шлёт SIGTERM группе тренера (train.py сохраняет и выходит).
"""
from __future__ import annotations

import os
import signal
import subprocess
import sys
from pathlib import Path
from typing import Callable

from client.config import GuardCfg

BUNDLED = Path(__file__).resolve().parent / "vendor" / "mem_guard.py"


def guard_script(cfg: GuardCfg) -> Path:
    p = Path(cfg.script).expanduser() if cfg.script else BUNDLED
    if not p.exists():
        raise FileNotFoundError(f"mem_guard.py не найден: {p}")
    return p


def wrap_command(cmd: list[str], cfg: GuardCfg) -> list[str]:
    if not cfg.enabled:
        return cmd
    return [sys.executable, str(guard_script(cfg)), "--reserve-gb", f"{cfg.reserve_gb:g}",
            "--min-free-pct", str(cfg.min_free_pct), "--max-swap-growth-mb", f"{cfg.max_swap_growth_mb:g}", "--", *cmd]


def _out(cmd: list[str]) -> str:
    return subprocess.run(cmd, capture_output=True, text=True, timeout=10, check=False).stdout


class GroupPauseProbe:
    """True, если все процессы группы тренера остановлены (состояние T): значит, охранник поставил паузу."""

    def __init__(self, guard_pid: int, runner: Callable[[list[str]], str] = _out):
        self.guard_pid, self.run = guard_pid, runner

    def __call__(self) -> bool:
        kids = [int(x) for x in self.run(["pgrep", "-P", str(self.guard_pid)]).split()]
        if not kids:
            return False
        pgid = str(kids[0])  # дочерний процесс охранника — лидер своей сессии/группы
        states = [ln.split()[1] for ln in self.run(["ps", "-axo", "pgid=,stat="]).splitlines()
                  if len(ln.split()) == 2 and ln.split()[0] == pgid]
        return bool(states) and all(s.startswith("T") for s in states)


def stop_guarded(proc: subprocess.Popen, grace_seconds: float = 120.0,
                 runner: Callable[[list[str]], str] = _out) -> int:
    """Просит охранника остановить группу (SIGINT), ждёт; если не вышел, убивает группу тренера и самого охранника."""
    try:
        proc.send_signal(signal.SIGINT)
        return proc.wait(timeout=grace_seconds)
    except subprocess.TimeoutExpired:
        for kid in runner(["pgrep", "-P", str(proc.pid)]).split():
            try:
                os.killpg(int(kid), signal.SIGKILL)   # дочерний процесс охранника — лидер своей группы
            except (ProcessLookupError, PermissionError):
                pass
        proc.kill()
        return proc.wait()


def spawn_guarded(cmd: list[str], cfg: GuardCfg, env: dict | None = None) -> subprocess.Popen:
    return subprocess.Popen(wrap_command(cmd, cfg), env={**os.environ, **(env or {})})
