#!/usr/bin/env python3
"""Writes docs/STATS.md: stars, forks, contributors, downloads, model quality.

    stats.py           update docs/STATS.md when a number changed
    stats.py --print   print the page instead
    stats.py selftest  offline tests

Reads the GitHub API (GH_TOKEN or GITHUB_TOKEN raises the rate limit). Model
quality comes from metrics.json at the root of the models repository when it
exists, otherwise from "NN,N% WER" in each model release's notes; metrics.json
maps a release tag to {"wer": percent, "test": "test set name"}.
"""

from __future__ import annotations

import base64
import datetime as dt
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PAGE = ROOT / "docs/STATS.md"
REPO = os.environ.get("STATS_REPO", "zigansh1n/velikiy-moguchiy")
MODELS_REPO = os.environ.get("STATS_MODELS_REPO", "zigansh1n/velikiy-moguchiy-models")
DATE_LINE = re.compile(r"^Данные на \d{4}-\d{2}-\d{2}\.$", re.M)
WER = re.compile(r"(\d+(?:[.,]\d+)?)\s*%\s*WER(?:\s+на\s+([^(.\n]+?))?(?:\s*\(([^)]+)\))?[.,;\n]", re.I)


def api(path: str) -> object:
    request = urllib.request.Request(f"https://api.github.com{path}", headers={
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    })
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def paged(path: str) -> list:
    items, page = [], 1
    while True:
        sep = "&" if "?" in path else "?"
        batch = api(f"{path}{sep}per_page=100&page={page}")
        items.extend(batch)
        if len(batch) < 100:
            return items
        page += 1


def releases(repo: str) -> list[dict]:
    found = []
    for release in paged(f"/repos/{repo}/releases"):
        if release.get("draft"):
            continue
        found.append({
            "tag": release["tag_name"],
            "date": (release.get("published_at") or "")[:10],
            "downloads": sum(asset.get("download_count", 0) for asset in release.get("assets", [])),
            "body": release.get("body") or "",
        })
    return found


def models_metrics() -> dict:
    try:
        entry = api(f"/repos/{MODELS_REPO}/contents/metrics.json")
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return {}
        raise
    return json.loads(base64.b64decode(entry["content"]))


def wer_from_notes(body: str) -> tuple[float, str] | None:
    match = WER.search(body + "\n")
    if not match:
        return None
    test = (match.group(3) or match.group(2) or "").strip()
    return float(match.group(1).replace(",", ".")), test


def training_participants() -> tuple[int, float]:
    data = json.loads((ROOT / "contributors.json").read_text(encoding="utf-8"))
    people = data.get("contributors", [])
    return len(people), sum(p.get("data_hours", 0) for p in people)


def number(value: float) -> str:
    text = f"{value:,.1f}" if isinstance(value, float) and not value.is_integer() else f"{int(value):,}"
    return text.replace(",", " ").replace(".", ",")


def collect() -> dict:
    repo = api(f"/repos/{REPO}")
    contributors = [c for c in paged(f"/repos/{REPO}/contributors")
                    if c.get("type") != "Bot" and not c.get("login", "").endswith("[bot]")]
    metrics = models_metrics()
    models = []
    for release in releases(MODELS_REPO):
        quality = metrics.get(release["tag"])
        if quality:
            wer = (float(quality["wer"]), quality.get("test", ""))
        else:
            wer = wer_from_notes(release["body"])
        models.append({**release, "wer": wer})
    people, hours = training_participants()
    return {
        "stars": repo["stargazers_count"],
        "forks": repo["forks_count"],
        "watchers": repo.get("subscribers_count", 0),
        "contributors": len(contributors),
        "training_people": people,
        "training_hours": hours,
        "apps": releases(REPO),
        "models": models,
    }


def render(data: dict, today: str) -> str:
    lines = [
        "# Статистика проекта",
        "",
        "Страница обновляется автоматически раз в день ([workflow](../.github/workflows/stats.yml)) и меняется,",
        "только когда меняются цифры.",
        "",
        f"Данные на {today}.",
        "",
        "## Репозиторий",
        "",
        "| | |",
        "|---|---:|",
        f"| Звёзды | {number(data['stars'])} |",
        f"| Форки | {number(data['forks'])} |",
        f"| Следят за обновлениями | {number(data['watchers'])} |",
        f"| Авторы изменений в коде | {number(data['contributors'])} |",
        f"| Участники обучения ([таблица](../README.md)) | {number(data['training_people'])} |",
        f"| Часов данных от участников | {number(float(data['training_hours']))} |",
        "",
        "## Скачивания приложения",
        "",
    ]
    if data["apps"]:
        lines += ["| Версия | Дата | Скачиваний |", "|---|---|---:|"]
        lines += [f"| {r['tag']} | {r['date']} | {number(r['downloads'])} |" for r in data["apps"]]
        lines.append(f"| **Всего** | | **{number(sum(r['downloads'] for r in data['apps']))}** |")
    else:
        lines.append("Опубликованных версий пока нет.")
    lines += [
        "",
        "## Модели чтения по губам",
        "",
        f"Файлы моделей — в [релизах {MODELS_REPO.split('/')[1]}](https://github.com/{MODELS_REPO}/releases).",
        "Ошибка — доля неверно распознанных слов (WER) на незнакомых людях: чем меньше, тем лучше.",
        "",
    ]
    if data["models"]:
        lines += ["| Версия | Дата | Ошибка (WER) | Тест | Скачиваний |", "|---|---|---:|---|---:|"]
        for r in data["models"]:
            wer, test = (f"{number(r['wer'][0])} %", r["wer"][1]) if r["wer"] else ("—", "")
            lines.append(f"| {r['tag']} | {r['date']} | {wer} | {test} | {number(r['downloads'])} |")
    else:
        lines.append("Опубликованных моделей пока нет.")
    return "\n".join(lines) + "\n"


def update(page: str) -> bool:
    old = PAGE.read_text(encoding="utf-8") if PAGE.exists() else ""
    if DATE_LINE.sub("", old) == DATE_LINE.sub("", page):
        return False
    PAGE.write_text(page, encoding="utf-8")
    return True


def selftest() -> int:
    assert wer_from_notes("Чтение по губам: 72,3% WER на незнакомых людях (MuAViC-ru). Дообучение") == (72.3, "MuAViC-ru")
    assert wer_from_notes("WER 70% нет") is None
    assert wer_from_notes("ошибка 65.5 % WER.") == (65.5, "")
    assert number(1234) == "1 234" and number(72.3) == "72,3" and number(5.0) == "5"
    data = {"stars": 1, "forks": 0, "watchers": 2, "contributors": 1, "training_people": 1, "training_hours": 439,
            "apps": [], "models": [{"tag": "lips-0.1", "date": "2026-10-14", "downloads": 3, "wer": (72.3, "MuAViC-ru")}]}
    page = render(data, "2026-10-14")
    assert "| lips-0.1 | 2026-10-14 | 72,3 % | MuAViC-ru | 3 |" in page
    assert DATE_LINE.sub("", page) == DATE_LINE.sub("", render(data, "2027-01-01"))
    print("selftest: ok")
    return 0


def main() -> int:
    if sys.argv[1:] == ["selftest"]:
        return selftest()
    page = render(collect(), dt.date.today().isoformat())
    if sys.argv[1:] == ["--print"]:
        print(page)
        return 0
    if sys.argv[1:]:
        sys.exit(__doc__)
    print("docs/STATS.md обновлён." if update(page) else "Цифры не изменились.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
