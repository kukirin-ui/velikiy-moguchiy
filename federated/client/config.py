"""Конфигурация клиента: ~/.velikiy-moguchiy-federated/config.toml (переопределяется VELIKIY_MOGUCHIY_FED_HOME).

Каталог установки с рабочим названием (~/.govorun-federated, переменная GOVORUN_FED_HOME) читается и дальше,
пока нового нет: ключи установки и журнал отправок сохраняются.
"""
from __future__ import annotations

import os
import tomllib
from dataclasses import dataclass, field, fields, is_dataclass
from pathlib import Path


HOME_DIR = "~/.velikiy-moguchiy-federated"
LEGACY_HOME_DIR = "~/.govorun-federated"      # до переименования


def home_dir() -> Path:
    env = os.environ.get("VELIKIY_MOGUCHIY_FED_HOME") or os.environ.get("GOVORUN_FED_HOME")
    if env:
        return Path(env).expanduser()
    current, legacy = Path(HOME_DIR).expanduser(), Path(LEGACY_HOME_DIR).expanduser()
    if not current.exists() and legacy.is_dir():
        return legacy
    return current


@dataclass
class ServerCfg:
    url: str = "https://127.0.0.1:8765"
    signing_public_key: str = ""        # base64, ключ подписи моделей сервера (закреплён, обязателен)
    tls_spki_sha256: str = ""           # hex SHA-256 от SubjectPublicKeyInfo сертификата сервера (закрепление)
    tls_ca_file: str = ""               # доверенный корень/самоподписанный сертификат; пусто = системные
    allow_insecure_localhost: bool = False  # http:// допустим ТОЛЬКО для localhost (разработка, симуляция)
    tls_system_trust: bool = False      # https без закрепления, по системным корням (сервер приёма: сертификаты меняет хостинг)
    timeout_seconds: float = 120.0
    retry_attempts: int = 5
    retry_base_seconds: float = 5.0
    retry_max_sleep_seconds: float = 300.0


@dataclass
class ScheduleCfg:
    require_ac_power: bool = True
    forbid_low_power_mode: bool = True
    idle_minutes: float = 10.0          # Mac не трогали минимум столько
    max_runtime_minutes: float = 30.0   # бюджет АКТИВНОГО времени обучения (паузы охранника памяти не считаются)
    poll_seconds: float = 120.0
    monitor_seconds: float = 15.0       # как часто пере-проверять условия во время обучения
    min_hours_between_runs: float = 24.0
    min_examples: int = 20              # меньше локальных примеров: не участвуем
    steps: int = 200
    min_steps_fraction: float = 0.5     # прерванное обучение отправляется, если сделано не меньше этой доли шагов


@dataclass
class TrainingCfg:
    backend: str = "lipread-ru"         # lipread-ru | stub
    features_dir: str = ""              # пусто = <каталог установки>/features
    spec_path: str = ""                 # пусто = встроенная protocol/specs/multivsr_lora_r16.json
    lipread_ru_dir: str = "~/velikiy-moguchiy/lipread"
    manifest: str = ""                  # пусто = <lipread_ru_dir>/data/manifest.jsonl
    mix: str = "silent=0.6,voiced=0.4"  # на клиенте есть только свои данные (public-реплея нет)


@dataclass
class GuardCfg:
    enabled: bool = True                # локальный тренер ВСЕГДА под охранником памяти
    script: str = ""                    # пусто = client/vendor/mem_guard.py
    reserve_gb: float = 6.0
    min_free_pct: int = 15
    max_swap_growth_mb: float = 512.0


@dataclass
class CommunityCfg:
    """«Помочь обучить» (client/community.py): сервер приёма (Cloudflare Worker) и задания с роликами."""
    server_url: str = ""                # пусто = адрес из client/community_defaults.py
    signing_public_key: str = ""        # пусто = ключ из client/community_defaults.py
    models_url: str = ""                # пусто = MODELS_URL из client/community_defaults.py; "server" = через сервер приёма
    auto_send: bool = False             # False: обновление ждёт, пока пользователь посмотрит и нажмёт «Отправить»
    credit_public: bool = True          # логин GitHub в таблице участников
    yt_dlp: str = ""                    # пусто = yt-dlp из PATH или python -m yt_dlp
    ffmpeg: str = ""                    # пусто = ffmpeg из PATH
    keep_work: bool = False             # True: не удалять отрезки и признаки после обучения (отладка)


@dataclass
class ClientConfig:
    server: ServerCfg = field(default_factory=ServerCfg)
    schedule: ScheduleCfg = field(default_factory=ScheduleCfg)
    training: TrainingCfg = field(default_factory=TrainingCfg)
    guard: GuardCfg = field(default_factory=GuardCfg)
    community: CommunityCfg = field(default_factory=CommunityCfg)
    home: Path = field(default_factory=home_dir)

    def __post_init__(self):
        if not self.training.features_dir:
            self.training.features_dir = str(Path(self.home) / "features")

    @property
    def adapters_dir(self) -> Path:
        return self.home / "adapters"

    @property
    def outbox_dir(self) -> Path:
        return self.home / "outbox"

    @property
    def work_dir(self) -> Path:
        return self.home / "work"

    @property
    def state_path(self) -> Path:
        return self.home / "state.json"

    @property
    def upload_log(self) -> Path:
        return self.home / "upload-log.jsonl"


def _fill(obj, data: dict):
    names = {f.name for f in fields(obj)}
    unknown = set(data) - names
    if unknown:
        raise ValueError(f"неизвестные ключи конфигурации {type(obj).__name__}: {sorted(unknown)}")
    for f in fields(obj):
        if f.name in data and f.name != "home":
            cur = getattr(obj, f.name)
            if is_dataclass(cur):
                _fill(cur, data[f.name])
            else:
                setattr(obj, f.name, type(cur)(data[f.name]))


def load_config(home: Path | None = None) -> ClientConfig:
    cfg = ClientConfig(home=Path(home) if home else home_dir())
    p = cfg.home / "config.toml"
    if p.exists():
        _fill(cfg, tomllib.loads(p.read_text()))
    if not cfg.training.features_dir:
        cfg.training.features_dir = str(cfg.home / "features")
    return cfg


DEFAULT_TOML = """\
# Velikiy Moguchiy («Великий & Могучий»), клиент федеративного обучения. Файл можно править вручную.
[server]
url = "https://127.0.0.1:8765"
signing_public_key = ""        # base64; выдаётся вместе с приложением (python -m server.admin keys)
tls_spki_sha256 = ""           # закрепление ключа сертификата сервера (hex)
tls_ca_file = ""
allow_insecure_localhost = false

[schedule]
require_ac_power = true
forbid_low_power_mode = true
idle_minutes = 10
max_runtime_minutes = 30
min_hours_between_runs = 24
min_examples = 20
steps = 200

[training]
backend = "lipread-ru"         # lipread-ru | stub
features_dir = ""              # пусто = features в каталоге установки
lipread_ru_dir = "~/velikiy-moguchiy/lipread"

[guard]
enabled = true
reserve_gb = 6
min_free_pct = 15
max_swap_growth_mb = 512
"""


def write_default_config(home: Path) -> Path:
    home.mkdir(parents=True, exist_ok=True, mode=0o700)
    p = home / "config.toml"
    if not p.exists():
        p.write_text(DEFAULT_TOML)
    return p
