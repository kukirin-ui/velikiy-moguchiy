#!/usr/bin/env python3
"""Privacy guard: fails when the repository would publish secrets, personal data or collected-data lists.

  python3 tools/privacy_guard.py                  every tracked file (what CI runs on each push and PR)
  python3 tools/privacy_guard.py --staged         the files staged for the next commit (a pre-commit hook)
  python3 tools/privacy_guard.py FILE...          only these files
  python3 tools/privacy_guard.py --commits A..B   also the commit messages in A..B (authorship trailers)
  python3 tools/privacy_guard.py --hash WORD      the hash to add to NAMES for a new name or identifier

Checks:
  secret      API keys and tokens (DashScope/OpenAI sk-, GitHub gh*_, AWS AKIA, Hugging Face hf_, Slack xox*-, private
              key blocks)
  path        home folders (/Users/<name>, /home/<name>, C:\\Users\\<name>)
  email       e-mail addresses, except in license notices and reserved or no-reply domains
  identifier  the author's personal identifiers (bundle ids, team prefixes, user name)
  name        names and handles of people whose videos were collected, in any grammatical form
  data-list   lists of collected videos or channels and raw provider results, by file name or by content
  media       images, video and audio outside the UI and design folders (MEDIA_DIRS)
  draft       a document that is not ready for publication: «черновик» in its title or banner, notes to a lawyer or
              «удалить из публикуемого», «не публиковать», TODO/FIXME/TBD (DOCS files only, code spans skipped)
  placeholder square brackets with Cyrillic or TBD that are not a link, a checkbox or code (DOCS files only)
  trailer     co-author or tool attribution trailers in commit messages (--commits)
  ai-author   an AI tool as the author or committer of a commit (--commits)

Names and identifiers are kept only as salted hashes, so this file does not publish them. Matching is per word:
words are split at non-letters and at camelCase humps, lowercased, ё read as е, and each word's prefix is hashed.
Extra local patterns (one regex per line, never committed) can come from --extra FILE or $PRIVACY_GUARD_EXTRA.
Findings print as path:line and the check name, never the matched text, so CI logs do not repeat it either.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import re
import subprocess
import sys
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parent.parent
SALT = b"velikiy-moguchiy-privacy-guard-v1:"

# (hash of the word prefix, prefix length, letters allowed after it or None for any, check)
NAMES = (
    ("b99131c3df3802ad873a", 9, None, "identifier"),
    ("914f96c8340e6a60a077", 8, None, "identifier"),
    ("54d332c15fa12326c150", 16, None, "identifier"),
    ("efb92b9fb324b1b6709b", 3, 2, "name"),
    ("433fc7bfd242468747ba", 4, None, "name"),
    ("0f07170973e7b8d6eb2c", 4, 0, "name"),
    ("b93448321959d179fb59", 8, None, "name"),
    ("d5ce8b9eff6599a49c2b", 8, None, "name"),
    ("19c86efad0a893e6d197", 8, None, "name"),
    ("1947b0d2334c7c78cd51", 9, None, "name"),
    ("18c708ff1c749d9ecf0c", 9, None, "name"),
    ("ae29a10399441a9a610c", 9, None, "name"),
    ("2e327f1653e67682c768", 6, None, "name"),
    ("bbb4f02f371f0d14cf4f", 6, None, "name"),
    ("6beb59299a137c4aa901", 9, None, "name"),
)

SECRETS = (
    re.compile(r"\bsk-(?:ant-|proj-)?[A-Za-z0-9_-]{20,}"),
    re.compile(r"\bgh[pousr]_[A-Za-z0-9]{30,}"),
    re.compile(r"\bgithub_pat_[A-Za-z0-9_]{40,}"),
    re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"),
    re.compile(r"\bhf_[A-Za-z0-9]{30,}"),
    re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}"),
    re.compile(r"-----BEGIN (?:[A-Z]+ )?PRIVATE KEY(?: BLOCK)?-----"),
)
# a key-shaped value that is plainly a stand-in
PLACEHOLDER = re.compile(r"placeholder|example|dummy|test|fake|x{6,}|your|redacted|\.\.\.|<", re.I)

HOME = re.compile(r"(?:/Users/|/home/|[A-Za-z]:\\+Users\\+)([A-Za-z0-9][\w.-]*)")
HOME_OK = {"shared", "user", "username", "you", "me", "u", "runner", "name", "foo", "example", "ubuntu", "linuxbrew",
           "lipflow"}

EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.([A-Za-z]{2,}))\b")
EMAIL_OK_TLD = {"png", "jpg", "jpeg", "gif", "svg", "pdf", "webp", "heic", "example", "test", "invalid", "localhost",
                "local", "swift", "json", "txt"}
EMAIL_OK_DOMAIN = re.compile(r"(?:^|\.)(?:example\.(?:com|org|net)|users\.noreply\.github\.com)$", re.I)
EMAIL_OK_LOCAL = re.compile(r"^(?:no-?reply|git|security|conduct)$", re.I)
# Dependabot appends this exact line to every commit message it writes
DEPENDABOT_SIGNOFF = re.compile(r"^Signed-off-by: dependabot\[bot\] <support@github\.com>[ \t]*$", re.M)
NOTICE_FILE = re.compile(r"(?:^|/)(?:LICEN[CS]E|NOTICE|COPYING|OFL|THIRD[_-]?PARTY|ThirdParty|AUTHORS|CREDITS)[^/]*$",
                         re.I)

# the upstream preferences domain, read only to migrate old installs (CLAUDE.md, naming)
LEGACY_DOMAIN = re.compile(r"nz\.owo\.koe")
LEGACY_DOMAIN_FILES = {"mac/MacApp/VelikiyMoguchiy/main.m", "mac/MacApp/Config/Secrets.xcconfig.example"}

DATA_LIST_NAMES = (
    re.compile(r"(?:^|/)manual_order[^/]*\.txt$"),
    re.compile(r"(?:^|/)queue[^/]*\.(?:txt|json|jsonl|tsv)$"),
    re.compile(r"(?:^|/)queue_faces[^/]*\.json$"),
    re.compile(r"(?:^|/)(?:video|feeder)_channels[^/]*\.tsv$"),
    re.compile(r"(?:^|/)channel_[^/]*\.(?:json|txt|tsv)$"),
    re.compile(r"(?:^|/)selection_ru[^/]*\.jsonl$"),
    re.compile(r"(?:^|/)cookies[^/]*\.txt$"),
    re.compile(r"^lipread/results/dashscope/"),
)
YOUTUBE_URL = re.compile(r"(?:youtube\.com/(?:watch\?v=|shorts/|embed/)|youtu\.be/)[A-Za-z0-9_-]{11}")
# an 11-character YouTube id as a JSON key or the first field of a line
VIDEO_ID_FIELD = re.compile(r'(?m)(?:^|["\'])([A-Za-z0-9_-]{11})(?:["\']\s*:|\t|,|$)')
MAX_VIDEO_IDS = 20
MAX_YOUTUBE_URLS = 5
PROVIDER_RESULT = (re.compile(r'"request_id"\s*:'), re.compile(r'"usage"\s*:'), re.compile(r'"output"\s*:'))

MEDIA = re.compile(r"\.(?:png|jpe?g|gif|webp|heic|heif|tiff?|bmp|ico|icns|svg|psd|mp4|mov|m4v|avi|mkv|webm|wav|mp3|"
                   r"m4a|aac|flac|ogg|opus|caf|aiff?|amr|3gp)$", re.I)
MEDIA_DIRS = (
    re.compile(r"^design/"),
    re.compile(r"^docs/assets/"),
    re.compile(r"^ios/(?:.+/)?[^/]*\.xcassets/"),
    re.compile(r"^mac/MacApp/(?:.+/)?[^/]*\.xcassets/"),
    re.compile(r"^ios/Tests/Reference/"),
    re.compile(r"^ios/screenshots/"),
)

# human-readable documents checked for publication readiness; data files such as phrase lists are not documents
DOCS = re.compile(r"\.(?:md|markdown)$|^\.github/ISSUE_TEMPLATE/[^/]+\.ya?ml$", re.I)
DOCS_EXEMPT = (
    re.compile(r"(?:^|/)vendor/"),
    re.compile(r"^tools/text_review/"),
)
BANNER_LINES = 12
# a GitHub draft release («черновик релиза») is not a draft document
DRAFT_TITLE = re.compile(r"черновик(?!\w*\s+(?:релиз|выпуск))|\bdraft\b(?!\s+release)", re.I)
DRAFT_NOTE = re.compile(r"для юриста|юристу\s*:|удалить (?:из публикуем|из финального|перед публикацией)|"
                        r"не публиковать|не для публикации|do not publish|not for publication", re.I)
DRAFT_TAG = re.compile(r"\b(?:TODO|FIXME|TBD)\b")
BRACKETS = re.compile(r"!?\[([^\[\]\n]*)\]")
PLACEHOLDER_TEXT = re.compile(r"[А-Яа-яЁё]|\bTBD\b")
# status tags that mark what a design document describes, e.g. «**[реализовано]**», «[план]»
STATUS_TAGS = {"план", "реализовано", "частично", "изм", "измерено", "оценка", "гипотеза", "код"}
CODE_SPAN = re.compile(r"(`+).+?\1")
FENCE = re.compile(r"^\s*(```|~~~)")
REF_DEF = re.compile(r"^\s{0,3}\[([^\]]+)\]:\s")
YAML_TITLE = re.compile(r"^\s*title:")

AI_IDENTITY = re.compile(r"claude|anthropic|openai|copilot|chatgpt|gemini|cursor", re.I)

TRAILER = re.compile(r"(?im)^(?:co-authored-by:.*(?:claude|anthropic|openai|copilot|gpt|gemini|\bai\b)|"
                     r".*generated with \[?claude|.*claude\.ai/code)")

WORD = re.compile(r"[^\W\d_]+|\d+", re.U)
HUMP = re.compile(r"[A-ZА-ЯЁ]?[a-zа-яё]+|[A-ZА-ЯЁ]+(?![a-zа-яё])|[^\W\d_]+", re.U)
ALNUM = re.compile(r"[^\W_]+", re.U)

SELF = "tools/privacy_guard.py"


def digest(word: str) -> str:
    return hashlib.sha256(SALT + word.lower().replace("ё", "е").encode()).hexdigest()[:20]


class Names:
    def __init__(self, names=NAMES):
        self.by_len = {}
        for h, n, extra, check in names:
            self.by_len.setdefault(n, {})[h] = (extra, check)
        self.cache = {}

    def word(self, w: str):
        """The check a word falls under, or None."""
        w = w.lower().replace("ё", "е")
        if w in self.cache:
            return self.cache[w]
        hit = None
        for n, table in self.by_len.items():
            if len(w) >= n:
                got = table.get(digest(w[:n]))
                if got and (got[0] is None or len(w) - n <= got[0]):
                    hit = got[1]
                    break
        self.cache[w] = hit
        return hit

    def line(self, text: str):
        found = set()
        words = set(ALNUM.findall(text)) | set(WORD.findall(text))
        for w in list(words):
            words.update(HUMP.findall(w))
        for w in words:
            c = self.word(w)
            if c:
                found.add(c)
        return found


def git(*args) -> str:
    return subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True, check=True).stdout


def tracked(staged=False):
    if staged:
        out = git("diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z")
    else:
        out = git("ls-files", "-z")
    return [p for p in out.split("\0") if p]


def read(rel: str, staged: bool):
    if staged:
        r = subprocess.run(["git", "-C", str(ROOT), "show", f":{rel}"], capture_output=True)
        return r.stdout if r.returncode == 0 else None
    p = ROOT / rel
    if p.is_symlink() or not p.is_file():
        return None
    return p.read_bytes()


def scan_text(rel: str, text: str, names: Names, extra):
    out = []
    is_notice = bool(NOTICE_FILE.search(rel))
    for no, line in enumerate(text.splitlines(), 1):
        checks = set()
        for rx in SECRETS:
            for m in rx.finditer(line):
                if not PLACEHOLDER.search(m.group(0)):
                    checks.add("secret")
        for m in HOME.finditer(line):
            if m.group(1).lower() not in HOME_OK and not m.group(1).startswith(("$", "<")):
                checks.add("path")
        if not is_notice:
            for m in EMAIL.finditer(line):
                local = m.group(0).split("@", 1)[0]
                if (m.group(2).lower() not in EMAIL_OK_TLD and not EMAIL_OK_DOMAIN.search(m.group(1))
                        and not EMAIL_OK_LOCAL.match(local)):
                    checks.add("email")
        if LEGACY_DOMAIN.search(line) and rel not in LEGACY_DOMAIN_FILES:
            checks.add("identifier")
        if rel != SELF:
            checks |= names.line(line)
        for rx in extra:
            if rx.search(line):
                checks.add("local pattern")
        out += [(rel, no, c) for c in sorted(checks)]
    if len(YOUTUBE_URL.findall(text)) >= MAX_YOUTUBE_URLS:
        out.append((rel, 0, f"data-list: {MAX_YOUTUBE_URLS}+ YouTube links"))
    ids = {m for m in VIDEO_ID_FIELD.findall(text) if re.search(r"\d|-|_", m) and re.search(r"[a-z]", m)
           and re.search(r"[A-Z]", m)}
    if len(ids) >= MAX_VIDEO_IDS:
        out.append((rel, 0, f"data-list: {len(ids)} video ids"))
    if all(rx.search(text) for rx in PROVIDER_RESULT):
        out.append((rel, 0, "data-list: raw provider result"))
    return out


def is_doc(rel: str) -> bool:
    return bool(DOCS.search(rel)) and not NOTICE_FILE.search(rel) and not any(rx.search(rel) for rx in DOCS_EXEMPT)


def scan_doc(rel: str, text: str):
    """Publication readiness of a document: drafts, notes to ourselves and unfilled placeholders."""
    out = []
    lines = text.splitlines()
    refs = {m.group(1).lower() for m in map(REF_DEF.match, lines) if m}
    is_yaml = not rel.lower().endswith((".md", ".markdown"))
    fenced = False
    seen = 0
    for no, line in enumerate(lines, 1):
        if FENCE.match(line):
            fenced = not fenced
            continue
        if fenced or REF_DEF.match(line) or (is_yaml and YAML_TITLE.match(line)):
            continue
        prose = CODE_SPAN.sub(" ", line)
        stripped = prose.strip()
        if stripped:
            seen += 1
        heading = stripped.startswith("#") or (is_yaml and re.match(r"(?:name|description)\s*:", stripped))
        banner = seen <= BANNER_LINES and stripped.startswith(">")
        checks = set()
        if (heading or banner) and DRAFT_TITLE.search(prose):
            checks.add("draft")
        if DRAFT_NOTE.search(prose) or DRAFT_TAG.search(prose):
            checks.add("draft")
        for m in BRACKETS.finditer(prose):
            inner, after = m.group(1), prose[m.end():m.end() + 1]
            if after in ("(", "[") or inner.strip().lower() in ("", "x") or inner.lower() in refs:
                continue
            if inner.startswith(("^", "!")) or inner.strip().lower() in STATUS_TAGS:
                continue
            if PLACEHOLDER_TEXT.search(inner):
                checks.add("placeholder")
        out += [(rel, no, c) for c in sorted(checks)]
    return out


def scan(paths, staged, extra):
    names = Names()
    findings = []
    for rel in paths:
        rel = PurePosixPath(rel).as_posix()
        if any(rx.search(rel) for rx in DATA_LIST_NAMES):
            findings.append((rel, 0, "data-list: file name"))
        if MEDIA.search(rel):
            if not any(rx.search(rel) for rx in MEDIA_DIRS):
                findings.append((rel, 0, "media outside the UI and design folders"))
            continue
        if rel != SELF and names.line(rel):
            findings.append((rel, 0, "name or identifier in the file name"))
        data = read(rel, staged)
        if data is None or b"\0" in data[:8192]:
            continue
        text = data.decode("utf-8", "replace")
        findings += scan_text(rel, text, names, extra)
        if is_doc(rel):
            findings += scan_doc(rel, text)
    return findings


def scan_commits(rng: str, names: Names):
    out = []
    for block in git("log", "--format=%H%x00%an <%ae>%x00%cn <%ce>%x00%B%x01", rng).split("\x01"):
        if not block.strip():
            continue
        sha, author, committer, body = block.strip("\n").split("\0", 3)
        short = sha[:9]
        people = author + "\n" + committer
        if TRAILER.search(body):
            out.append((f"commit {short}", 0, "trailer"))
        if AI_IDENTITY.search(people):
            out.append((f"commit {short}", 0, "ai-author"))
        for c in names.line(people) | names.line(body):
            out.append((f"commit {short}", 0, c))
        for m in EMAIL.finditer(people + "\n" + DEPENDABOT_SIGNOFF.sub("", body)):
            if not EMAIL_OK_DOMAIN.search(m.group(1)) and not EMAIL_OK_LOCAL.match(m.group(0).split("@")[0]):
                out.append((f"commit {short}", 0, "email"))
    return out


def load_extra(path):
    lines = []
    if path:
        lines += Path(path).read_text().splitlines()
    if os.environ.get("PRIVACY_GUARD_EXTRA"):
        lines += os.environ["PRIVACY_GUARD_EXTRA"].splitlines()
    return [re.compile(x, re.I) for x in (l.strip() for l in lines) if x and not x.startswith("#")]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="*")
    ap.add_argument("--staged", action="store_true")
    ap.add_argument("--commits", metavar="RANGE")
    ap.add_argument("--extra", metavar="FILE")
    ap.add_argument("--hash", metavar="WORD")
    a = ap.parse_args(argv)
    if a.hash:
        print(f'("{digest(a.hash)}", {len(a.hash)}, None, "name"),')
        return 0
    paths = a.files or tracked(a.staged)
    findings = scan(paths, a.staged, load_extra(a.extra))
    if a.commits:
        findings += scan_commits(a.commits, Names())
    for rel, no, check in sorted(set(findings)):
        print(f"{rel}:{no}: {check}" if no else f"{rel}: {check}")
    if findings:
        print(f"privacy guard: {len(set(findings))} finding(s) in {len({f[0] for f in findings})} file(s) or commit(s)",
              file=sys.stderr)
        return 1
    print(f"privacy guard: {len(paths)} files clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())
