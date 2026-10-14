"""Память: общий модуль для всех процессов с PyTorch/MPS. Импортировать ДО `import torch`.

ПОЛИТИКА: основной ограничитель это внешний `tools/mem_guard.py -- <команда>` (общий для репозитория): он считает
бюджет MPS из доступной памяти минус резерв 6 ГБ, ставит PYTORCH_MPS_HIGH/LOW_WATERMARK_RATIO и ставит процесс на
паузу (SIGSTOP), если растёт своп или мало свободной памяти. Запускайте все модельные задачи через него
(`./guarded.sh train.py ...`; nightly.sh так и делает).

Что делает этот модуль при импорте:
  * если PYTORCH_MPS_*_WATERMARK_RATIO уже заданы (их поставил mem_guard.py), НЕ трогает их;
  * если не заданы (запуск без обёртки), ставит безопасные 0.35 / 0.25;
  * PYTORCH_ENABLE_MPS_FALLBACK=1 по умолчанию.

Функции:
  free_pct()                    свободная память системы по `memory_pressure`, %
  require_free(min_free, what)  SystemExit, если свободно меньше min_free % (последняя страховка; при работе под
                                mem_guard пауза наступает раньше, на 15%)
  mps_cleanup()                 gc + torch.mps.empty_cache()
  mps_stats()                   (allocated ГБ, driver ГБ, RSS-пик ГБ)
  ActiveClock                   часы «активного» времени: паузы SIGSTOP от mem_guard не считаются (для --max-minutes)

CLI: `python memguard.py --check [--min-free 10]`: код возврата 0, если памяти достаточно (для nightly.sh).
"""
from __future__ import annotations

# The owner forbids ML runs (training, recognition, evaluation) on the Mac: they go to RunPod pods.
# Two exceptions the owner allowed: the synthetic-lips pilot, which sets LIPREAD_MAC_OK=1, and the user's own
# «Обучить на мне» job that the Mac app starts with VELIKIY_MOGUCHIY_APP_JOB=train-on-me: only that job's scripts,
# always under tools/mem_guard.py. The app's lips mode starts lips_service.py with VELIKIY_MOGUCHIY_APP_JOB=lips-service:
# the user's own lip reading on their Mac, that script only. tools/mem_guard.py has the same rule
# (tests/test_train_on_me.py keeps them equal).
import os as _os, sys as _sys, platform as _platform


def r11_allowed(system, env, argv):
    if system != "Darwin" or env.get("LIPREAD_MAC_OK") == "1":
        return True
    if "synth" in " ".join(argv).lower():  # the synthetic-lips pilot is allowed on the Mac
        return True
    script = _os.path.basename(argv[0]) if argv else ""
    if env.get("VELIKIY_MOGUCHIY_APP_JOB") == "lips-service":
        return script == "lips_service.py"
    if env.get("VELIKIY_MOGUCHIY_APP_JOB") == "help-train":  # «Помочь обучить» (R11): train.py and the worker's prepare
        return script in ("train.py", "mem_guard.py") or (script == "train_on_me_worker.py" and argv[1:2] == ["prepare"])
    return env.get("VELIKIY_MOGUCHIY_APP_JOB") == "train-on-me" and script in (
        "train_on_me_worker.py", "train.py", "train_e2e.py", "mem_guard.py")


if not r11_allowed(_platform.system(), _os.environ, _sys.argv):
    _sys.exit("[R11] ML runs are not allowed on the Mac: run this on a RunPod pod (RULES.md R11)")

import os
import re
import resource
import subprocess
import sys

MIN_FREE_DEFAULT = 10  # mem_guard ставит паузу на 15%, мы прерываем работу только если упало до 10% (без обёртки)

# без обёртки mem_guard.py: фиксированные безопасные значения (обе переменные нужны вместе, low <= high)
os.environ.setdefault("PYTORCH_MPS_HIGH_WATERMARK_RATIO", "0.35")
os.environ.setdefault("PYTORCH_MPS_LOW_WATERMARK_RATIO", "0.25")
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")


class ActiveClock:
    """Активное время процесса без пауз SIGSTOP. Поток тикает раз в 0.5 с; если между тиками прошло больше
    gap секунд (процесс был заморожен), разница добавляется в paused. active() = прошедшее - паузы."""

    def __init__(self, gap: float = 8.0):
        import threading
        import time
        self._time = time
        self.t0 = time.monotonic()
        self.paused = 0.0
        self.gap = gap
        self._last = self.t0
        self._stop = False
        t = threading.Thread(target=self._run, daemon=True)
        t.start()

    def _run(self):
        while not self._stop:
            self._time.sleep(0.5)
            now = self._time.monotonic()
            if now - self._last > self.gap:
                self.paused += now - self._last - 0.5
            self._last = now

    def active(self) -> float:
        now = self._time.monotonic()
        extra = (now - self._last - 0.5) if (now - self._last) > self.gap else 0.0  # пауза идёт прямо сейчас
        return now - self.t0 - self.paused - max(extra, 0.0)


def free_pct() -> int:
    try:
        out = subprocess.run(["memory_pressure"], capture_output=True, text=True, timeout=20).stdout
    except Exception:
        return 100
    m = re.search(r"free percentage:\s*(\d+)%", out)
    return int(m.group(1)) if m else 100


def require_free(min_free: int = MIN_FREE_DEFAULT, what: str = "") -> int:
    f = free_pct()
    if f < min_free:
        raise SystemExit(f"[memguard] свободной памяти {f}% < {min_free}%{(' (' + what + ')') if what else ''}: стоп")
    return f


def mps_cleanup():
    import gc
    gc.collect()
    try:
        import torch
        if torch.backends.mps.is_available():
            torch.mps.empty_cache()
    except Exception:
        pass


def mps_stats() -> tuple[float, float, float]:
    import torch
    rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 2**30  # macOS: байты
    if torch.backends.mps.is_available():
        torch.mps.synchronize()
        return torch.mps.current_allocated_memory() / 2**30, torch.mps.driver_allocated_memory() / 2**30, rss
    return 0.0, 0.0, rss


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--min-free", type=int, default=MIN_FREE_DEFAULT)
    a = ap.parse_args()
    f = free_pct()
    print(f"свободно памяти: {f}% (порог {a.min_free}%)")
    sys.exit(0 if f >= a.min_free else 3)
