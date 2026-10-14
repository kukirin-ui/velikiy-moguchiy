#!/usr/bin/env python3
"""Fails when a dependency's licence is not in tools/licenses/allowlist.toml.

    check.py rust      cargo-deny over mac/ (needs cargo-deny on PATH)
    check.py python    resolved lipread/ and federated/ packages, licences from PyPI
    check.py selftest  offline tests of the licence parser
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
import tempfile
import tomllib
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ALLOWLIST = ROOT / "tools/licenses/allowlist.toml"
COPYLEFT = re.compile(r"\b(A?GPL|LGPL|SSPL|GNU)", re.I)

# (label, uv pip compile arguments). lipread runs only on Apple Silicon and is
# pinned by uv.lock; the federated server also runs on Linux (Hugging Face Space).
PYTHON_SETS = [
    ("lipread (macOS arm64)", "lipread-lock", ["--python-platform", "aarch64-apple-darwin", "--python-version", "3.13"]),
    ("federated (macOS arm64, all extras)", "federated/pyproject.toml",
     ["--all-extras", "--python-platform", "aarch64-apple-darwin", "--python-version", "3.13"]),
    ("federated (Linux, server)", "federated/pyproject.toml",
     ["--python-platform", "x86_64-manylinux_2_28", "--python-version", "3.11"]),
]

CLASSIFIERS = {
    "Apache Software License": "Apache-2.0",
    "BSD License": "BSD-3-Clause",
    "ISC License (ISCL)": "ISC",
    "MIT License": "MIT",
    "MIT No Attribution License (MIT-0)": "MIT-0",
    "Mozilla Public License 2.0 (MPL 2.0)": "MPL-2.0",
    "Python Software Foundation License": "PSF-2.0",
    "The Unlicense (Unlicense)": "Unlicense",
    "zlib/libpng License": "Zlib",
    "Historical Permission Notice and Disclaimer (HPND)": "HPND",
    "Boost Software License 1.0 (BSL-1.0)": "BSL-1.0",
    "CC0 1.0 Universal (CC0 1.0) Public Domain Dedication": "CC0-1.0",
}

# Free-text `License:` values seen on PyPI that are not SPDX ids.
ALIASES = {
    "apache 2.0": "Apache-2.0",
    "apache license 2.0": "Apache-2.0",
    "apache license, version 2.0": "Apache-2.0",
    "apache software license": "Apache-2.0",
    "apache": "Apache-2.0",
    "apache2": "Apache-2.0",
    "bsd": "BSD-3-Clause",
    "bsd license": "BSD-3-Clause",
    "3-clause bsd license": "BSD-3-Clause",
    "new bsd license": "BSD-3-Clause",
    "mit license": "MIT",
    "the mit license": "MIT",
    "psf": "PSF-2.0",
    "psf license": "PSF-2.0",
    "mpl 2.0": "MPL-2.0",
    "isc license": "ISC",
}


def load_allowlist() -> dict:
    with ALLOWLIST.open("rb") as f:
        return tomllib.load(f)


def tokenize(expr: str) -> list[str]:
    return re.findall(r"\(|\)|[^\s()]+", expr)


def satisfiable(expr: str, allowed: set[str]) -> bool:
    """SPDX expression check: OR needs one allowed side, AND needs both."""
    tokens = tokenize(expr)
    pos = 0

    def atom() -> bool:
        nonlocal pos
        if pos >= len(tokens):
            raise ValueError(expr)
        if tokens[pos] == "(":
            pos += 1
            value = disjunction()
            if pos >= len(tokens) or tokens[pos] != ")":
                raise ValueError(expr)
            pos += 1
            return value
        license_id = tokens[pos]
        pos += 1
        if pos < len(tokens) and tokens[pos].upper() == "WITH":
            license_id = f"{license_id} WITH {tokens[pos + 1]}"
            pos += 2
        return license_id in allowed or license_id.rstrip("+") in allowed

    def conjunction() -> bool:
        nonlocal pos
        value = atom()
        while pos < len(tokens) and tokens[pos].upper() == "AND":
            pos += 1
            value = atom() and value
        return value

    def disjunction() -> bool:
        nonlocal pos
        value = conjunction()
        while pos < len(tokens) and tokens[pos].upper() == "OR":
            pos += 1
            value = conjunction() or value
        return value

    result = disjunction()
    if pos != len(tokens):
        raise ValueError(expr)
    return result


def satisfiable_or_false(expr: str, allowed: set[str]) -> bool:
    try:
        return satisfiable(expr, allowed)
    except (ValueError, IndexError):
        return False


SPDX_LIKE = re.compile(r"^[\w.+-]+( (AND|OR|WITH) [\w.+-]+)*$")


def license_of(info: dict) -> str | None:
    """SPDX expression for a PyPI `info` block, or None when it cannot be told."""
    if info.get("license_expression"):
        return info["license_expression"]
    # An unmapped classifier is passed on as its text, which no allowlist matches.
    from_classifiers = [
        CLASSIFIERS.get(c.split(" :: ")[-1], c.split(" :: ")[-1])
        for c in info.get("classifiers") or []
        if c.startswith("License :: ") and c != "License :: OSI Approved"
    ]
    if from_classifiers:
        return " AND ".join(sorted(set(from_classifiers)))
    text = (info.get("license") or "").strip()
    if not text or "\n" in text:
        return None
    if text.lower() in ALIASES:
        return ALIASES[text.lower()]
    return text if SPDX_LIKE.match(text) else None


def run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=True, text=True, capture_output=True, cwd=ROOT, **kwargs)


def resolve(source: str, args: list[str]) -> list[tuple[str, str]]:
    with tempfile.TemporaryDirectory() as tmp:
        if source == "lipread-lock":
            reqs = Path(tmp) / "lipread.txt"
            reqs.write_text(run(["uv", "export", "--frozen", "--no-hashes", "--no-emit-project",
                                 "--no-header", "--directory", "lipread"]).stdout)
            source = str(reqs)
        out = run(["uv", "pip", "compile", source, *args, "--no-header", "--no-annotate", "-q"]).stdout
    pins = []
    for line in out.splitlines():
        name, sep, version = line.strip().partition("==")
        if sep:
            pins.append((name.lower(), version))
    return pins


def pypi_info(pin: tuple[str, str]) -> dict:
    name, version = pin
    url = f"https://pypi.org/pypi/{name}/{version}/json"
    for attempt in range(3):
        try:
            with urllib.request.urlopen(url, timeout=30) as response:
                return json.load(response)["info"]
        except OSError:
            if attempt == 2:
                raise
    raise AssertionError


def check_python() -> int:
    config = load_allowlist()
    allowed = set(config["allow"])
    clarify = config.get("python", {}).get("clarify", {})
    exceptions = config.get("python", {}).get("exceptions", {})

    pins: set[tuple[str, str]] = set()
    for label, source, args in PYTHON_SETS:
        found = resolve(source, args)
        print(f"{label}: {len(found)} пакетов")
        pins.update(found)

    with ThreadPoolExecutor(max_workers=16) as pool:
        infos = dict(zip(sorted(pins), pool.map(pypi_info, sorted(pins))))

    problems = []
    for (name, version), info in infos.items():
        expr = clarify.get(name) or license_of(info)
        if name in exceptions:
            print(f"  {name} {version}: исключение — {exceptions[name].get('reason', '')}")
            continue
        if expr is None:
            raw = (info.get("license") or "").strip().splitlines()
            hint = raw[0][:80] if raw else "не указана"
            problems.append(f"{name} {version}: лицензия не распознана ({hint})")
            continue
        if not satisfiable_or_false(expr, allowed):
            kind = "копилефт" if COPYLEFT.search(expr) else "не в списке разрешённых"
            problems.append(f"{name} {version}: {expr} — {kind}")

    print(f"Проверено пакетов Python: {len(infos)}")
    return report(problems)


def check_rust() -> int:
    config = load_allowlist()
    exceptions = config.get("rust", {}).get("exceptions", {})
    deny = {
        "licenses": {
            "allow": config["allow"],
            "confidence-threshold": 0.9,
            "unused-allowed-license": "allow",
            "exceptions": [{"crate": name, "allow": [entry["license"]]} for name, entry in exceptions.items()],
        },
    }
    with tempfile.NamedTemporaryFile("w", suffix=".toml", delete=False) as f:
        f.write(to_toml(deny))
        deny_path = f.name
    result = subprocess.run(
        ["cargo", "deny", "--manifest-path", "mac/Cargo.toml", "--all-features",
         "--config", deny_path, "check", "licenses"],
        cwd=ROOT,
    )
    if result.returncode:
        print("\nЛицензия зависимости Rust не в tools/licenses/allowlist.toml (подробности выше).")
    return result.returncode


def to_toml(data: dict) -> str:
    lines = []
    for table, values in data.items():
        lines.append(f"[{table}]")
        for key, value in values.items():
            lines.append(f"{key} = {json.dumps(value)}")
    return "\n".join(lines) + "\n"


def report(problems: list[str]) -> int:
    if not problems:
        print("Все лицензии разрешены.")
        return 0
    print("\nНедопустимые или неизвестные лицензии:")
    for line in problems:
        print(f"  - {line}")
    print("\nЗамените зависимость. Если лицензия на самом деле разрешительная, но PyPI её не называет,"
          "\nдобавьте пакет в [python.clarify] файла tools/licenses/allowlist.toml.")
    return 1


def selftest() -> int:
    allowed = {"MIT", "Apache-2.0", "BSD-3-Clause", "Apache-2.0 WITH LLVM-exception"}
    assert satisfiable("MIT", allowed)
    assert satisfiable("MIT OR LGPL-2.1-or-later", allowed)
    assert not satisfiable("MIT AND GPL-3.0-only", allowed)
    assert satisfiable("(MIT OR GPL-2.0-only) AND Apache-2.0", allowed)
    assert satisfiable("Apache-2.0 WITH LLVM-exception OR MIT", allowed)
    assert not satisfiable("AGPL-3.0-or-later", allowed)
    assert license_of({"license_expression": "BSD-3-Clause"}) == "BSD-3-Clause"
    assert license_of({"classifiers": ["License :: OSI Approved :: MIT License"]}) == "MIT"
    gpl = license_of({"classifiers": ["License :: OSI Approved :: GNU General Public License v3 (GPLv3)"]})
    assert COPYLEFT.search(gpl) and not satisfiable_or_false(gpl, allowed)
    assert license_of({"license": "Apache License, Version 2.0"}) == "Apache-2.0"
    assert license_of({"license": "Copyright (c) 2020\nPermission is hereby granted"}) is None
    assert license_of({"license": ""}) is None
    print("selftest: ok")
    return 0


if __name__ == "__main__":
    commands = {"python": check_python, "rust": check_rust, "selftest": selftest}
    if len(sys.argv) != 2 or sys.argv[1] not in commands:
        sys.exit(__doc__)
    sys.exit(commands[sys.argv[1]]())
