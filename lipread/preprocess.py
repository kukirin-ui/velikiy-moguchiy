"""Предобработка клипа с веб-камеры в точности как у MultiVSR (multivsr/preprocess/run_pipeline.py).

Цепочка авторов (адаптация SyncNet):
  1. ffmpeg: видео -> AVI, 25 fps (`-qscale:v 2 -async 1 -r 25`), затем кадры в JPEG (`-qscale:v 2`);
  2. детектор лица S3FD: масштаб 0.25, порог 0.9;
  3. трекинг по IoU > 0.5 (до 25 пропущенных кадров), линейная интерполяция рамок;
  4. медианное сглаживание (окно 13) центра и размера рамки;
  5. квадратный кроп вокруг лица: top = cy - s, bottom = cy + s*1.8, лево/право = cx -+ s*1.4
     (crop_scale 0.4, серое поле 110 по краям), ресайз до 224x224 -> XVID AVI, 25 fps;
  6. потом inference.py читает AVI с ресайзом до 160x160 и берёт центр 96x96 RGB, значения /255
     (это делает mvsr.MultiVSR.load_faces).

Отличия от оригинала (намеренные):
  * детектор лица S3FD всегда на CPU (быстро, ~40 мс на кадр; на MPS он отдаёт неверные рамки);
  * пропущена детекция смены сцен (scenedetect): клип с веб-камеры это один план;
  * min_track по умолчанию 10 кадров вместо 100: фразы диктовки короче 4 секунд, а оригинал
    выбрасывает треки <= 100 кадров;
  * если треков несколько, берётся самый длинный; звук не нужен и не копируется.
"""
from __future__ import annotations

import argparse
import glob
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import cv2
import numpy as np
from scipy.interpolate import interp1d

import facecrop

ROOT = Path(__file__).resolve().parent
REPO = ROOT / "multivsr"

_DET = None


def _detector(device: str):
    global _DET
    if _DET is None or _DET[0] != device:
        sys.path.insert(0, str(REPO / "preprocess"))
        from detectors import S3FD  # type: ignore
        _DET = (device, S3FD(device=device))
    return _DET[1]


def _iou(a, b):
    xa, ya = max(a[0], b[0]), max(a[1], b[1])
    xb, yb = min(a[2], b[2]), min(a[3], b[3])
    inter = max(0, xb - xa) * max(0, yb - ya)
    area_a = (a[2] - a[0]) * (a[3] - a[1])
    area_b = (b[2] - b[0]) * (b[3] - b[1])
    return inter / float(area_a + area_b - inter)


def track_shot(scenefaces, min_track, num_failed_det=25, min_face_size=25, iou_thres=0.5):
    """run_pipeline.track_shot без изменений логики."""
    tracks = []
    while True:
        track = []
        for framefaces in scenefaces:
            for face in framefaces:
                if track == []:
                    track.append(face)
                    framefaces.remove(face)
                elif face["frame"] - track[-1]["frame"] <= num_failed_det:
                    if _iou(face["bbox"], track[-1]["bbox"]) > iou_thres:
                        track.append(face)
                        framefaces.remove(face)
                        continue
                else:
                    break
        if track == []:
            break
        elif len(track) > min_track:
            framenum = np.array([f["frame"] for f in track])
            bboxes = np.array([np.array(f["bbox"]) for f in track])
            frame_i = np.arange(framenum[0], framenum[-1] + 1)
            bboxes_i = []
            for ij in range(0, 4):
                bboxes_i.append(interp1d(framenum, bboxes[:, ij])(frame_i))
            bboxes_i = np.stack(bboxes_i, axis=1)
            if max(np.mean(bboxes_i[:, 2] - bboxes_i[:, 0]), np.mean(bboxes_i[:, 3] - bboxes_i[:, 1])) > min_face_size:
                tracks.append({"frame": frame_i, "bbox": bboxes_i})
    return tracks


