#!/usr/bin/env python3
"""Builds the keyboard's word lists from the AOSP LatinIME dictionaries (Apache-2.0).

  python3 android/tools/build_wordlists.py --download     fetch the pinned sources, then build
  python3 android/tools/build_wordlists.py DIR            build from ru/en_US *_wordlist.combined.gz already in DIR

Output, in android/app/src/main/assets/dictionary/:
  <lang>.tsv               word<TAB>frequency (0-255), most frequent first; 0 = valid but never suggested
  <lang>.replacements.tsv  typo<TAB>replacement ("щас" -> "сейчас", "alot" -> "a lot")

Words that tools/privacy_guard.py would flag as a personal name or identifier are dropped, so the
list can be published in this repository.
"""
from __future__ import annotations

import argparse
import base64
import gzip
import hashlib
import sys
import tempfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "android/app/src/main/assets/dictionary"
COMMIT = "127336e9f29d69607eab55982324b210279ae8c5"
SOURCE = "https://android.googlesource.com/platform/packages/inputmethods/LatinIME/+/{commit}/dictionaries/{name}?format=TEXT"

# (output name, source file, sha256 of the source, lowest frequency kept)
LANGUAGES = (
    ("ru", "ru_wordlist.combined.gz", "8ef73a234018d23f5ca9ccc6cb65adecfd5667e87a8b6c6f1ed13ab86abad16e", 60),
    ("en", "en_US_wordlist.combined.gz", "0f78dd455b532be169a23f233227b811fabced4b5bd7fc9c40cc05839793bcbd", 40),
)
HIDDEN_FLAGS = ("offensive", "nonword", "drugs")


def parse(lines):
    """Yields (word, frequency, flags, not_a_word, shortcut) for each entry."""
    entry = None
    for raw in lines:
        if raw.startswith(" word="):
            if entry:
                yield entry
            fields = dict(part.split("=", 1) for part in raw.strip().split(",") if "=" in part)
            entry = [fields["word"], int(fields.get("f", "0")), fields.get("flags", ""),
                     fields.get("not_a_word") == "true", None]
        elif raw.startswith("  shortcut=") and entry:
            entry[4] = raw.strip().split(",")[0].split("=", 1)[1]
    if entry:
        yield entry


def build(source: Path, name: str, min_freq: int, names) -> tuple[int, int]:
    words, replacements, seen = [], [], set()
    with gzip.open(source, "rt", encoding="utf-8") as f:
        for word, freq, flags, not_a_word, shortcut in parse(f):
            if not_a_word:
                if shortcut and not names.line(shortcut):
                    replacements.append((word, shortcut))
                continue
            if freq < min_freq or word in seen or "\t" in word or names.line(word):
                continue
            seen.add(word)
            words.append((word, 0 if any(flag in flags for flag in HIDDEN_FLAGS) else freq))
    words.sort(key=lambda item: -item[1])
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / f"{name}.tsv").write_text("".join(f"{w}\t{f}\n" for w, f in words), encoding="utf-8")
    (OUT / f"{name}.replacements.tsv").write_text(
        "".join(f"{w}\t{r}\n" for w, r in sorted(replacements)), encoding="utf-8")
    return len(words), len(replacements)


def download(directory: Path):
    for _, file, sha, _ in LANGUAGES:
        url = SOURCE.format(commit=COMMIT, name=file)
        with urllib.request.urlopen(url, timeout=60) as response:
            data = base64.b64decode(response.read())
        if hashlib.sha256(data).hexdigest() != sha:
            sys.exit(f"{file}: checksum mismatch")
        (directory / file).write_bytes(data)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("source", nargs="?", type=Path, help="folder with the *_wordlist.combined.gz files")
    parser.add_argument("--download", action="store_true", help="fetch the pinned AOSP files first")
    args = parser.parse_args(argv)
    sys.path.insert(0, str(ROOT / "tools"))
    from privacy_guard import Names

    names = Names()
    with tempfile.TemporaryDirectory() as tmp:
        source = args.source
        if args.download:
            source = Path(tmp)
            download(source)
        if source is None:
            parser.error("give a source folder or --download")
        for name, file, sha, min_freq in LANGUAGES:
            path = source / file
            if hashlib.sha256(path.read_bytes()).hexdigest() != sha:
                sys.exit(f"{path}: not the pinned version")
            count, shortcuts = build(path, name, min_freq, names)
            print(f"{name}: {count} words, {shortcuts} replacements")


if __name__ == "__main__":
    main()
