#!/usr/bin/env python3
"""Decides what the next release is and writes its Russian release notes (.github/workflows/release.yml).

  python3 tools/release/plan.py auto --notes OUT.md [--changes OUT.md] [--bump auto|patch|minor|major]
                                     [--version X.Y.Z] [--force] [--dry-run]
  python3 tools/release/plan.py tag vX.Y.Z --notes OUT.md [--changes OUT.md]
  python3 tools/release/plan.py selftest

auto: the daily automatic release. Takes the newest commit of main whose push checks all finished green (main is
walked back from its tip, so a commit whose checks still run or failed is never released), and releases it when it
changes a product since the last v* tag: mac/, ios/, android/, windows/, or the lip reading and «Помочь обучить»
code that the Mac app bundles. Documentation and tests alone do not make a release.
The version is the last tag with the patch number bumped; «[minor]» or «[major]» in a commit message or in the
title of a merged PR bumps that part instead. Without any v* tag the first version is FIRST.

tag: a tag pushed by hand (the draft path); only the notes, from the previous stable tag to this one.

Notes are .github/release-notes.md with {{VERSION}} and {{CHANGES}} filled in: the titles of the PRs merged since
the previous tag, grouped by product. Results go to $GITHUB_OUTPUT (release, version, tag, sha, prerelease, reason)
when it is set. GitHub is read through `gh api`, so GH_TOKEN must be set.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
TEMPLATE = ROOT / ".github" / "release-notes.md"
FIRST = "0.1.0"
BRANCH = "main"
MAX_WALK = 50  # commits of main checked for green checks, newest first
MAX_ITEMS = 80

PRODUCT = re.compile(
    r"^(?:mac|ios|android|windows)/"
    r"|^lipread/[^/]+\.(?:py|toml|lock|sha256)$"
    r"|^federated/(?:client|protocol)/"
    r"|^tools/mem_guard\.py$")
NOT_PRODUCT = re.compile(r"\.md$|(?:^|/)(?:tests?|androidTest|Tests)/", re.I)
GREEN = {"success", "skipped", "neutral"}
SEMVER = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)(-[0-9A-Za-z.-]+)?$")
BUMP_TAG = re.compile(r"\[(minor|major)\]", re.I)

# first path component -> group heading; anything else is «Проект»
GROUPS = (
    ("mac", "Mac"),
    ("ios", "iPhone"),
    ("android", "Android"),
    ("windows", "Windows"),
    ("lipread", "Чтение по губам"),
    ("federated", "«Помочь обучить»"),
)
OTHER = "Проект"
PREFIX_ALIASES = {"mac": {"mac", "macos"}, "ios": {"ios", "iphone"}, "lipread": {"lipread", "губы"}}


def git(*args) -> str:
    return subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True, check=True).stdout


def gh_api(path: str):
    out = subprocess.run(["gh", "api", "-H", "Accept: application/vnd.github+json", path],
                         capture_output=True, text=True, check=True).stdout
    return json.loads(out)


def parse(version: str):
    m = SEMVER.match(version)
    if not m:
        raise ValueError(f"not a version: {version}")
    return int(m.group(1)), int(m.group(2)), int(m.group(3)), m.group(4) or ""


def bump(version: str, part: str) -> str:
    major, minor, patch, _ = parse(version)
    if part == "major":
        return f"{major + 1}.0.0"
    if part == "minor":
        return f"{major}.{minor + 1}.0"
    return f"{major}.{minor}.{patch + 1}"


def bump_part(texts) -> str:
    parts = {m.group(1).lower() for text in texts for m in BUMP_TAG.finditer(text or "")}
    return "major" if "major" in parts else "minor" if "minor" in parts else "patch"


def stable_tags(tags, before: str | None = None):
    """v* tags without a -suffix, oldest first; with `before`, only those lower than it."""
    out = []
    for tag in tags:
        try:
            v = parse(tag)
        except ValueError:
            continue
        if tag.startswith("v") and not v[3] and (before is None or v[:3] < parse(before)[:3]):
            out.append((v[:3], tag))
    return [tag for _, tag in sorted(out)]


def is_product(path: str) -> bool:
    return bool(PRODUCT.search(path)) and not NOT_PRODUCT.search(path)


def green(runs) -> bool | None:
    """True when every push run finished green, False when one failed, None when that is not known yet.

    A cancelled run is unknown, not failed: a newer push to main cancels the checks of the older one."""
    if any(r.get("conclusion") not in GREEN | {"cancelled", None} for r in runs):
        return False
    if not runs or any(r.get("status") != "completed" or r.get("conclusion") == "cancelled" for r in runs):
        return None
    return True


def push_runs(repo: str, sha: str, api=gh_api):
    data = api(f"repos/{repo}/actions/runs?head_sha={sha}&event=push&branch={BRANCH}&per_page=100")
    return data.get("workflow_runs", [])


def newest_green(repo: str, commits, api=gh_api):
    """The newest commit whose push checks are all green, with a log of why newer ones were passed over."""
    log = []
    for sha in commits[:MAX_WALK]:
        state = green(push_runs(repo, sha, api))
        if state:
            return sha, log
        log.append(f"{sha[:9]}: " + ("a check failed" if state is False else "checks not finished or cancelled"))
    return None, log


def group_of(files) -> str:
    counts = {}
    for path in files:
        key = path.split("/", 1)[0]
        if key == "tools" and path == "tools/mem_guard.py":
            key = "lipread"
        if any(key == k for k, _ in GROUPS):
            counts[key] = counts.get(key, 0) + 1
    if not counts:
        return OTHER
    key = max(counts, key=lambda k: (counts[k], -[g for g, _ in GROUPS].index(k)))
    return dict(GROUPS)[key]


def clean_title(title: str, group: str) -> str:
    title = BUMP_TAG.sub("", title or "").strip()
    m = re.match(r"^([^:]{1,30}):\s+(.+)$", title)
    if m:
        prefix = m.group(1).strip().lower()
        key = next((k for k, label in GROUPS if label == group), "")
        if prefix in PREFIX_ALIASES.get(key, {key}) or prefix == group.lower():
            title = m.group(2).strip()
    title = " ".join(title.split())
    return title[:1].upper() + title[1:]


def is_bot(pr: dict) -> bool:
    user = pr.get("user") or {}
    return user.get("type") == "Bot" or str(user.get("login", "")).endswith("[bot]")


def merged_prs(repo: str, commits: set, since: str | None, api=gh_api):
    """PRs into main whose merge commit is in `commits`; pages stop once PRs were last updated before `since`."""
    out, page = [], 1
    while True:
        batch = api(f"repos/{repo}/pulls?state=closed&base={BRANCH}&sort=updated&direction=desc"
                    f"&per_page=100&page={page}")
        for pr in batch:
            if pr.get("merged_at") and pr.get("merge_commit_sha") in commits:
                out.append(pr)
        if len(batch) < 100 or (since and batch[-1].get("updated_at", "") < since):
            break
        page += 1
    return sorted(out, key=lambda pr: pr["merged_at"])


def pr_files(repo: str, number: int, api=gh_api):
    files, page = [], 1
    while page <= 30:
        batch = api(f"repos/{repo}/pulls/{number}/files?per_page=100&page={page}")
        files += [f["filename"] for f in batch]
        if len(batch) < 100:
            break
        page += 1
    return files


def changes(prs, files_of, repo: str, previous: str | None, tag: str) -> str:
    groups, deps = {}, []
    for pr in prs:
        if is_bot(pr):
            deps.append(pr["number"])
            continue
        group = group_of(files_of(pr["number"]))
        groups.setdefault(group, []).append(f"- {clean_title(pr['title'], group)} (#{pr['number']})")
    rows = ["## Что нового", ""]
    order = [label for _, label in GROUPS] + [OTHER]
    shown = 0
    for label in order:
        items = groups.get(label, [])
        if not items:
            continue
        room = MAX_ITEMS - shown
        if room <= 0:
            break
        rows += [f"**{label}**", ""] + items[:room] + [""]
        shown += min(len(items), room)
    total = sum(len(v) for v in groups.values())
    if total > shown:
        rows += [f"И ещё изменений: {total - shown}.", ""]
    if not total:
        rows += ["Исправления и мелкие улучшения.", ""]
    if deps:
        rows += ["Обновлены зависимости: " + ", ".join(f"#{n}" for n in deps) + ".", ""]
    if previous:
        rows += [f"Все изменения: https://github.com/{repo}/compare/{previous}...{tag}", ""]
    return "\n".join(rows).rstrip() + "\n"


def render(version: str, changes_md: str, template: Path = TEMPLATE) -> str:
    text = template.read_text(encoding="utf-8")
    if "{{CHANGES}}" not in text:
        raise SystemExit(f"{template} has no {{{{CHANGES}}}} line")
    return text.replace("{{VERSION}}", version).replace("{{CHANGES}}", changes_md.rstrip())


def prs_between(repo: str, previous: str | None, sha: str, api=gh_api):
    commits = set(git("rev-list", f"{previous}..{sha}" if previous else sha).split())
    since = to_utc(git("log", "-1", "--format=%cI", previous).strip()) if previous else None
    return merged_prs(repo, commits, since, api)


def to_utc(iso: str) -> str:
    """GitHub compares updated_at as text in UTC (Z); git prints the committer's offset."""
    from datetime import datetime, timezone
    return datetime.fromisoformat(iso).astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def plan_auto(a, repo: str, api=gh_api) -> dict:
    tags = stable_tags(git("tag", "-l", "v*").split())
    previous = tags[-1] if tags else None
    head = git("rev-parse", f"origin/{BRANCH}").strip()
    stop = [f"^{previous}"] if previous else []
    commits = git("rev-list", "--first-parent", f"--max-count={MAX_WALK}", head, *stop).split()
    if not commits:
        return {"release": False, "reason": f"main has nothing new since {previous}"}
    sha, log = newest_green(repo, commits, api)
    for line in log:
        print(f"passed over {line}")
    if not sha:
        return {"release": False, "reason": "no commit since the last release has all its checks green yet"}
    rng = f"{previous}..{sha}" if previous else sha
    product = [p for p in git("diff", "--name-only", f"{previous}..{sha}").splitlines() if is_product(p)] \
        if previous else ["(first release)"]
    if not product and not a.force:
        return {"release": False, "sha": sha, "reason": f"no product changes since {previous}"}
    prs = prs_between(repo, previous, sha, api)
    if a.version:
        version = a.version.removeprefix("v")
        parse(version)
        if previous and parse(version)[:3] <= parse(previous)[:3]:
            raise SystemExit(f"{version} is not newer than {previous}")
    elif not previous:
        version = FIRST
    else:
        part = a.bump
        if part == "auto":
            part = bump_part(git("log", "--format=%B%x00", rng).split("\0") + [pr["title"] for pr in prs])
        version = bump(previous, part)
    tag = f"v{version}"
    if git("tag", "-l", tag).strip():
        raise SystemExit(f"{tag} already exists")
    new = changes(prs, lambda n: pr_files(repo, n, api), repo, previous, tag)
    return {"release": True, "version": version, "tag": tag, "sha": sha, "previous": previous or "",
            "prerelease": bool(parse(version)[3]), "changes": new, "notes": render(version, new),
            "reason": f"{len(product)} product file(s) changed since {previous or 'the start'}"}


