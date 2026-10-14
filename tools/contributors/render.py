"""Renders the contributors table in README.md from contributors.json.

    python3 tools/contributors/render.py           # rewrite the table between the markers
    python3 tools/contributors/render.py --check   # exit 1 if README.md is out of date

The table sits between <!-- contributors:start --> and <!-- contributors:end -->; edit contributors.json, never the
table. Sorted by accepted weight updates, then training steps, then hours of data, then login. No dependencies.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
START, END = "<!-- contributors:start -->", "<!-- contributors:end -->"
LOGIN = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38}$")
FIELDS = {"github", "name", "data_hours", "training_steps", "accepted_updates"}


def load(path):
    data = json.loads(path.read_text(encoding="utf-8"))
    people = data.get("contributors")
    if not isinstance(people, list):
        raise ValueError("contributors.json: 'contributors' must be a list")
    seen = set()
    for i, p in enumerate(people):
        where = f"contributors[{i}]"
        if not isinstance(p, dict) or set(p) - FIELDS:
            raise ValueError(f"{where}: unknown fields {sorted(set(p) - FIELDS) if isinstance(p, dict) else p!r}")
        if not isinstance(p.get("github"), str) or not LOGIN.match(p["github"]):
            raise ValueError(f"{where}: 'github' must be a GitHub login")
        if p["github"].lower() in seen:
            raise ValueError(f"{where}: duplicate login {p['github']}")
        seen.add(p["github"].lower())
        for key, kind in (("data_hours", (int, float)), ("training_steps", int), ("accepted_updates", int)):
            v = p.get(key)
            if isinstance(v, bool) or not isinstance(v, kind) or v < 0:
                raise ValueError(f"{where}: '{key}' must be a non-negative number")
        if "name" in p and (not isinstance(p["name"], str) or set(p["name"]) & set("|[]<>\n")
                            or len(p["name"]) > 80):
            raise ValueError(f"{where}: 'name' must be a short single line without | [ ] < >")
    return people


def hours(v):
    """1.5 -> «1,5», as Russian writes decimals."""
    return f"{v:g}".replace(".", ",")


def count(n):
    """12345 -> «12 345», grouped with a narrow no-break space."""
    return f"{n:,}".replace(",", " ")


def table(people):
    rows = ["| Участник | Часы данных | Шаги обучения | Принятые обновления весов |", "|---|---:|---:|---:|"]
    ordered = sorted(people, key=lambda p: (-p["accepted_updates"], -p["training_steps"], -p["data_hours"],
                                            p["github"].lower()))
    for p in ordered:
        label = p.get("name") or p["github"]
        rows.append(f"| [{label}](https://github.com/{p['github']}) | {hours(p['data_hours'])} | "
                    f"{count(p['training_steps'])} | {count(p['accepted_updates'])} |")
    return "\n".join(rows)


def render(readme_text, people):
    i, j = readme_text.find(START), readme_text.find(END)
    if i < 0 or j < i:
        raise ValueError("README.md: contributors markers not found")
    return readme_text[: i + len(START)] + "\n" + table(people) + "\n" + readme_text[j:]


def main(argv):
    people = load(ROOT / "contributors.json")
    readme = ROOT / "README.md"
    current = readme.read_text(encoding="utf-8")
    updated = render(current, people)
    if "--check" in argv:
        if updated != current:
            print("README.md: the contributors table is out of date; run python3 tools/contributors/render.py")
            return 1
        print("README.md: contributors table is up to date")
        return 0
    if updated != current:
        readme.write_text(updated, encoding="utf-8")
        print("README.md: contributors table updated")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
