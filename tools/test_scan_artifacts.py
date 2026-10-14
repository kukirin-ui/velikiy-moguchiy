"""python3 -m pytest tools/test_scan_artifacts.py"""
import io
import sys
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import scan_artifacts as s  # noqa: E402

HOME = "/Users/" + "someone/work/x.rs"
MAIL = "a.person@" + "mail.ru"
LEGACY = "nz.owo" + ".koe"


def zipped(files):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for name, data in files.items():
            z.writestr(name, data)
    return buf.getvalue()


def found(label, files, extra=()):
    return {(m, c) for m, c, _ in s.scan_bytes(label, zipped(files), extra)}


def test_binary_strings_are_read_as_ascii_and_utf16():
    blob = b"\x00\x01junk\x00" + HOME.encode() + b"\x00\x02" + MAIL.encode("utf-16-le") + b"\x00"
    assert found("a.zip", {"bin/app": blob}) == {("a.zip!bin/app", "path"), ("a.zip!bin/app", "email")}


def test_runner_paths_and_noreply_are_fine():
    ok = b"/Users/runner/work/x /home/runner/.cargo C:\\Use" b"rs\\runneradmin\\x 1+u@users.noreply.github.com icon@2x.png"
    assert found("a.zip", {"bin/app": ok}) == set()


def test_legacy_id_only_in_the_mac_executable():
    blob = b"id=" + LEGACY.encode()
    assert found("m.zip", {"App.app/Contents/MacOS/App": blob}) == set()
    assert found("m.zip", {"App.app/Contents/Resources/x": blob}) == {("m.zip!App.app/Contents/Resources/x", "identifier")}
    assert found("a.apk", {"classes.dex": blob}) == {("a.apk!classes.dex", "identifier")}


def test_nested_archives_and_member_names():
    inner = zipped({"x.bin": MAIL.encode()})
    assert found("a.ipa", {"Payload/lib.zip": inner}) == {("a.ipa!Payload/lib.zip!x.bin", "email")}
    assert found("a.zip", {HOME.lstrip("/"): b"clean"}) == set()
    assert found("a.zip", {"/" + HOME.lstrip("/"): b"clean"}) == {("a.zip!" + "/" + HOME.lstrip("/"), "path")}


def test_license_notices_may_name_authors():
    assert found("a.apk", {"assets/licenses.txt": b"Copyright " + MAIL.encode()}) == set()


def test_findings_do_not_print_the_text(tmp_path, capsys):
    p = tmp_path / "a.zip"
    p.write_bytes(zipped({"bin/app": MAIL.encode()}))
    assert s.main([str(p)]) == 1
    assert "mail.ru" not in capsys.readouterr().out
