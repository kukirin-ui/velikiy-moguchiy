#!/usr/bin/env python3
"""Sets the version and sha256 of a Homebrew cask.

    bump.py CASK VERSION SHA256   rewrite the two stanzas in place
    bump.py selftest              offline tests

The cask keeps the release URL as a template on #{version}, so these two lines are all that changes
from one release to the next. Exits 1 when either stanza is missing, so a renamed stanza fails CI
instead of shipping a cask with stale checksums.
"""

from __future__ import annotations

import re
import sys
import tempfile
from pathlib import Path

VERSION = re.compile(r'^(\s*version\s+)"[^"]*"', re.M)
SHA256 = re.compile(r'^(\s*sha256\s+)"[^"]*"', re.M)
VERSION_FORMAT = re.compile(r"^\d+(?:\.\d+)*$")
SHA256_FORMAT = re.compile(r"^[0-9a-f]{64}$")


def bump(text: str, version: str, sha256: str) -> str:
    if not VERSION_FORMAT.match(version):
        raise ValueError(f"not a release version: {version!r}")
    if not SHA256_FORMAT.match(sha256):
        raise ValueError(f"not a SHA-256 digest: {sha256!r}")
    text, versions = VERSION.subn(lambda m: f'{m.group(1)}"{version}"', text, count=1)
    text, digests = SHA256.subn(lambda m: f'{m.group(1)}"{sha256}"', text, count=1)
    if not (versions and digests):
        raise ValueError("the cask has no version or sha256 stanza")
    return text


def selftest() -> None:
    cask = 'cask "x" do\n  version "0.1.0"\n  sha256 "' + "0" * 64 + '"\n  url "https://e/v#{version}/a.zip"\nend\n'
    out = bump(cask, "0.2.0", "a" * 64)
    assert 'version "0.2.0"' in out and f'sha256 "{"a" * 64}"' in out, out
    assert 'url "https://e/v#{version}/a.zip"' in out
    assert bump(out, "0.2.0", "a" * 64) == out
    for version, sha in (("v0.2.0", "a" * 64), ("0.2.0-beta", "a" * 64), ("0.2.0", "A" * 64), ("0.2.0", "a" * 63)):
        try:
            bump(cask, version, sha)
        except ValueError:
            continue
        raise AssertionError(f"accepted {version} {sha}")
    try:
        bump('cask "x" do\nend\n', "0.2.0", "a" * 64)
    except ValueError:
        pass
    else:
        raise AssertionError("accepted a cask without stanzas")
    real = Path(__file__).resolve().parent / "Casks/velikiy-moguchiy.rb"
    with tempfile.TemporaryDirectory() as tmp:
        copy = Path(tmp) / real.name
        copy.write_text(bump(real.read_text(encoding="utf-8"), "9.9.9", "b" * 64), encoding="utf-8")
        assert 'version "9.9.9"' in copy.read_text(encoding="utf-8")
    print("selftest: ok")


def main(argv: list[str]) -> int:
    if argv == ["selftest"]:
        selftest()
        return 0
    if len(argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    path, version, sha256 = Path(argv[0]), argv[1], argv[2]
    try:
        path.write_text(bump(path.read_text(encoding="utf-8"), version, sha256), encoding="utf-8")
    except ValueError as error:
        print(f"{path}: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
