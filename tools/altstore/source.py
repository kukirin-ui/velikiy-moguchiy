#!/usr/bin/env python3
"""Writes docs/altstore/source.json, the AltStore (and SideStore) source of the iPhone app.

    source.py           rewrite the source from the published releases
    source.py --print   print it instead
    source.py selftest  offline tests

One version per published release that has the unsigned IPA, newest first. The bundle identifier,
build number, minimum iOS and the usage descriptions are read from the IPA itself, because AltStore
refuses an IPA whose Info.plist disagrees with the source. Versions already in the file are reused,
so only a new release's IPA is downloaded. Entitlements are the keys of ios/dist/*.entitlements.plist,
the files the IPA is signed with.
"""

from __future__ import annotations

import io
import json
import os
import plistlib
import re
import sys
import tempfile
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "docs/altstore/source.json"
REPO = os.environ.get("ALTSTORE_REPO", "zigansh1n/velikiy-moguchiy")
ASSET = "VelikiyMoguchiy-iOS-unsigned.ipa"
RAW = f"https://raw.githubusercontent.com/{REPO}/main"
SITE = f"https://github.com/{REPO}"
TINT = "9B3A2C"
APP_PLIST = re.compile(r"^Payload/[^/]+\.app/Info\.plist$")
EXTENSION_PLIST = re.compile(r"^Payload/[^/]+\.app/PlugIns/[^/]+\.appex/Info\.plist$")
USAGE = re.compile(r"^NS\w+UsageDescription$")
DESCRIPTION_LIMIT = 1500


def api(path: str) -> object:
    request = urllib.request.Request(f"https://api.github.com{path}", headers={
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    })
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def download(url: str) -> bytes:
    # No token: the asset URL redirects to another host, and public assets need none.
    with urllib.request.urlopen(url, timeout=300) as response:
        return response.read()


def releases() -> list[dict]:
    out, page = [], 1
    while True:
        batch = api(f"/repos/{REPO}/releases?per_page=100&page={page}")
        out += batch
        if len(batch) < 100:
            return out
        page += 1


def inspect_ipa(data: bytes) -> dict:
    with zipfile.ZipFile(io.BytesIO(data)) as ipa:
        names = ipa.namelist()
        app = [n for n in names if APP_PLIST.match(n)]
        if len(app) != 1:
            raise ValueError(f"expected one Payload/*.app/Info.plist, found {len(app)}")
        info = plistlib.loads(ipa.read(app[0]))
        privacy = {k: v for k, v in info.items() if USAGE.match(k)}
        for name in sorted(n for n in names if EXTENSION_PLIST.match(n)):
            for key, value in plistlib.loads(ipa.read(name)).items():
                if USAGE.match(key):
                    privacy.setdefault(key, value)
    return {
        "bundleIdentifier": info["CFBundleIdentifier"],
        "version": info["CFBundleShortVersionString"],
        "buildVersion": str(info.get("CFBundleVersion", "1")),
        "minOSVersion": info.get("MinimumOSVersion", ""),
        "privacy": dict(sorted(privacy.items())),
    }


def entitlements(folder: Path) -> list[str]:
    keys = set()
    for path in sorted(folder.glob("*.entitlements.plist")):
        keys.update(plistlib.loads(path.read_bytes()))
    return sorted(keys)


def notes(body: str) -> str:
    """Plain text for AltStore: the «Что нового» section if there is one, otherwise the introduction."""
    body = (body or "").replace("\r\n", "\n")
    section = re.search(r"^##\s+Что нового\s*\n(.*?)(?=^##\s|\Z)", body, re.M | re.S)
    if section:
        text = section.group(1)
    else:
        text = re.split(r"^##\s", body, maxsplit=1, flags=re.M)[0]
        text = re.sub(r"^#\s.*\n?", "", text, flags=re.M)
    text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text)
    text = re.sub(r"\*\*|__|`", "", text)
    text = re.sub(r"\n{3,}", "\n\n", text).strip()
    if len(text) > DESCRIPTION_LIMIT:
        text = text[:DESCRIPTION_LIMIT].rsplit(" ", 1)[0] + "…"
    return text


