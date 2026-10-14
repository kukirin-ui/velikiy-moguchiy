#!/usr/bin/env python3
"""Semantic review of the texts a pull request changes, by a language model behind an OpenAI-compatible API.

  python3 tools/text_review.py --base SHA --head SHA            review, print findings, exit 1 on high severity
  python3 tools/text_review.py --base SHA --head SHA --dry-run  only show what would be sent
  python3 tools/text_review.py --file NOTES.md --fail-on medium  every line of a generated text, e.g. release notes

The model reads the added lines of changed documents (.md, .txt, issue templates) and reports drafts, internal notes,
placeholders, personal data, AI attribution and statements that contradict the project's facts. The instructions are
in tools/text_review/prompt.md; known false positives are dropped by tools/text_review/allowlist.txt.

The model is configured by TEXT_REVIEW_ENDPOINT (chat completions URL), TEXT_REVIEW_MODEL and TEXT_REVIEW_TOKEN;
the free tier of Cloudflare Workers AI is enough (docs/AUTOMATION.md). Without any of them the review says so and
exits 0. TEXT_REVIEW_MAX_TOKENS (default 4096) is the answer limit sent with every request: a reasoning model spends
tokens on thinking first, and the endpoint's own default cuts the JSON off.
When the API is unreachable, refuses or is rate limited, the review warns and exits 0: the hard rules live in
privacy_guard.py, this check must never block the project for good.
With --comment (GITHUB_TOKEN, GITHUB_REPOSITORY, PR_NUMBER) the result goes to one PR comment updated in place.
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import privacy_guard  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
HERE = ROOT / "tools" / "text_review"
ENDPOINT = os.environ.get("TEXT_REVIEW_ENDPOINT", "")
MODEL = os.environ.get("TEXT_REVIEW_MODEL", "")
# keeps a request near 4000 input tokens plus the prompt; Cyrillic runs about 3 characters per token
CHUNK_CHARS = 12000
MAX_CHUNKS = int(os.environ.get("TEXT_REVIEW_MAX_CHUNKS") or 10)
VERBOSE = bool(os.environ.get("TEXT_REVIEW_VERBOSE"))
MAX_TOKENS = int(os.environ.get("TEXT_REVIEW_MAX_TOKENS") or 4096)
PAUSE = 7  # seconds between requests, to stay under free-tier rate limits
MAX_FINDINGS = 40
MARKER = "<!-- text-review -->"
SEVERITIES = ("high", "medium", "low")

REVIEWED = re.compile(r"\.(?:md|markdown|txt)$|^\.github/ISSUE_TEMPLATE/[^/]+\.ya?ml$", re.I)
# data, not prose: phrase lists, dictionaries, vocabularies, requirements
DATA_FILES = re.compile(r"(?:^|/)(?:phrases[^/]*|dictionary[^/]*|[^/]*_units|requirements[^/]*|paired)\.txt$", re.I)
HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@")


class Unavailable(Exception):
    """The model could not be asked; the review is skipped, not failed."""


@dataclass
class Section:
    path: str
    lines: list = field(default_factory=list)  # (new line number, added?, text)

    @property
    def added(self):
        return {no for no, add, _ in self.lines if add}

    def render(self):
        rows = [f"### {self.path}"]
        for no, add, text in self.lines:
            rows.append(f"{'+' if add else ' '}{no:5d}| {text}")
        return "\n".join(rows) + "\n"


@dataclass
class Finding:
    path: str
    line: int
    severity: str
    category: str
    quote: str
    problem: str
    fix: str = ""


def git(*args) -> str:
    return subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True, check=True).stdout


def reviewable(rel: str) -> bool:
    return (bool(REVIEWED.search(rel)) and not DATA_FILES.search(rel)
            and not privacy_guard.NOTICE_FILE.search(rel)
            and not any(rx.search(rel) for rx in privacy_guard.DOCS_EXEMPT))


def changed_files(base: str, head: str):
    out = git("diff", "--name-only", "--diff-filter=AMR", "-z", f"{base}...{head}")
    return [p for p in out.split("\0") if p and reviewable(p)]


def parse_diff(path: str, diff: str):
    """Sections of new-file lines around each hunk that adds something; deleted lines are not reviewed."""
    sections, cur, no = [], None, 0
    for line in diff.splitlines():
        m = HUNK.match(line)
        if m:
            if cur and cur.added:
                sections.append(cur)
            cur, no = Section(path), int(m.group(1))
            continue
        if cur is None or line.startswith("\\"):
            continue
        if line.startswith("+"):
            cur.lines.append((no, True, line[1:]))
            no += 1
        elif line.startswith(" "):
            cur.lines.append((no, False, line[1:]))
            no += 1
    if cur and cur.added:
        sections.append(cur)
    return sections


def whole_file(path: str) -> Section:
    """A file reviewed in full, as if every line were added."""
    text = Path(path).read_text(encoding="utf-8")
    return Section(path, [(no, True, line) for no, line in enumerate(text.splitlines(), 1) if line.strip()])


def split_section(sec: Section, limit: int):
    if len(sec.render()) <= limit:
        return [sec]
    parts, cur, size = [], Section(sec.path), 0
    for row in sec.lines:
        n = len(row[2]) + 10
        if cur.lines and size + n > limit:
            parts.append(cur)
            cur, size = Section(sec.path), 0
        cur.lines.append((row[0], row[1], row[2][:limit - 100]))
        size += n
    if cur.lines:
        parts.append(cur)
    return [p for p in parts if p.added]


def chunks(sections, limit=CHUNK_CHARS):
    out, cur, size = [], [], 0
    for sec in sections:
        for part in split_section(sec, limit):
            n = len(part.render())
            if cur and size + n > limit:
                out.append(cur)
                cur, size = [], 0
            cur.append(part)
            size += n
    if cur:
        out.append(cur)
    return out


def load_allowlist(path=HERE / "allowlist.txt"):
    rules = []
    for raw in Path(path).read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        glob, rx, why = (x.strip() for x in (line.split(" | ", 2) + ["", ""])[:3])
        rules.append((glob, re.compile(rx, re.I), why))
    return rules


def allowed(f: Finding, rules) -> bool:
    return any(fnmatch.fnmatch(f.path, glob) and rx.search(f.quote) for glob, rx, _ in rules)


def system_prompt(rules) -> str:
    text = (HERE / "prompt.md").read_text()
    known = "\n".join(f"- `{rx.pattern}` в `{glob}`: {why}" for glob, rx, why in rules)
    return text.replace("{{ALLOWLIST}}", known or "- нет")


def reply_text(raw: bytes):
    """(text, finish reason) of a chat completion. Reasoning models return the answer in `content` next to
    `reasoning`/`reasoning_content`; `content` may be null, a list of parts, or absent when the reasoning used up
    the token limit. Cloudflare's own shape (`result.response`) is accepted too."""
    data = json.loads(raw)
    if isinstance(data.get("result"), dict) and "choices" not in data:
        data = data["result"]
    if "choices" in data:
        choice = data["choices"][0]
        content = (choice.get("message") or {}).get("content")
        finish = choice.get("finish_reason")
    else:
        content, finish = data["response"], None
    if isinstance(content, list):
        content = "".join(str(p.get("text", "")) for p in content if isinstance(p, dict))
    return content or "", finish


