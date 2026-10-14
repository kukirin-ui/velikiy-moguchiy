"""Прогон логики рекордера без камеры и окна: видеофайл вместо камеры, клавиши по расписанию; второй прогон в режиме
--whisper с аудиофайлом вместо микрофона.
Запуск: uv run python tests/test_record_flow.py"""
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
mic = ROOT / "work" / "fake_mic.wav"
if not mic.exists():
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=3", str(mic)],
                   check=True)
# (секунды от старта, клавиша)
script = [(0.4, 32), (1.6, 32),          # фраза 1 записана
          (1.9, 32), (2.4, 32),          # фраза 2 записана
          (2.7, ord("r")),               # назад: фраза 2 удалена, снова на ней
          (3.0, 32), (4.0, 32),          # фраза 2 перезаписана
          (4.3, ord("n")),               # фраза 3 пропущена
          (4.6, 32), (5.3, ord("r")),    # фраза 4: старт и отброс дубля
          (5.6, 27)]                     # выход
t0, pos = 0.0, 0


def fake_wait(_ms):
    global pos
    if pos < len(script) and time.monotonic() - t0 >= script[pos][0]:
        k = script[pos][1]
        pos += 1
        return k
    return -1


cv2.imshow = lambda *a, **k: None
cv2.namedWindow = lambda *a, **k: None
cv2.resizeWindow = lambda *a, **k: None
cv2.destroyAllWindows = lambda *a, **k: None
cv2.getWindowProperty = lambda *a, **k: 1
cv2.waitKey = fake_wait


def run(extra, phrases_file):
    global t0, pos
    out = Path(tempfile.mkdtemp(prefix="rec_test_"))
    t0, pos = time.monotonic(), 0
    sys.argv = ["record.py", "--camera", str(src), "--out", str(out), *extra]
    record.main()
    files = sorted(p.name for p in out.iterdir())
    print("files:", files)
    assert files == ["001.mp4", "001.txt", "002.mp4", "002.txt"], files
    for n in ("001", "002"):
        pr = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                             "stream=r_frame_rate,nb_frames,width,height", "-of", "csv=p=0", str(out / f"{n}.mp4")],
                            capture_output=True, text=True)
        print(n, pr.stdout.strip(), (out / f"{n}.txt").read_text(encoding="utf8").strip())
        if extra:
            au = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "a:0", "-show_entries",
                                 "stream=codec_name,sample_rate", "-of", "csv=p=0", str(out / f"{n}.mp4")],
                                capture_output=True, text=True).stdout.strip()
            assert au == "alac,16000", au
    phr = record.load_phrases(phrases_file)
    assert (out / "001.txt").read_text(encoding="utf8").strip() == phr[0]
    assert (out / "002.txt").read_text(encoding="utf8").strip() == phr[1]
    shutil.rmtree(out)
    print("record flow: ok", *extra)


run([], ROOT / "phrases_ru.txt")
run(["--whisper", "--mic", str(mic)], ROOT / "phrases_whisper_ru.txt")
