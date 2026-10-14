"""Настройки сервера на Hugging Face Space: только переменные окружения (секреты Space задаются в его настройках).

Обязательные:
  HF_TOKEN            токен Hugging Face с правом записи в FL_INBOX (секрет)
  FL_INBOX            hf:<владелец>/<датасет> — закрытый датасет для входящих обновлений и пула роликов
  FL_MODELS           hf:<владелец>/<модель> — открытый репозиторий версий адаптера (его пишет агрегатор)
  FL_TASK_SECRET      случайная строка не короче 32 символов: подпись заданий (секрет)
Необязательные (значения по умолчанию в скобках):
  FL_GITHUB_CLIENT_ID        Client ID OAuth-приложения GitHub для входа с устройства (без него — только токен)
  FL_POOL_PATH               путь пула роликов внутри FL_INBOX (pool/pool.jsonl)
  FL_EXCLUSIONS_URLS         адреса файлов исключений через запятую (data-governance/ в main репозитория)
  FL_MIN_ACCOUNT_AGE_DAYS    (30) аккаунт GitHub моложе — отказ
  FL_MAX_UPDATES_PER_DAY     (2)  обновлений на логин за 24 часа
  FL_MAX_TASKS_PER_DAY       (3)  заданий на логин за 24 часа
  FL_MAX_UPDATE_NORM         (50) L2-норма дельты больше — отказ при приёме
  FL_VIDEOS_PER_TASK         (8)  роликов в задании
  FL_IP_PER_MINUTE           (60) запросов с адреса в минуту
  FL_BANNED_LOGINS           логины через запятую, которым отказано
  FL_TRAINING_JSON           поправки к настройкам обучения в задании (JSON)
  FL_ASSETS_JSON             поправки к файлам, которые клиент скачивает для задания (JSON)
"""
from __future__ import annotations

import json
import os
from dataclasses import dataclass, field

from hub.tasks import DEFAULT_TRAINING

DEFAULT_EXCLUSIONS = "https://raw.githubusercontent.com/zigansh1n/velikiy-moguchiy/main/data-governance/exclusions/channels.tsv"
MODELS_RELEASE = "https://github.com/zigansh1n/velikiy-moguchiy-models/releases/download/lips-0.1/"
DEFAULT_ASSETS = {
    # front-end of lips-0.1: the shared adapter and the hidden exam are built on its VTP features
    "venc": {"url": MODELS_RELEASE + "velikiy-moguchiy-lips-0.1-venc.pth",
             "sha256": "5d3d2808d7f2ca462c9ae8851d8b2114f3dc6937887f57c0ceeddf19d91f16cf", "bytes": 51884747},
}


class SettingsError(Exception):
    pass


@dataclass
class Settings:
    hf_token: str
    inbox: str
    models: str
    task_secret: bytes
    github_client_id: str = ""
    pool_path: str = "pool/pool.jsonl"
    exclusion_urls: list[str] = field(default_factory=lambda: DEFAULT_EXCLUSIONS.split(","))
    min_account_age_days: float = 30.0
    max_updates_per_day: int = 2
    max_tasks_per_day: int = 3
    max_update_norm: float = 50.0
    videos_per_task: int = 8
    ip_per_minute: int = 60
    banned: frozenset[str] = frozenset()
    training: dict = field(default_factory=lambda: dict(DEFAULT_TRAINING))
    assets: dict = field(default_factory=lambda: json.loads(json.dumps(DEFAULT_ASSETS)))

    @classmethod
    def from_env(cls, env: dict | None = None) -> "Settings":
        e = os.environ if env is None else env
        missing = [k for k in ("HF_TOKEN", "FL_INBOX", "FL_MODELS", "FL_TASK_SECRET") if not e.get(k)]
        if missing:
            raise SettingsError("не заданы секреты/переменные Space: " + ", ".join(missing) + " (см. federated/docs/DEPLOY.md)")
        if len(e["FL_TASK_SECRET"]) < 32:
            raise SettingsError("FL_TASK_SECRET короче 32 символов")
        s = cls(hf_token=e["HF_TOKEN"], inbox=e["FL_INBOX"], models=e["FL_MODELS"],
                task_secret=e["FL_TASK_SECRET"].encode())
        s.github_client_id = e.get("FL_GITHUB_CLIENT_ID", "")
        s.pool_path = e.get("FL_POOL_PATH", s.pool_path)
        if e.get("FL_EXCLUSIONS_URLS"):
            s.exclusion_urls = [u.strip() for u in e["FL_EXCLUSIONS_URLS"].split(",") if u.strip()]
        s.min_account_age_days = float(e.get("FL_MIN_ACCOUNT_AGE_DAYS", s.min_account_age_days))
        s.max_updates_per_day = int(e.get("FL_MAX_UPDATES_PER_DAY", s.max_updates_per_day))
        s.max_tasks_per_day = int(e.get("FL_MAX_TASKS_PER_DAY", s.max_tasks_per_day))
        s.max_update_norm = float(e.get("FL_MAX_UPDATE_NORM", s.max_update_norm))
        s.videos_per_task = int(e.get("FL_VIDEOS_PER_TASK", s.videos_per_task))
        s.ip_per_minute = int(e.get("FL_IP_PER_MINUTE", s.ip_per_minute))
        s.banned = frozenset(x.strip().lower() for x in e.get("FL_BANNED_LOGINS", "").split(",") if x.strip())
        if e.get("FL_TRAINING_JSON"):
            s.training.update(json.loads(e["FL_TRAINING_JSON"]))
        if e.get("FL_ASSETS_JSON"):
            s.assets.update(json.loads(e["FL_ASSETS_JSON"]))
        return s