def ask(system: str, user: str, token: str) -> str:
    """The model's answer. A reasoning model spends tokens on its thinking first and the endpoint's default limit
    is small, so the answer comes back cut off (finish reason `length`); that is retried once with twice the limit."""
    for limit in (MAX_TOKENS, MAX_TOKENS * 2):
        body = json.dumps({
            "model": MODEL,
            "temperature": 0,
            "max_tokens": limit,
            "reasoning_effort": "low",
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
        }).encode()
        text, finish = post(body, token)
        if finish != "length":
            return text
        if VERBOSE:
            print(f"text review: cut off at {limit} tokens")
    raise Unavailable(f"the answer was cut off at {limit} tokens (TEXT_REVIEW_MAX_TOKENS)")


def post(body: bytes, token: str):
    req = urllib.request.Request(ENDPOINT, data=body, method="POST", headers={
        "Authorization": f"Bearer {token}", "Content-Type": "application/json", "Accept": "application/json"})
    for attempt in (1, 2):
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                raw = r.read()
        except urllib.error.HTTPError as e:
            wait = e.headers.get("Retry-After") if e.headers else None
            if e.code == 429 and attempt == 1 and wait and wait.isdigit() and int(wait) <= 60:
                time.sleep(int(wait))
                continue
            raise Unavailable(f"HTTP {e.code}") from e
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            raise Unavailable(type(e).__name__) from e
        try:
            text, finish = reply_text(raw)
        except (ValueError, KeyError, IndexError, TypeError, AttributeError) as e:
            raise Unavailable(f"the API answered without a chat completion: {raw[:40]!r}") from e
        if VERBOSE:
            print(f"text review: {len(raw)} bytes, finish reason {finish!r}, answer {len(text)} chars")
        return text, finish
    raise Unavailable("rate limited")