def build(all_releases: list[dict], previous: dict | None, fetch=download, ent_folder: Path = ROOT / "ios/dist") -> dict:
    known = {}
    for app in (previous or {}).get("apps", []):
        for version in app.get("versions", []):
            known[version.get("downloadURL")] = (version, app)

    published = [r for r in all_releases if not r.get("draft") and r.get("published_at")]
    published.sort(key=lambda r: r["published_at"], reverse=True)
    versions, latest_meta = [], None
    for release in published:
        asset = next((a for a in release.get("assets", []) if a.get("name") == ASSET), None)
        if not asset:
            continue
        url, size = asset["browser_download_url"], asset["size"]
        cached = known.get(url)
        if cached and cached[0].get("size") == size:
            entry = dict(cached[0])
            meta = {"bundleIdentifier": cached[1].get("bundleIdentifier"),
                    "privacy": cached[1].get("appPermissions", {}).get("privacy", {})}
        else:
            meta = inspect_ipa(fetch(url))
            entry = {
                "version": meta["version"],
                "buildVersion": meta["buildVersion"],
                "minOSVersion": meta["minOSVersion"],
                "downloadURL": url,
                "size": size,
            }
        entry["date"] = release["published_at"]
        entry["localizedDescription"] = notes(release.get("body", ""))
        versions.append(entry)
        latest_meta = latest_meta or meta

    source = {
        "name": "Великий & Могучий",
        "identifier": "io.github.zigansh1n.velikiy-moguchiy",
        "sourceURL": f"{RAW}/docs/altstore/source.json",
        "subtitle": "Русская голосовая диктовка для iPhone",
        "description": "Официальный источник открытого проекта «Великий & Могучий»: клавиатуры RU и EN с "
                       "нейродиктовкой. Сборки берутся со страницы релизов на GitHub.",
        "website": SITE,
        "iconURL": f"{RAW}/ios/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png",
        "tintColor": TINT,
        "apps": [],
        "news": [],
    }
    if not versions:
        return source
    latest = versions[0]
    source["apps"].append({
        "name": "Великий & Могучий",
        "bundleIdentifier": latest_meta["bundleIdentifier"],
        "developerName": "zigansh1n и участники",
        "subtitle": "Клавиатура с русской нейродиктовкой",
        "localizedDescription": "Клавиатуры RU и EN, повторяющие системную клавиатуру iOS, с кнопкой нейродиктовки "
                                "(Qwen Omni): говорите — и текст появляется там, где стоит курсор. Ключ провайдера "
                                "распознавания (DashScope) указывается в приложении; в сборке ключей нет.\n\n"
                                "После установки добавьте клавиатуры в «Настройки → Основные → Клавиатура → "
                                "Клавиатуры» и включите им «Разрешить полный доступ». Нужен iOS 26.\n\n"
                                "Бесплатный Apple ID даёт не больше 3 App ID за 7 дней, а в сборке их 4: если "
                                "установка не пройдёт, уберите расширение Live Activity.",
        "iconURL": source["iconURL"],
        "tintColor": TINT,
        "category": "utilities",
        "screenshots": [],
        "versions": versions,
        "appPermissions": {"entitlements": entitlements(ent_folder), "privacy": latest_meta["privacy"]},
        # The fields AltStore 1.x and old SideStore read instead of versions[].
        "version": latest["version"],
        "versionDate": latest["date"],
        "versionDescription": latest["localizedDescription"],
        "downloadURL": latest["downloadURL"],
        "size": latest["size"],
    })
    return source


def render(source: dict) -> str:
    return json.dumps(source, ensure_ascii=False, indent=2) + "\n"


