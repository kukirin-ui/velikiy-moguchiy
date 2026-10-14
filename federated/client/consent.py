"""Согласие на участие в общем обучении: отдельное, явное, по умолчанию выключено.

Это не пункт условий использования, а отдельное решение пользователя (см. docs/AGREEMENT.md, PRIVACY.md, TERMS.md).
Хранится в <каталог установки>/consent.json:

    {"contribute_training": true, "changed_at": "2026-10-14T12:00:00Z", "agreement": "2026-10-14"}

Нет файла, он повреждён, в нём false или согласие дано на другую редакцию docs/AGREEMENT.md: клиент ничего не делает —
не скачивает модель, не обучает и не отправляет. Новая редакция текста (AGREEMENT_VERSION) требует нового согласия.
Решение читается в начале каждого прохода, поэтому отзыв действует сразу.

    python -m client.runner consent on|off      записать решение
    python -m client.runner consent             показать
"""
from __future__ import annotations

import json
import time
from pathlib import Path

FILE_NAME = "consent.json"
AGREEMENT_VERSION = "2026-10-14"   # редакция docs/AGREEMENT.md, с которой пользователь согласился


def consent_path(home: Path) -> Path:
    return Path(home) / FILE_NAME


def granted(home: Path) -> bool:
    try:
        data = json.loads(consent_path(home).read_text())
    except (OSError, ValueError):
        return False
    return (isinstance(data, dict) and data.get("contribute_training") is True
            and data.get("agreement") == AGREEMENT_VERSION)


def record(home: Path, contribute: bool, now: float | None = None) -> dict:
    home = Path(home)
    home.mkdir(parents=True, exist_ok=True, mode=0o700)
    data = {
        "contribute_training": bool(contribute),
        "changed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() if now is None else now)),
        "agreement": AGREEMENT_VERSION,
    }
    tmp = consent_path(home).with_suffix(".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False) + "\n")
    tmp.chmod(0o600)
    tmp.replace(consent_path(home))
    return data