def json_objects(reply: str):
    """Every JSON object in a reply, outermost first; models wrap them in fences or sentences and sometimes
    break the outer one (a stray bracket), in which case the objects inside it still come out."""
    out, pos = [], reply.find("{")
    while pos != -1:
        try:
            obj, end = json.JSONDecoder().raw_decode(reply[pos:])
        except ValueError:
            pos = reply.find("{", pos + 1)
            continue
        out.append(obj)
        pos = reply.find("{", pos + end)
    return out


def parse_findings(reply: str, chunk) -> list:
    """Findings the model reported for lines this chunk actually adds; anything else is dropped."""
    if VERBOSE:
        print("text review: reply starts with " + repr(reply[:1500]))
    objects = [o for o in json_objects(reply) if isinstance(o, dict)]
    if not objects:
        raise Unavailable("the model did not answer with JSON")
    items = []
    for obj in objects:
        if isinstance(obj.get("findings"), list):
            items += obj["findings"]
        elif "severity" in obj and "file" in obj:
            items.append(obj)
    added = {}
    for sec in chunk:
        added.setdefault(sec.path, set()).update(sec.added)
    if VERBOSE:
        print(f"text review: the model reported {len(items)} item(s), "
              f"added lines {({p: sorted(n) for p, n in added.items()})}")
    out = []
    for it in items:
        if not isinstance(it, dict):
            continue
        path = str(it.get("file", "")).strip()
        try:
            line = int(it.get("line", 0))
        except (TypeError, ValueError):
            continue
        sev = str(it.get("severity", "")).lower()
        if path not in added or line not in added[path] or sev not in SEVERITIES:
            if VERBOSE:
                print(f"text review: dropped {path!r}:{line} severity {sev!r}")
            continue
        out.append(Finding(path, line, sev, clean(it.get("category"), 40), clean(it.get("quote"), 200),
                           clean(it.get("problem"), 400), clean(it.get("fix"), 300)))
    return out


def clean(value, limit: int) -> str:
    """Model output goes into a PR comment: one line, no mentions, no HTML."""
    text = " ".join(str(value or "").split())[:limit]
    return text.replace("@", "@​").replace("<", "&lt;").replace(">", "&gt;")


def annotate(f: Finding):
    level = "error" if f.severity == "high" else "warning"
    msg = f"{f.category}: {f.problem}" + (f" Исправить: {f.fix}" if f.fix else "")
    msg = msg.replace("%", "%25").replace("\r", "").replace("\n", " ")
    print(f"::{level} file={f.path},line={f.line},title=Проверка текстов ({f.severity})::{msg}")


def report(findings, skipped, note="") -> str:
    rows = [MARKER, "### Проверка текстов", ""]
    if note:
        rows += [note, ""]
    if findings:
        rows += ["| Важность | Где | Что не так | Как исправить |", "|---|---|---|---|"]
        for f in findings:
            quote = f" «{f.quote}»" if f.quote else ""
            rows.append(f"| {f.severity} | `{f.path}:{f.line}` | {f.category}:{quote} {f.problem} | {f.fix} |"
                        .replace("\\", "\\\\"))
        rows += ["", "Замечания с важностью high не дают слить PR. Ложное срабатывание можно добавить в "
                 "`tools/text_review/allowlist.txt` с объяснением."]
    elif not note:
        rows.append("Замечаний нет.")
    if skipped:
        rows += ["", "Не проверено (лимит запросов): " + ", ".join(f"`{p}`" for p in skipped)]
    rows += ["", f"Модель: `{MODEL}`. Проверяются только добавленные строки."]
    return "\n".join(rows) + "\n"


