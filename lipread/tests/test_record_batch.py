"""Порции в рекордере: --batch 2 останавливает запись после 2 клипов за сеанс, повторный запуск продолжает с 003.
Без камеры и окна (видеофайл вместо камеры). Запуск: uv run python tests/test_record_batch.py"""
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import cv2

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
import record  # noqa: E402

src = ROOT / "work" / "fake_webcam.mp4"
if not src.exists():
    src.parent.mkdir(exist_ok=True)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=1280x720:rate=30:duration=3",
                    "-pix_fmt", "yuv420p", str(src)], check=True)
out = Path(tempfile.mkdtemp(prefix="rec_batch_"))
phr = out / "phr.txt"
phr.write_text("# комментарий\nпервая фраза номер один\nвторая фраза номер два\nтретья фраза номер три\nчетвёртая фраза номер четыре\nпятая фраза номер пять\n",
               encoding="utf8")


def session(script):
    t0 = time.monotonic()
    pos = [0]

    def fake_wait(_ms):
        if pos[0] < len(script) and time.monotonic() - t0 >= script[pos[0]][0]:
            k = script[pos[0]][1]
            pos[0] += 1
            return k
        return -1

    cv2.imshow = lambda *a, **k: None
    cv2.namedWindow = lambda *a, **k: None
    cv2.resizeWindow = lambda *a, **k: None
    cv2.destroyAllWindows = lambda *a, **k: None
    cv2.getWindowProperty = lambda *a, **k: 1
    cv2.waitKey = fake_wait
    sys.argv = ["record.py", "--camera", str(src), "--out", str(out), "--phrases", str(phr), "--batch", "2"]
    record.main()


# сеанс 1: три попытки записи, третья должна быть проигнорирована (порция из 2 заполнена)
session([(0.4, 32), (1.2, 32), (1.5, 32), (2.2, 32), (2.5, 32), (3.2, 32), (3.6, 27)])
names = sorted(p.name for p in out.glob("*.mp4"))
print("после сеанса 1:", names)
assert names == ["001.mp4", "002.mp4"], names
# сеанс 2: продолжает с третьей фразы
session([(0.4, 32), (1.2, 32), (1.5, 32), (2.2, 32), (2.5, 32), (3.2, 32), (3.6, 27)])
names = sorted(p.name for p in out.glob("*.mp4"))
print("после сеанса 2:", names)
assert names == ["001.mp4", "002.mp4", "003.mp4", "004.mp4"], names
assert (out / "003.txt").read_text(encoding="utf8").strip() == "третья фраза номер три"
shutil.rmtree(out)
print("record batch: ok")
