"""Writes the third-party notices that ship inside the apps (shown under «Лицензии»).

    python3 tools/third-party-notices/generate.py

- mac/MacApp/VelikiyMoguchiy/Licenses/ThirdPartyNotices.txt: this project's license, koe, the
  bundled helpers and ported code, and every Rust crate linked into the shipped core library and
  CLI (aarch64-apple-darwin, the release feature set) with the license files from the crate itself.
- ios/App/ThirdPartyNotices.txt: the Apache-2.0 base of the keyboard and the KeyboardKit port.

Run it again after changing Rust dependencies or the release features (needs cargo; it runs
`cargo fetch` for the macOS target first).
"""
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MAC = ROOT / "mac"
TARGET = "aarch64-apple-darwin"
# Must match the release build: MacApp/project.yml (core) and the CLI build in build-apple.yml.
BUILDS = [
    ["-p", "velikiy-moguchiy-core", "--no-default-features", "--features", "apple-speech,sherpa-onnx"],
    ["-p", "velikiy-moguchiy-cli"],
]
LICENSE_FILE = re.compile(r"^(LICEN[CS]E|COPYING|NOTICE|COPYRIGHT|AUTHORS)([-._].*)?$", re.I)
OWN = {"velikiy-moguchiy-core", "velikiy-moguchiy-asr", "velikiy-moguchiy-cli"}
# License files below the crate root of code that is compiled in: audiopus_sys builds and
# statically links its bundled libopus.
EXTRA_FILES = {"audiopus_sys": ["opus/COPYING"]}
RULE = "=" * 78
# Native libraries the sherpa-onnx-sys crate links statically: the no-TTS build that
# mac/scripts/sherpa-onnx-libs.sh fetches. The crates' own license files cover sherpa-onnx.
SHERPA_NATIVE = """sherpa-onnx v1.13.4 static libraries without text-to-speech (https://github.com/k2-fsa/sherpa-onnx):

sherpa-onnx, kaldi-native-fbank, kaldi-decoder (k2-fsa) — Apache License 2.0
OpenFst (sherpa-onnx-fst, sherpa-onnx-kaldifst-core) — Apache License 2.0
simple-sentencepiece (ssentencepiece_core) — Apache License 2.0
ONNX Runtime — MIT License, Copyright (c) Microsoft Corporation
KISS FFT — BSD 3-Clause License, Copyright (c) 2003-2010 Mark Borgerding

The Apache License 2.0 text is given with the sherpa-onnx crates below.

--- ONNX Runtime: MIT License ---
Copyright (c) Microsoft Corporation

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
documentation files (the "Software"), to deal in the Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of
the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO
THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

--- KISS FFT: BSD 3-Clause License ---
Copyright (c) 2003-2010 Mark Borgerding. All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the
following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this list of conditions and the
   following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the
   following disclaimer in the documentation and/or other materials provided with the distribution.
3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote
   products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES,
INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE."""


def run(*args, cwd=MAC):
    return subprocess.run(args, cwd=cwd, check=True, capture_output=True, text=True).stdout


def section(title, body):
    return f"{RULE}\n{title}\n{RULE}\n\n{body.strip()}\n\n"


def markdown_block(path, heading):
    """The fenced block that follows `heading` in a Markdown file."""
    text = path.read_text(encoding="utf-8")
    start = text.index(heading)
    fence = text.index("```", start)
    end = text.index("```", fence + 3)
    return text[fence + 3:end].strip("\n")


def crates():
    found = {}
    for build in BUILDS:
        out = run("cargo", "tree", "--target", TARGET, "-e", "normal", "--prefix", "none",
                  "--format", "{p}\t{l}", *build)
        for line in out.splitlines():
            if not line.strip() or line.endswith("(*)"):
                continue
            pkg, _, lic = line.partition("\t")
            parts = pkg.split()
            name, version = parts[0], parts[1].lstrip("v")
            if name in OWN:
                continue
            found[(name, version)] = lic.strip() or "see the crate"
    return sorted(found.items())