def github(method: str, url: str, token: str, payload=None):
    req = urllib.request.Request(url, method=method, data=json.dumps(payload).encode() if payload else None, headers={
        "Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def post_comment(body: str, token: str, create: bool):
    repo, pr = os.environ.get("GITHUB_REPOSITORY"), os.environ.get("PR_NUMBER")
    if not (repo and pr):
        return
    api = f"https://api.github.com/repos/{repo}/issues"
    try:
        old = [c for c in github("GET", f"{api}/{pr}/comments?per_page=100", token)
               if MARKER in (c.get("body") or "")]
        if old:
            github("PATCH", f"{api}/comments/{old[-1]['id']}", token, {"body": body})
        elif create:
            github("POST", f"{api}/{pr}/comments", token, {"body": body})
    except (urllib.error.URLError, OSError, ValueError) as e:
        print(f"::warning title=Проверка текстов::комментарий в PR не опубликован ({type(e).__name__})")


def summary(text: str):
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a") as fh:
            fh.write(text)
    print(text)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base")
    ap.add_argument("--head")
    ap.add_argument("--file", action="append", default=[], help="review every line of this file (repeatable)")
    ap.add_argument("--fail-on", choices=SEVERITIES, default="high", help="the lowest severity that fails")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--comment", action="store_true")
    a = ap.parse_args(argv)
    if not a.file and not (a.base and a.head):
        ap.error("either --base and --head, or --file")

    sections = [whole_file(path) for path in a.file]
    if a.base and a.head:
        for path in changed_files(a.base, a.head):
            sections += parse_diff(path, git("diff", "-U3", f"{a.base}...{a.head}", "--", path))
    sections = [s for s in sections if s.added]
    if not sections:
        print("text review: no changed texts")
        return 0
    parts = chunks(sections)
    todo, rest = parts[:MAX_CHUNKS], parts[MAX_CHUNKS:]
    skipped = sorted({s.path for c in rest for s in c} - {s.path for c in todo for s in c})
    rules = load_allowlist()
    system = system_prompt(rules)
    if a.dry_run:
        for c in todo:
            print("".join(s.render() for s in c), "-" * 40, sep="\n")
        print(f"text review: {len(todo)} request(s), skipped: {skipped or 'none'}")
        return 0

    token = os.environ.get("TEXT_REVIEW_TOKEN", "")
    if not (ENDPOINT and MODEL and token):
        summary(f"{MARKER}\n### Проверка текстов\n\nМодель не настроена (TEXT_REVIEW_ENDPOINT, TEXT_REVIEW_MODEL, "
                "TEXT_REVIEW_TOKEN; см. docs/AUTOMATION.md), проверка пропущена. Жёсткие правила проверяет "
                "privacy_guard.py.\n")
        print("::notice title=Проверка текстов::модель не настроена, проверка пропущена")
        return 0
    findings, failed = [], None
    for i, c in enumerate(todo):
        if i:
            time.sleep(PAUSE)
        try:
            findings += parse_findings(ask(system, "".join(s.render() for s in c), token), c)
        except Unavailable as e:
            failed = str(e)
            skipped = sorted(set(skipped) | {s.path for cc in todo[i:] for s in cc})
            break
    findings = [f for f in findings if not allowed(f, rules)]
    findings.sort(key=lambda f: (SEVERITIES.index(f.severity), f.path, f.line))
    findings = findings[:MAX_FINDINGS]

    note = ""
    if failed:
        note = (f"Модель недоступна ({failed}), часть файлов не проверена. Это не ошибка PR: "
                "жёсткие правила проверяет privacy_guard.py.")
        print(f"::warning title=Проверка текстов::модель недоступна ({failed}); проверка не блокирует PR")
    for f in findings:
        annotate(f)
    body = report(findings, skipped, note)
    summary(body)
    gh_token = os.environ.get("GITHUB_TOKEN", "")
    if a.comment and gh_token:
        post_comment(body, gh_token, create=bool(findings or failed))
    failing = SEVERITIES[:SEVERITIES.index(a.fail_on) + 1]
    return 1 if any(f.severity in failing for f in findings) else 0


if __name__ == "__main__":
    sys.exit(main())
