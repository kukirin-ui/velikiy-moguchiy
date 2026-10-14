"""Настройки сервера (server.toml в каталоге данных; значения по умолчанию безопасные)."""
from __future__ import annotations

import tomllib
from dataclasses import dataclass, field, fields, is_dataclass
from pathlib import Path


@dataclass
class Limits:
    max_update_norm: float = 50.0          # дельта с большей L2-нормой отвергается при приёме (422 norm_too_large)
    max_updates_per_client_per_day: int = 4  # попыток с проверенной подписью за 24 ч на client_id
    ip_requests_per_minute: int = 300      # грубый лимит на адрес (только в памяти, на диск не пишется)


@dataclass
class Aggregation:
    method: str = "trimmed_mean"           # trimmed_mean | median | mean
    trim_ratio: float = 0.1                # доля отбрасываемых клиентов с КАЖДОЙ стороны по каждой координате
    min_clients: int = 10                  # меньше обновлений на базовую версию: раунд не запускается
    clip_norm: float = 0.0                 # >0: фиксированная граница C; 0: адаптивная C = clip_median_mult * медиана норм
    clip_median_mult: float = 1.5
    max_weight_examples: int = 2000        # вес клиента = min(num_examples, это): заявленное число примеров не доверяем
    server_lr: float = 1.0
    retain_payload_days: float = 0.0       # 0: файлы с дельтами удаляются сразу после агрегации


@dataclass
class DP:
    enabled: bool = False                  # центральный DP выключен по умолчанию
    noise_multiplier: float = 1.0          # z: sigma = z * C * w_max / W на координату агрегата
    delta: float = 1e-6
    max_epsilon: float = 0.0               # >0: после исчерпания бюджета новые версии не публикуются


@dataclass
class ServerConfig:
    limits: Limits = field(default_factory=Limits)
    aggregation: Aggregation = field(default_factory=Aggregation)
    dp: DP = field(default_factory=DP)

    def validate(self) -> None:
        a = self.aggregation
        if a.method not in ("trimmed_mean", "median", "mean"):
            raise ValueError(f"aggregation.method: {a.method}")
        if not 0 <= a.trim_ratio < 0.5:
            raise ValueError("aggregation.trim_ratio должен быть в [0, 0.5)")
        if a.min_clients < 1 or a.clip_norm < 0 or a.max_weight_examples < 1:
            raise ValueError("некорректные параметры агрегации")
        if self.dp.enabled and a.clip_norm <= 0:
            raise ValueError("dp.enabled требует фиксированного aggregation.clip_norm > 0 (чувствительность не должна зависеть от данных)")
        if self.dp.enabled and self.dp.noise_multiplier <= 0:
            raise ValueError("dp.noise_multiplier должен быть > 0")


def _fill(obj, data: dict):
    for f in fields(obj):
        if f.name in data:
            cur = getattr(obj, f.name)
            if is_dataclass(cur):
                _fill(cur, data[f.name])
            else:
                setattr(obj, f.name, type(cur)(data[f.name]))
    unknown = set(data) - {f.name for f in fields(obj)}
    if unknown:
        raise ValueError(f"неизвестные ключи конфигурации: {sorted(unknown)}")
    return obj


def load_config(data_dir: Path) -> ServerConfig:
    cfg = ServerConfig()
    p = Path(data_dir) / "server.toml"
    if p.exists():
        _fill(cfg, tomllib.loads(p.read_text()))
    cfg.validate()
    return cfg
