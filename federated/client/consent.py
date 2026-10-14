"""Согласие на участие в общем обучении: отдельное, явное, по умолчанию выключено.

Это не пункт условий использования, а отдельное решение пользователя (см. docs/AGREEMENT.md, PRIVACY.md, TERMS.md).
Хранится в <каталог установки>/consent.json:

    {"contribute_training": true, "changed_at": "2026-10-14T12:00:00Z", "agreement": "2026-10-15"}

Нет файла, он повреждён, в нём false или согласие дано на другую редакцию docs/AGREEMENT.md: клиент ничего не делает —
не скачивает модель, не обучает и не отправляет. Новая редакция текста (AGREEMENT_VERSION) требует нового согласия.
Решение читается в начале каждого прохода, поэтому отзыв действует сразу.

    python -m client.runner consent on|off      записать решение
    python -m client.runner consent             показать

«Помочь обучить» (client/community.py) спрашивает своё согласие отдельно: файл community-consent.json, ключ
"help_train". Одно согласие не включает другое.
"""
from __future__ import annotations

import json
import time
from pathlib import Path

FILE_NAME = "consent.json"
AGREEMENT_VERSION = "2026-10-15"   # редакция docs/AGREEMENT.md, с которой пользователь согласился
TRAINING = (FILE_NAME, "contribute_training")
HELP_TRAIN = ("community-consent.json", "help_train")


def consent_path(home: Path, kind: tuple[str, str] = TRAINING) -> Path:
    return Path(home) / kind[0]


def granted(home: Path, kind: tuple[str, str] = TRAINING) -> bool:
    try:
        data = json.loads(consent_path(home, kind).read_text())
    except (OSError, ValueError):
        return False
    return (isinstance(data, dict) and data.get(kind[1]) is True
            and data.get("agreement") == AGREEMENT_VERSION)


def record(home: Path, contribute: bool, now: float | None = None, kind: tuple[str, str] = TRAINING) -> dict:
    home = Path(home)
    home.mkdir(parents=True, exist_ok=True, mode=0o700)
    data = {
        kind[1]: bool(contribute),
        "changed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() if now is None else now)),
        "agreement": AGREEMENT_VERSION,
    }
    path = consent_path(home, kind)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False) + "\n")
    tmp.chmod(0o600)
    tmp.replace(path)
    return data
