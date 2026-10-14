#!/usr/bin/env python3
"""Creates or updates the repository labels listed in tools/labels/labels.json.

    sync.py             apply them with gh (GH_TOKEN needs the issues write permission)
    sync.py --dry-run   print the gh commands instead

Idempotent: `gh label create --force` updates the colour and description of a label that exists.
Labels missing from the file are left alone. The names «good first issue» and «help wanted» stay
in English, because GitHub and the newcomer catalogues look for exactly these.
"""

from __future__ import annotations

import json
import os
import re
import shlex
import subprocess
import sys
from pathlib import Path

LABELS = Path(__file__).resolve().parent / "labels.json"
REPO = os.environ.get("LABELS_REPO") or os.environ.get("GITHUB_REPOSITORY") or "zigansh1n/velikiy-moguchiy"
COLOR = re.compile(r"^[0-9a-f]{6}$")


def load() -> list[dict]:
    labels = json.loads(LABELS.read_text(encoding="utf-8"))
    names = [label["name"] for label in labels]
    if len(set(n.lower() for n in names)) != len(names):
        raise SystemExit(f"{LABELS.name}: duplicate label names")
    for label in labels:
        if not COLOR.match(label["color"]):
            raise SystemExit(f"{LABELS.name}: {label['name']}: colour must be six lowercase hex digits")
        if len(label.get("description", "")) > 100:
            raise SystemExit(f"{LABELS.name}: {label['name']}: GitHub allows 100 characters of description")
    return labels


def main(argv: list[str]) -> int:
    if argv not in ([], ["--dry-run"]):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    for label in load():
        cmd = ["gh", "label", "create", label["name"], "--repo", REPO, "--force",
               "--color", label["color"], "--description", label.get("description", "")]
        if argv:
            print(shlex.join(cmd))
        else:
            subprocess.run(cmd, check=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