def plan_tag(tag: str, repo: str, api=gh_api) -> dict:
    version = tag.removeprefix("v")
    parse(version)
    sha = git("rev-parse", f"{tag}^{{commit}}").strip()
    older = stable_tags(git("tag", "-l", "v*").split(), before=version)
    previous = older[-1] if older else None
    prs = prs_between(repo, previous, sha, api)
    new = changes(prs, lambda n: pr_files(repo, n, api), repo, previous, tag)
    return {"release": True, "version": version, "tag": tag, "sha": sha, "previous": previous or "",
            "prerelease": bool(parse(version)[3]), "changes": new, "notes": render(version, new),
            "reason": "tag pushed by hand"}


def write_outputs(result: dict):
    path = os.environ.get("GITHUB_OUTPUT")
    if not path:
        return
    with open(path, "a") as fh:
        for key in ("release", "version", "tag", "sha", "previous", "prerelease", "reason"):
            value = result.get(key, "")
            fh.write(f"{key}={str(value).lower() if isinstance(value, bool) else value}\n")


def selftest():
    assert bump("0.1.0", "patch") == "0.1.1" and bump("0.1.9", "minor") == "0.2.0" and bump("1.2.3", "major") == "2.0.0"
    assert bump_part(["fix", "Окно [minor]"]) == "minor" and bump_part(["[MAJOR] x", "[minor]"]) == "major"
    assert bump_part(["minor fix"]) == "patch"
    assert stable_tags(["v0.2.0", "v0.10.0", "v0.3.0-rc1", "mac-v1.0.0", "v0.9.1"]) == ["v0.2.0", "v0.9.1", "v0.10.0"]
    assert stable_tags(["v0.2.0", "v0.3.0"], before="0.3.0") == ["v0.2.0"]
    for path in ("mac/MacApp/x.m", "ios/App/y.swift", "android/app/build.gradle.kts", "windows/app/src/main.rs",
                 "lipread/lips_service.py", "lipread/uv.lock", "federated/client/train.py", "tools/mem_guard.py"):
        assert is_product(path), path
    for path in ("mac/README.md", "docs/AUTOMATION.md", "lipread/harvester/harvest.py", "lipread/tests/test_x.py",
                 "android/app/src/androidTest/K.kt", "federated/worker/src/index.js", ".github/workflows/tests.yml"):
        assert not is_product(path), path
    assert green([]) is None
    assert green([{"status": "completed", "conclusion": "success"}, {"status": "in_progress"}]) is None
    assert green([{"status": "completed", "conclusion": "failure"}, {"status": "in_progress"}]) is False
    assert green([{"status": "completed", "conclusion": "cancelled"}]) is None
    assert green([{"status": "completed", "conclusion": "success"}, {"status": "completed", "conclusion": "skipped"}])
    assert group_of(["mac/a", "mac/b", "docs/x.md"]) == "Mac" and group_of(["docs/x.md"]) == OTHER
    assert group_of(["ios/a", "android/b"]) == "iPhone"
    assert clean_title("mac: окно «Начало работы» [minor]", "Mac") == "Окно «Начало работы»"
    assert clean_title("Клавиатура iPhone: эмодзи", "iPhone") == "Клавиатура iPhone: эмодзи"
    assert clean_title("iPhone: регион DashScope", "iPhone") == "Регион DashScope"
    assert clean_title("«Помочь обучить»: экзамен", "«Помочь обучить»") == "Экзамен"
    print("plan.py selftest: ok")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    auto = sub.add_parser("auto")
    auto.add_argument("--notes", required=True)
    auto.add_argument("--changes", help="also write the generated «Что нового» section alone here")
    auto.add_argument("--bump", choices=("auto", "patch", "minor", "major"), default="auto")
    auto.add_argument("--version", default="")
    auto.add_argument("--force", action="store_true", help="release even without product changes")
    auto.add_argument("--dry-run", action="store_true", help="show the plan, never ask for a release")
    tag = sub.add_parser("tag")
    tag.add_argument("tag")
    tag.add_argument("--notes", required=True)
    tag.add_argument("--changes")
    sub.add_parser("selftest")
    a = ap.parse_args(argv)
    if a.cmd == "selftest":
        selftest()
        return 0
    repo = os.environ.get("GITHUB_REPOSITORY") or "zigansh1n/velikiy-moguchiy"
    result = plan_auto(a, repo) if a.cmd == "auto" else plan_tag(a.tag, repo)
    if result.get("notes"):
        Path(a.notes).write_text(result["notes"], encoding="utf-8")
        if a.changes:
            Path(a.changes).write_text(result["changes"], encoding="utf-8")
    if a.cmd == "auto" and a.dry_run and result["release"]:
        result = dict(result, release=False, reason="dry run: " + result["reason"])
    shown = {k: v for k, v in result.items() if k not in ("notes", "changes")}
    print(json.dumps(shown, ensure_ascii=False, indent=2))
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as fh:
            title = f"Выпуск {result['tag']}" if result.get("tag") else "Выпуска не будет"
            fh.write(f"### {title}\n\n{result['reason']}\n\n")
            fh.write(result.get("changes", ""))
    write_outputs(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
