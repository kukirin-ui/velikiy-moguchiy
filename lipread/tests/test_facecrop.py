"""Кадрирование лица одно и то же у preprocess.py и у сборщика (RULES.md, R3).

1. Одинаковые рамки -> одинаковые пиксели: preprocess.crop_track и newdata/vision.crop_clip идут через facecrop.py.
2. Одно и то же видео, два источника рамки: S3FD (preprocess.py, как у MultiVSR) и FaceMesh + newdata/calib.json
   (сборщик). Сравниваются сглаженные треки (s, x, y): отношение размеров и сдвиг центра в долях s.
   FaceMesh считается интерпретатором newdata/.venv (mediapipe), S3FD этим (torch + torchvision).

Запуск: ./run.sh python tests/test_facecrop.py [видео ...]   (по умолчанию clips/001.mp4 и clips/025.mp4)
"""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
sys.path.append(str(ROOT / "newdata"))

import cv2  # noqa: E402
import numpy as np  # noqa: E402

import facecrop  # noqa: E402
import preprocess  # noqa: E402
import vision  # noqa: E402

COLLECTOR_PY = ROOT / "newdata" / ".venv" / "bin" / "python"
MAX_SIZE_DIFF = 0.08  # |s_collector / s_s3fd - 1|
MAX_SHIFT = 0.05  # |centre shift| / s


def same_pixels():
    rng = np.random.default_rng(0)
    frames = rng.integers(0, 255, (20, 360, 640, 3), np.uint8)
    boxes = np.array([[250 + i, 80 - i, 370 + i, 230 + i * 0.5] for i in range(20)], np.float64)
    boxes[:, :2] -= [[150, 60]]  # часть кропа выходит за кадр: проверяется и серое поле
    with tempfile.TemporaryDirectory() as td:
        files = []
        for i, f in enumerate(frames):
            files.append(f"{td}/{i:03d}.png")
            cv2.imwrite(files[-1], f)
        preprocess.crop_track({"frame": np.arange(20), "bbox": boxes}, files, f"{td}/x.avi")
        sxy = facecrop.boxes_to_sxy(boxes)
        ref = np.stack([facecrop.crop_frame(cv2.imread(p), *sxy[i]) for i, p in enumerate(files)])
    col = vision.crop_clip(frames, sxy)
    assert np.array_equal(col, ref), "vision.crop_clip != facecrop"
    assert (ref[0, -1] == facecrop.PAD_VALUE).all(), "нет серого поля там, где кроп вышел за кадр"
    print("одинаковые рамки -> одинаковые пиксели: ok")


def s3fd_track(video):
    w, h = vision._dims(video)
    frames = vision.decode_frames(video)
    det = preprocess._detector("cpu")
    boxes = []
    for f in frames:
        b = det.detect_faces(f, conf_th=0.9, scales=[0.25])
        boxes.append(b[np.argmax((b[:, 2] - b[:, 0]) * (b[:, 3] - b[:, 1])), :4] if len(b) else [np.nan] * 4)
    boxes = np.array(boxes, np.float64)
    ok = ~np.isnan(boxes[:, 0])
    for j in range(4):
        boxes[~ok, j] = np.interp(np.flatnonzero(~ok), np.flatnonzero(ok), boxes[ok, j])
    return facecrop.boxes_to_sxy(boxes), h


COLLECTOR_SNIPPET = """
import sys, json, numpy as np
sys.path.insert(0, sys.argv[1])
import vision as V
w, h = V._dims(sys.argv[2])
out_h = 360 if w >= h else int(round(360 * h / w / 2) * 2)
o = V.analyze_frames(V.decode_frames(sys.argv[2], out_h=out_h))
print(json.dumps({"sxy": V.s3fd_like_track(o).tolist(), "h": out_h, "face": float(o["face"].mean())}))
"""


def collector_track(video):
    r = subprocess.run([str(COLLECTOR_PY), "-c", COLLECTOR_SNIPPET, str(ROOT / "newdata"), str(video)],
                       capture_output=True, text=True, check=True)
    d = json.loads(r.stdout.strip().splitlines()[-1])
    return np.array(d["sxy"]), d["h"], d["face"]


def same_video(video):
    a, ha = s3fd_track(video)
    b, hb, face = collector_track(video)
    n = min(len(a), len(b))
    a, b = a[:n], b[:n] * (ha / hb)  # сборщик работает на 360p, S3FD на исходном разрешении
    size = float(np.median(b[:, 0] / a[:, 0]) - 1)
    dx = float(np.median((b[:, 1] - a[:, 1]) / a[:, 0]))
    dy = float(np.median((b[:, 2] - a[:, 2]) / a[:, 0]))
    # в окне 96x96 у mvsr.read_faces лицо высотой 2s занимает ~2s * 224/(2.8s) * 160/224 = 114 px, т.е. 0.01 s ~ 0.57 px
    print(f"{Path(video).name}: кадров {n}, лицо у FaceMesh {face:.0%}; сборщик/S3FD: размер {size:+.1%}, "
          f"центр x {dx:+.3f}s ({dx * 57:+.1f} px окна 96), y {dy:+.3f}s ({dy * 57:+.1f} px)")
    assert abs(size) < MAX_SIZE_DIFF, f"размер рамки расходится на {size:+.1%}"
    assert abs(dx) < MAX_SHIFT and abs(dy) < MAX_SHIFT, f"центр рамки сдвинут на ({dx:+.3f}, {dy:+.3f}) s"
    return size, dx, dy


if __name__ == "__main__":
    same_pixels()
    vids = sys.argv[1:] or [str(ROOT / "clips" / "001.mp4"), str(ROOT / "clips" / "025.mp4")]
    if not COLLECTOR_PY.exists():
        sys.exit(f"нет {COLLECTOR_PY} (mediapipe для пути сборщика): newdata/README")
    for v in vids:
        same_video(v)
    print("facecrop: ok")
