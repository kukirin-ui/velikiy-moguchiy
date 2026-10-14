#!/usr/bin/env python3
"""Scans release builds for personal data the way `strings` would see it.

  python3 tools/scan_artifacts.py BUILD...        .zip, .ipa and .apk files (and archives inside them)
  python3 tools/scan_artifacts.py --show BUILD... also prints the matched text (local use only, never in CI)

Every file in an archive is read as printable ASCII and UTF-16LE runs of at least MIN_RUN characters, which is
what `strings -a` and `strings -el` print, and the runs go through the privacy guard's patterns for secrets, home
folders (the CI runners' own are fine), e-mail addresses and the author's identifiers. The upstream bundle id that
old installs migrate from is allowed only in the Mac app's own executable.
Findings name the build, the file inside and the check, never the text.
"""
from __future__ import annotations

import argparse
import io
import os
import re
import sys
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import privacy_guard as g  # noqa: E402

MIN_RUN = 6
MAX_DEPTH = 3
ARCHIVE = re.compile(r"\.(?:zip|ipa|apk|jar|aar)$", re.I)
ASCII_RUN = re.compile(rb"[\x20-\x7e\t]{%d,}" % MIN_RUN)
UTF16_RUN = re.compile(rb"(?:[\x20-\x7e]\x00){%d,}" % MIN_RUN)
LEGACY_ID_FILE = re.compile(r"(?:^|/)[^/]+\.app/Contents/MacOS/[^/]+$")
RUNNER_HOMES = g.HOME_OK | {"runneradmin", "vsts", "buildbot"}


def runs(data: bytes):
    for m in ASCII_RUN.finditer(data):
        yield m.group(0).decode("ascii")
    for m in UTF16_RUN.finditer(data):
        yield m.group(0).decode("utf-16-le")


def check_run(text: str, member: str, extra):
    """Checks one printable run found in `member`; returns (check, matched text) pairs."""
    out = []
    for rx in g.SECRETS:
        for m in rx.finditer(text):
            if not g.PLACEHOLDER.search(m.group(0)):
                out.append(("secret", m.group(0)))
    for m in g.HOME.finditer(text):
        name = m.group(1)
        if name.lower() not in RUNNER_HOMES and not name.startswith(("$", "<")):
            out.append(("path", m.group(0)))
    if not g.NOTICE_FILE.search(member):
        for m in g.EMAIL.finditer(text):
            local = m.group(0).split("@", 1)[0]
            if (m.group(2).lower() not in g.EMAIL_OK_TLD and not g.EMAIL_OK_DOMAIN.search(m.group(1))
                    and not g.EMAIL_OK_LOCAL.match(local)):
                out.append(("email", m.group(0)))
    for m in g.LEGACY_DOMAIN.finditer(text):
        if not LEGACY_ID_FILE.search(member):
            out.append(("identifier", m.group(0)))
    for rx in extra:
        for m in rx.finditer(text):
            out.append(("local pattern", m.group(0)))
    return out


def scan_bytes(label: str, data: bytes, extra, depth=0):
    findings = []
    if depth < MAX_DEPTH and ARCHIVE.search(label) and zipfile.is_zipfile(io.BytesIO(data)):
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            for info in z.infolist():
                if info.is_dir():
                    continue
                name = f"{label}!{info.filename}"
                findings += [(name, c, t) for c, t in check_run(info.filename, info.filename, extra)]
                findings += scan_bytes(name, z.read(info), extra, depth + 1)
        return findings
    member = label.rsplit("!", 1)[-1]
    seen = set()
    for text in runs(data):
        for check, matched in check_run(text, member, extra):
            if (check, matched) not in seen:
                seen.add((check, matched))
                findings.append((label, check, matched))
    return findings


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("builds", nargs="+")
    ap.add_argument("--extra", metavar="FILE")
    ap.add_argument("--show", action="store_true", help="print the matched text; not for CI logs")
    a = ap.parse_args(argv)
    extra = g.load_extra(a.extra)
    findings = []
    for build in a.builds:
        findings += scan_bytes(os.path.basename(build), Path(build).read_bytes(), extra)
    for label, check, matched in sorted(set(findings)):
        print(f"{label}: {check}" + (f" ({matched})" if a.show else ""))
    if findings:
        print(f"scan of the builds: {len(set(findings))} finding(s)", file=sys.stderr)
        return 1
    print(f"scan of the builds: {len(a.builds)} build(s) clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())
