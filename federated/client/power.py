"""Состояние питания и простоя Mac: `pmset -g batt`, `pmset -g`, `ioreg -c IOHIDSystem` (HIDIdleTime, наносекунды).

Разбор текста вынесен в чистые функции (тестируются на образцах вывода), запуск команд в `SystemProbe`.
"""
from __future__ import annotations

import re
import subprocess
from dataclasses import dataclass
from typing import Callable, Optional


@dataclass(frozen=True)
class Snapshot:
    on_ac: bool
    low_power: bool
    idle_seconds: float


def parse_on_ac(pmset_batt: str) -> bool:
    """`Now drawing from 'AC Power'` / `'Battery Power'`. Настольный Mac без батареи тоже выдаёт AC Power."""
    m = re.search(r"Now drawing from '([^']+)'", pmset_batt)
    return bool(m) and m.group(1).strip().lower() == "ac power"


def parse_low_power(pmset_g: str) -> bool:
    """`lowpowermode 1` (macOS 12+) или `powermode 1` (0 авто, 1 экономия, 2 высокая производительность)."""
    low = False
    for m in re.finditer(r"^\s*(lowpowermode|powermode)\s+(\d+)", pmset_g, re.M):
        if (m.group(1) == "lowpowermode" and m.group(2) == "1") or (m.group(1) == "powermode" and m.group(2) == "1"):
            low = True
    return low


def parse_hid_idle_seconds(ioreg_out: str) -> Optional[float]:
    """`"HIDIdleTime" = 6627891833` в наносекундах; несколько устройств: берём минимум (самая свежая активность)."""
    vals = [int(x) for x in re.findall(r'"HIDIdleTime"\s*=\s*(\d+)', ioreg_out)]
    return min(vals) / 1e9 if vals else None


def _run(cmd: list[str], timeout: float = 10.0) -> str:
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, check=False).stdout


class SystemProbe:
    def __init__(self, runner: Callable[[list[str]], str] = _run):
        self.run = runner

    def snapshot(self) -> Snapshot:
        on_ac = parse_on_ac(self.run(["pmset", "-g", "batt"]))
        low = parse_low_power(self.run(["pmset", "-g"]))
        idle = parse_hid_idle_seconds(self.run(["ioreg", "-c", "IOHIDSystem"]))
        # idle неизвестен: считаем «не простаивает», безопаснее для пользователя
        return Snapshot(on_ac=on_ac, low_power=low, idle_seconds=0.0 if idle is None else idle)