def main():
    run("cargo", "fetch", "--target", TARGET)
    import json
    meta = json.loads(run("cargo", "metadata", "--format-version", "1", "--filter-platform", TARGET))
    dirs = {(p["name"], p["version"]): Path(p["manifest_path"]).parent for p in meta["packages"]}

    out = []
    out.append("«Великий & Могучий» (Velikiy Moguchiy) for macOS: licenses and third-party notices\n"
               "«Великий & Могучий» для macOS: лицензии и уведомления сторонних компонентов\n\n"
               "https://github.com/zigansh1n/velikiy-moguchiy — THIRD_PARTY.md has the full list,\n"
               "including models and services that are not part of the app.\n\n")
    out.append(section("Velikiy Moguchiy — MIT License", (ROOT / "LICENSE").read_text(encoding="utf-8")))
    out.append(section("koe by Vincent Yang (https://github.com/missuo/koe) — MIT License\n"
                       "The macOS app is derived from koe.", (MAC / "LICENSE").read_text(encoding="utf-8")))
    out.append(section("macos-mic-keepwarm by Drew Burchfield (bundled as Contents/MacOS/mic-warm) — MIT License",
                       (MAC / "vendor/mic-warm/LICENSE").read_text(encoding="utf-8")))
    out.append(section("giga-pisar by moznoazachem (clipboard backup code, ported) — MIT License",
                       markdown_block(MAC / "THIRD_PARTY.md", "## giga-pisar")))
    listing = crates()
    table = "\n".join(f"{name} {version} — {lic}" for (name, version), lic in listing)
    out.append(section(f"Rust crates linked into the app and its CLI ({len(listing)})", table))
    out.append(section("Native libraries linked through sherpa-onnx-sys", SHERPA_NATIVE))
    seen_texts = {}
    for (name, version), lic in listing:
        d = dirs.get((name, version))
        files = sorted(p for p in d.iterdir() if p.is_file() and LICENSE_FILE.match(p.name)) if d else []
        files += [d / extra for extra in EXTRA_FILES.get(name, []) if d and (d / extra).is_file()]
        if not files:
            out.append(section(f"{name} {version} — {lic}",
                               "The crate ships no license file; the license is given by its SPDX expression "
                               f"above (texts: https://spdx.org/licenses/)."))
            continue
        body = []
        for p in files:
            text = p.read_text(encoding="utf-8", errors="replace").strip()
            key = text
            if key in seen_texts:
                body.append(f"--- {p.relative_to(d)}: same text as {seen_texts[key]} ---")
            else:
                seen_texts[key] = f"{name} {version} ({p.relative_to(d)})"
                body.append(f"--- {p.relative_to(d)} ---\n{text}")
        out.append(section(f"{name} {version} — {lic}", "\n\n".join(body)))
    dest = MAC / "MacApp/VelikiyMoguchiy/Licenses/ThirdPartyNotices.txt"
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text("".join(out).rstrip() + "\n", encoding="utf-8")
    print(f"{dest.relative_to(ROOT)}: {len(listing)} crates, {dest.stat().st_size // 1024} KiB")

    ios = []
    ios.append("«Великий & Могучий» (Velikiy Moguchiy) for iPhone: licenses and third-party notices\n"
               "«Великий & Могучий» для iPhone: лицензии и уведомления сторонних компонентов\n\n"
               "https://github.com/zigansh1n/velikiy-moguchiy\n\n")
    ios.append(section("This app is based on GeminiKeyboardSample by LyalinDotCom\n"
                       "(https://github.com/LyalinDotCom/GeminiKeyboardSample) and is distributed under the\n"
                       "Apache License 2.0. It was modified; the changes are listed in ios/THIRD_PARTY.md.",
                       (ROOT / "ios/LICENSE").read_text(encoding="utf-8")))
    kk = (ROOT / "ios/THIRD_PARTY_NOTICES.md").read_text(encoding="utf-8")
    kk_body = kk.split("## KeyboardKit 9.9.1", 1)[1]
    kk_body = re.sub(r"^> ?", "", kk_body, flags=re.M).strip()
    ios.append(section("KeyboardKit 9.9.1 by Daniel Saidi — MIT License", kk_body))
    dest = ROOT / "ios/App/ThirdPartyNotices.txt"
    dest.write_text("".join(ios).rstrip() + "\n", encoding="utf-8")
    print(f"{dest.relative_to(ROOT)}: {dest.stat().st_size // 1024} KiB")


if __name__ == "__main__":
    main()
