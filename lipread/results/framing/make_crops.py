"""Test crops for results/framing: one S3FD box track per clip (full resolution, as preprocess.py), cropped by facecrop
from frames decoded at another height, plus the collector's FaceMesh box on full-resolution frames.

  work/faces_s3fd720   S3FD box, full-resolution frames, no JPEG step (control for work/faces)
  work/faces_s3fd480   S3FD box, frames decoded at 480p
  work/faces_s3fd360   S3FD box, frames decoded at 360p
  work/faces_fm720     FaceMesh + calib.json box (collector), full-resolution frames

Writes XVID AVI 224x224 like preprocess.py and prints the S3FD box height in source pixels at each height.
Needs .venv (S3FD) and newdata/.venv (mediapipe, called as a subprocess by tests/test_facecrop.py).
Usage: .venv/bin/python results/framing/make_crops.py [clips/*.mp4]
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "tests"))
import cv2  # noqa: E402
import numpy as np  # noqa: E402
import test_facecrop as T  # noqa: E402

HEIGHTS = (480, 360)


def write_xvid(arr_rgb, dst):
    v = cv2.VideoWriter(str(dst), cv2.VideoWriter_fourcc(*"XVID"), 25, (224, 224))
    for f in arr_rgb:
        v.write(f[..., ::-1])
    v.release()


def main():
    clips = sys.argv[1:] or sorted(str(p) for p in (ROOT / "clips").glob("*.mp4"))
    dirs = {k: ROOT / "work" / f"faces_{k}" for k in ["s3fd720", "fm720"] + [f"s3fd{h}" for h in HEIGHTS]}
    for d in dirs.values():
        d.mkdir(parents=True, exist_ok=True)
    for src in clips:
        st = Path(src).stem
        if all((d / f"{st}.avi").exists() for d in dirs.values()):
            continue
        s3, h = T.s3fd_track(src)
        fm, fm_h, _ = T.collector_track(src)
        full = T.vision.decode_frames(src)
        n = min(len(full), len(s3), len(fm))
        write_xvid(T.facecrop.crop_frames(full, s3[:n]), dirs["s3fd720"] / f"{st}.avi")
        write_xvid(T.facecrop.crop_frames(full, fm[:n] * (h / fm_h)), dirs["fm720"] / f"{st}.avi")
        sizes = {h: float(np.median(s3[:n, 0]) * 2)}
        for lh in HEIGHTS:
            low = T.vision.decode_frames(src, out_h=lh)
            write_xvid(T.facecrop.crop_frames(low, s3[:n] * (lh / h)), dirs[f"s3fd{lh}"] / f"{st}.avi")
            sizes[lh] = sizes[h] * lh / h
        print(st, "face box 2s:", ", ".join(f"{k}p {v:.0f} px" for k, v in sizes.items()), flush=True)


if __name__ == "__main__":
    main()