def _fake_ipa(version: str, build_number: str) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as ipa:
        ipa.writestr("Payload/A.app/Info.plist", plistlib.dumps({
            "CFBundleIdentifier": "org.example.app", "CFBundleShortVersionString": version,
            "CFBundleVersion": build_number, "MinimumOSVersion": "26.0",
            "NSMicrophoneUsageDescription": "mic",
        }, fmt=plistlib.FMT_BINARY))
        ipa.writestr("Payload/A.app/PlugIns/K.appex/Info.plist", plistlib.dumps({
            "CFBundleIdentifier": "org.example.app.k", "NSSpeechRecognitionUsageDescription": "speech",
        }))
    return buf.getvalue()


def selftest() -> None:
    def release(tag, date, draft=False, asset=True, body=""):
        assets = [{"name": ASSET, "size": 10 + len(tag), "browser_download_url": f"https://dl/{tag}/{ASSET}"}] if asset else []
        return {"tag_name": tag, "draft": draft, "published_at": None if draft else date, "body": body,
                "assets": assets + [{"name": "SHA256SUMS.txt", "size": 1, "browser_download_url": "x"}]}

    fetched = []

    def fetch(url):
        fetched.append(url)
        version = url.split("/")[3].lstrip("v")
        return _fake_ipa(version, version.replace(".", ""))

    with tempfile.TemporaryDirectory() as tmp:
        ent = Path(tmp)
        (ent / "app.entitlements.plist").write_bytes(plistlib.dumps({"keychain-access-groups": ["x"],
                                                                     "com.apple.security.application-groups": ["g"]}))
        rels = [
            release("v0.1.0", "2026-10-15T10:00:00Z", body="# Т\n\nВступление **жирное** и [ссылка](https://x).\n\n## Файлы\nтаблица"),
            release("v0.2.0", "2026-11-15T10:00:00Z", body="# Т\n\nВступ.\n\n## Что нового\n\n- `ключ` новый\n\n## Файлы\n"),
            release("v0.3.0", "2026-12-15T10:00:00Z", draft=True),
            release("v0.2.1", "2026-11-20T10:00:00Z", asset=False),
        ]
        first = build(rels, None, fetch, ent)
        app = first["apps"][0]
        assert [v["version"] for v in app["versions"]] == ["0.2.0", "0.1.0"], app["versions"]
        assert app["version"] == "0.2.0" and app["downloadURL"] == "https://dl/v0.2.0/" + ASSET
        assert app["bundleIdentifier"] == "org.example.app"
        assert app["versions"][0]["buildVersion"] == "020" and app["versions"][0]["minOSVersion"] == "26.0"
        assert app["appPermissions"]["privacy"] == {"NSMicrophoneUsageDescription": "mic",
                                                    "NSSpeechRecognitionUsageDescription": "speech"}
        assert app["appPermissions"]["entitlements"] == ["com.apple.security.application-groups", "keychain-access-groups"]
        assert app["versions"][0]["localizedDescription"] == "- ключ новый", app["versions"][0]
        assert app["versions"][1]["localizedDescription"] == "Вступление жирное и ссылка.", app["versions"][1]
        assert len(fetched) == 2

        fetched.clear()
        again = build(rels, json.loads(render(first)), fetch, ent)
        assert fetched == [] and render(again) == render(first)

        empty = build([release("v0.1.0", "", draft=True)], None, fetch, ent)
        assert empty["apps"] == []

    long = notes("слово " * 400)
    assert long.endswith("…") and len(long) <= DESCRIPTION_LIMIT + 1, len(long)
    print("selftest: ok")


def main(argv: list[str]) -> int:
    if argv == ["selftest"]:
        selftest()
        return 0
    if argv not in ([], ["--print"]):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    previous = json.loads(OUT.read_text(encoding="utf-8")) if OUT.exists() else None
    text = render(build(releases(), previous))
    if argv == ["--print"]:
        sys.stdout.write(text)
        return 0
    if not OUT.exists() or OUT.read_text(encoding="utf-8") != text:
        OUT.parent.mkdir(parents=True, exist_ok=True)
        OUT.write_text(text, encoding="utf-8")
        print(f"updated {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
