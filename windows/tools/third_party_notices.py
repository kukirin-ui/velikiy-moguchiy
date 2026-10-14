"""Writes ThirdPartyNotices.txt for the Windows zip: this project's license, koe, and every Rust
crate linked into VelikiyMoguchiy.exe (x86_64-pc-windows-msvc, release features) with the license
files from the crate itself.

    python3 windows/tools/third_party_notices.py OUT_FILE

The license-file rules are those of tools/third-party-notices/generate.py, which writes the Mac
app's notices.
"""
import importlib.util
import json
import subprocess
import sys
from pathlib import Path

WINDOWS = Path(__file__).resolve().parents[1]
ROOT = WINDOWS.parent
TARGET = "x86_64-pc-windows-msvc"
OWN = {"velikiy-moguchiy-core", "velikiy-moguchiy-asr", "velikiy-moguchiy-windows", "velikiy-moguchiy-win32"}

spec = importlib.util.spec_from_file_location("mac_notices", ROOT / "tools/third-party-notices/generate.py")
mac_notices = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mac_notices)
section = mac_notices.section


def run(*args):
    return subprocess.run(args, cwd=WINDOWS, check=True, capture_output=True, encoding="utf-8").stdout


def crates():
    found = {}
    out = run("cargo", "tree", "--target", TARGET, "-e", "normal", "--prefix", "none",
              "--format", "{p}\t{l}", "-p", "velikiy-moguchiy-windows")
    for line in out.splitlines():
        if not line.strip() or line.endswith("(*)"):
            continue
        pkg, _, lic = line.partition("\t")
        name, version = pkg.split()[0], pkg.split()[1].lstrip("v")
        if name not in OWN:
            found[(name, version)] = lic.strip() or "see the crate"
    return sorted(found.items())


def main(dest: Path):
    meta = json.loads(run("cargo", "metadata", "--format-version", "1", "--filter-platform", TARGET))
    dirs = {(p["name"], p["version"]): Path(p["manifest_path"]).parent for p in meta["packages"]}
    out = ["«Великий & Могучий» (Velikiy Moguchiy) for Windows: licenses and third-party notices\n"
           "«Великий & Могучий» для Windows: лицензии и уведомления сторонних компонентов\n\n"
           "https://github.com/zigansh1n/velikiy-moguchiy — THIRD_PARTY.md has the full list,\n"
           "including models and services that are not part of the program.\n\n"]
    out.append(section("Velikiy Moguchiy — MIT License", (ROOT / "LICENSE").read_text(encoding="utf-8")))
    out.append(section("koe by Vincent Yang (https://github.com/missuo/koe) — MIT License\n"
                       "The shared Rust core is derived from koe.",
                       (ROOT / "mac/LICENSE").read_text(encoding="utf-8")))
    listing = crates()
    table = "\n".join(f"{name} {version} — {lic}" for (name, version), lic in listing)
    out.append(section(f"Rust crates linked into the program ({len(listing)})", table))
    seen = {}
    for (name, version), lic in listing:
        d = dirs.get((name, version))
        files = sorted(p for p in d.iterdir() if p.is_file() and mac_notices.LICENSE_FILE.match(p.name)) if d else []
        files += [d / extra for extra in mac_notices.EXTRA_FILES.get(name, []) if d and (d / extra).is_file()]
        if not files:
            out.append(section(f"{name} {version} — {lic}",
                               "The crate ships no license file; the license is given by its SPDX expression "
                               "above (texts: https://spdx.org/licenses/)."))
            continue
        body = []
        for p in files:
            text = p.read_text(encoding="utf-8", errors="replace").strip()
            if text in seen:
                body.append(f"--- {p.relative_to(d)}: same text as {seen[text]} ---")
            else:
                seen[text] = f"{name} {version} ({p.relative_to(d)})"
                body.append(f"--- {p.relative_to(d)} ---\n{text}")
        out.append(section(f"{name} {version} — {lic}", "\n\n".join(body)))
    dest.write_text("".join(out).rstrip() + "\n", encoding="utf-8")
    print(f"{dest}: {len(listing)} crates, {dest.stat().st_size // 1024} KiB")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(Path(sys.argv[1]))
