"""Планировщик: когда можно обучаться, и учёт активного времени обучения.

Условия запуска (все сразу): питание от сети, режим низкого энергопотребления выключен, Mac простаивает не меньше
idle_minutes, с прошлого участия прошло не меньше min_hours_between_runs. Во время обучения условия пере-проверяются
(кроме интервала): вернулись к Mac или отключили зарядку -> остановка.

ActiveClock считает бюджет max_runtime по АКТИВНОМУ времени: охранник памяти ставит процесс на паузу (SIGSTOP), и эти
паузы не должны съедать бюджет. Для подпроцесса паузу видно по состоянию процессов группы (`ps` -> T), для обучения
внутри процесса по скачку между вызовами tick (процесс «замёрз», когда часы шли).
"""
from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Callable, Optional

from client.config import ScheduleCfg
from client.power import Snapshot


@dataclass
class Decision:
    run: bool
    reasons: list[str] = field(default_factory=list)


def evaluate(snap: Snapshot, cfg: ScheduleCfg, last_run_ts: Optional[float], now: float, *, check_interval: bool = True) -> Decision:
    reasons = []
    if cfg.require_ac_power and not snap.on_ac:
        reasons.append("нет питания от сети")
    if cfg.forbid_low_power_mode and snap.low_power:
        reasons.append("включён режим низкого энергопотребления")
    if snap.idle_seconds < cfg.idle_minutes * 60:
        reasons.append(f"Mac использовали {snap.idle_seconds / 60:.1f} мин назад (нужно простоя {cfg.idle_minutes:g} мин)")
    if check_interval and last_run_ts is not None and now - last_run_ts < cfg.min_hours_between_runs * 3600:
        left = (cfg.min_hours_between_runs * 3600 - (now - last_run_ts)) / 3600
        reasons.append(f"слишком рано после прошлого участия (ещё {left:.1f} ч)")
    return Decision(run=not reasons, reasons=reasons)


class ActiveClock:
    """Накопитель активного времени. tick(now) прибавляет интервал с прошлого вызова, если он не похож на паузу.

    gap_threshold: интервал между tick больше этого значения считается паузой процесса (целиком вычитается,
    кроме одного нормального периода). paused_probe (необязательный): функция, сообщающая, что процесс сейчас на паузе;
    тогда время с последнего tick не засчитывается."""

    def __init__(self, max_active_seconds: float, *, clock: Callable[[], float] = time.monotonic,
                 gap_threshold: float = 60.0, expected_period: float = 1.0,
                 paused_probe: Optional[Callable[[], bool]] = None):
        self.max_active = max_active_seconds
        self.clock = clock
        self.gap = gap_threshold
        self.period = expected_period
        self.probe = paused_probe
        self.active = 0.0
        self.paused_total = 0.0
        self._last = clock()

    def tick(self) -> float:
        now = self.clock()
        dt = now - self._last
        self._last = now
        if self.probe is not None and self.probe():
            self.paused_total += dt
        elif dt > self.gap:
            self.active += self.period
            self.paused_total += dt - self.period
        else:
            self.active += dt
        return self.active

    @property
    def exceeded(self) -> bool:
        return self.active >= self.max_active


class Monitor:
    """should_stop() для тренера: пере-проверка условий не чаще раза в monitor_seconds и (если задан aclock) бюджет
    активного времени. Для подпроцессного тренера бюджет считает он сам (у него есть датчик паузы), aclock=None."""

    def __init__(self, probe, cfg: ScheduleCfg, aclock: Optional[ActiveClock] = None, *, now: Callable[[], float] = time.monotonic):
        self.probe, self.cfg, self.aclock, self.now = probe, cfg, aclock, now
        self.reason: Optional[str] = None
        self._next_check = 0.0

    def __call__(self) -> bool:
        if self.reason:
            return True
        if self.aclock is not None:
            self.aclock.tick()
            if self.aclock.exceeded:
                self.reason = "budget"
                return True
        t = self.now()
        if t >= self._next_check:
            self._next_check = t + self.cfg.monitor_seconds
            d = evaluate(self.probe.snapshot(), self.cfg, None, 0.0, check_interval=False)
            if not d.run:
                self.reason = "conditions: " + "; ".join(d.reasons)
                return True
        return False
