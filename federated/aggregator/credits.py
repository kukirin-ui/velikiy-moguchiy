"""Таблица вклада (contributors.json в корне репозитория, схема tools/contributors/contributors.schema.json).

Засчитывается только обновление, вошедшее в опубликованную версию. Часы и шаги берутся из подписанных сведений
участника, но не больше, чем было в выданном задании (сервер записал это при приёме).
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path

LOGIN_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38}$")


@dataclass(frozen=True)
class Credit:
    login: str
    data_seconds: float
    training_steps: int


def merge_credits(doc: dict, credits: list[Credit]) -> dict:
    rows = doc.setdefault("contributors", [])
    by_login = {r["github"].lower(): r for r in rows}
    for c in credits:
        if not LOGIN_RE.match(c.login):
            raise ValueError(f"недопустимый логин GitHub: {c.login!r}")
        r = by_login.get(c.login.lower())
        if r is None:
            r = {"github": c.login, "data_hours": 0, "training_steps": 0, "accepted_updates": 0}
            rows.append(r)
            by_login[c.login.lower()] = r
        r["data_hours"] = round(r["data_hours"] + max(0.0, c.data_seconds) / 3600.0, 2)
        r["training_steps"] = int(r["training_steps"]) + max(0, int(c.training_steps))
        r["accepted_updates"] = int(r["accepted_updates"]) + 1
    return doc


def update_file(path: Path, credits: list[Credit]) -> bool:
    if not credits:
        return False
    doc = json.loads(path.read_text(encoding="utf8"))
    merge_credits(doc, credits)
    path.write_text(json.dumps(doc, ensure_ascii=False, indent=2) + "\n", encoding="utf8")
    return True
