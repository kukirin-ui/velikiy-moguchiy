"""Тестовые клипы не могут попасть в train/dev. Без GPU и без весов.
 1) train.guard_no_test_leak: совпадение хэша -> отказ; битая запись хэша -> отказ; текст теста -> строка исключена;
    --smoke-allow-test пропускает.
 2) dataset.py: байтовая копия тестового клипа и копия с тем же текстом в data/silent пропускаются с причиной.
Запуск: ./run.sh python tests/test_guard.py"""
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
import train  # noqa: E402

clips = ROOT / "clips"
tmp = Path(tempfile.mkdtemp(prefix="guard_"))
try:
    # --- 1. guard на строках манифеста
    from dataset import HashCache
    hc = HashCache(tmp / "h.json")
    c1 = clips / "001.mp4"
    h1 = hc.get(c1)
    cp = tmp / "copy.mp4"
    shutil.copyfile(c1, cp)
    other = tmp / "other.mp4"
    other.write_bytes(c1.read_bytes() + b"\0")  # другой хэш, текст тот же (проверяется ниже)
    ho = hc.get(other)
    row = lambda i, v, h, t, sp="train": dict(id=i, video=str(v), text=t, source="silent", split=sp, hash=h, frames=80,
                                              feats="x", face=None)
    ref_text = (clips / "001.txt").read_text(encoding="utf8").strip()

    try:
        train.guard_no_test_leak([row("a", cp, h1, "уникальный текст один")], clips)
        raise AssertionError("копия теста прошла")
    except SystemExit as e:
        assert "ОТКАЗ" in str(e), e
    print("ok: байтовая копия теста отклонена")

    try:  # в манифесте записан чужой хэш, файл на деле тестовый
        train.guard_no_test_leak([row("b", cp, "0" * 40, "уникальный текст два")], clips)
        raise AssertionError("подмена хэша прошла")
    except SystemExit as e:
        assert "хэш в манифесте" in str(e), e
    print("ok: подмена хэша в манифесте отклонена")

    try:  # видео из самой папки clips/
        train.guard_no_test_leak([row("c", clips / "002.mp4", "1" * 40, "уникальный текст три")], clips)
        raise AssertionError("видео из clips/ прошло")
    except SystemExit:
        pass
    print("ok: видео из clips/ отклонено")

    out = train.guard_no_test_leak([row("d", other, ho, ref_text), row("e", other, ho, "совсем другая фраза")], clips)
    assert [r["id"] for r in out] == ["e"], out
    print("ok: строка с тестовой фразой исключена, остальные пропущены")

    out = train.guard_no_test_leak([row("f", cp, h1, "текст")], clips, smoke_ok=True)
    assert len(out) == 1
    print("ok: --smoke-allow-test пропускает (только для дымового теста)")

    # --- 2. dataset.py на копиях тестовых клипов
    (tmp / "clips").mkdir()
    (tmp / "silent").mkdir()
    (tmp / "work" / "faces").mkdir(parents=True)
    for n in ("001", "002"):
        shutil.copyfile(clips / f"{n}.mp4", tmp / "clips" / f"{n}.mp4")
        shutil.copyfile(clips / f"{n}.txt", tmp / "clips" / f"{n}.txt")
        shutil.copyfile(ROOT / "work" / "faces" / f"{n}.avi", tmp / "work" / "faces" / f"{n}.avi")
    shutil.copyfile(c1, tmp / "silent" / "x1.mp4")
    (tmp / "silent" / "x1.txt").write_text("любой текст\n", encoding="utf8")
    (tmp / "silent" / "x2.mp4").write_bytes(c1.read_bytes() + b"\0")
    (tmp / "silent" / "x2.txt").write_text(ref_text + "\n", encoding="utf8")
    r = subprocess.run([sys.executable, str(ROOT / "dataset.py"), "--clips-dir", str(tmp / "clips"),
                        "--silent-dir", str(tmp / "silent"), "--voiced-dir", str(tmp / "none"),
                        "--public-dir", str(tmp / "none"), "--manifest", str(tmp / "m.jsonl"),
                        "--work-dir", str(tmp / "work"), "--no-features"], capture_output=True, text=True, cwd=ROOT)
    print(r.stdout[-600:], r.stderr[-300:])
    assert r.returncode == 0, r.stderr
    assert "пропуск silent/x1: хэш видео совпадает с тестовым клипом 001" in r.stdout
    assert "пропуск silent/x2: нормализованный текст совпадает" in r.stdout
    rows = [json.loads(l) for l in (tmp / "m.jsonl").read_text().splitlines()] if (tmp / "m.jsonl").exists() else []
    assert all(r_["split"] == "test" for r_ in rows), rows
    print("ok: dataset.py не пустил копии теста в train/dev")
    print("guard: ok")
finally:
    shutil.rmtree(tmp, ignore_errors=True)