def crop_track(track, frame_files, out_path, crop_scale=0.40, frame_rate=25):
    """run_pipeline.crop_video без звука (геометрия в facecrop.py). Пишет XVID AVI 224x224."""
    out_path = str(out_path)
    v_out = cv2.VideoWriter(out_path, cv2.VideoWriter_fourcc(*"XVID"), frame_rate, (224, 224))
    if not v_out.isOpened():
        raise RuntimeError("cv2.VideoWriter XVID не открылся")
    sxy = facecrop.boxes_to_sxy(track["bbox"])
    for fidx, frame in enumerate(track["frame"]):
        v_out.write(facecrop.crop_frame(cv2.imread(frame_files[frame]), *sxy[fidx], crop_scale=crop_scale))
    v_out.release()
    return {"s": sxy[:, 0], "x": sxy[:, 1], "y": sxy[:, 2]}


def preprocess_video(src, dst, min_track=10, facedet_scale=0.25, crop_scale=0.40,
                     conf_th=0.9, keep_tmp=False, verbose=False, det_every=1) -> dict:
    """src (любое видео) -> dst (.avi, лицо 224x224, 25 fps). Возвращает статистику.

    det_every > 1: детектор только на каждом N-м кадре (и на последнем), остальные рамки дают интерполяция
    и сглаживание track_shot / crop_track; min_track тогда считается в кадрах видео, как и без пропусков."""
    src, dst = str(src), str(dst)
    Path(dst).parent.mkdir(parents=True, exist_ok=True)
    tmp = tempfile.mkdtemp(prefix="mvsr_pre_")
    try:
        avi = os.path.join(tmp, "video.avi")
        frames_dir = os.path.join(tmp, "frames")
        os.makedirs(frames_dir)
        quiet = [] if verbose else ["-v", "error"]
        subprocess.run(["ffmpeg", "-y", *quiet, "-i", src, "-qscale:v", "2", "-async", "1", "-r", "25", avi], check=True)
        subprocess.run(["ffmpeg", "-y", *quiet, "-i", avi, "-qscale:v", "2", "-threads", "1", "-f", "image2",
                        os.path.join(frames_dir, "%06d.jpg")], check=True)
        flist = sorted(glob.glob(os.path.join(frames_dir, "*.jpg")))
        if not flist:
            raise RuntimeError(f"ffmpeg не извлёк кадры из {src}")

        det = _detector(os.environ.get("MVSR_PRE_DEVICE", "cpu"))  # cuda on a GPU pod: CPU S3FD takes minutes per clip
        dets = []
        for fidx, fname in enumerate(flist):
            if det_every > 1 and fidx % det_every and fidx != len(flist) - 1:
                dets.append([])
                continue
            image_np = cv2.cvtColor(cv2.imread(fname), cv2.COLOR_BGR2RGB)
            bboxes = det.detect_faces(image_np, conf_th=conf_th, scales=[facedet_scale])
            dets.append([{"frame": fidx, "bbox": b[:-1].tolist(), "conf": b[-1]} for b in bboxes])
        n_with_face = sum(1 for d in dets if d)

        tracks = track_shot(dets, min_track=max(1, min_track // det_every))
        if not tracks:
            raise RuntimeError(f"лицо не найдено или трек короче {min_track} кадров "
                               f"(кадров {len(flist)}, с лицом {n_with_face})")
        track = max(tracks, key=lambda t: len(t["frame"]))
        crop_track(track, flist, dst, crop_scale=crop_scale)
        return {"frames": len(flist), "frames_with_face": n_with_face, "track_frames": int(len(track["frame"])),
                "tracks": len(tracks)}
    finally:
        if not keep_tmp:
            shutil.rmtree(tmp, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser(description="Клип с веб-камеры -> трек лица для MultiVSR (как run_pipeline.py)")
    ap.add_argument("videos", nargs="+", help="входные видео")
    ap.add_argument("--out", default="work/faces", help="папка для результата (.avi 224x224, 25 fps)")
    ap.add_argument("--min_track", type=int, default=10, help="минимум кадров в треке (оригинал: 100)")
    ap.add_argument("--force", action="store_true")
    a = ap.parse_args()
    for v in a.videos:
        dst = Path(a.out) / (Path(v).stem + ".avi")
        if dst.exists() and not a.force:
            print(f"{v}: уже есть {dst}")
            continue
        info = preprocess_video(v, dst, min_track=a.min_track)
        print(f"{v} -> {dst}  {info}")


if __name__ == "__main__":
    main()
