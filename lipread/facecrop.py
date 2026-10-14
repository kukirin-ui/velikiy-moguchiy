"""Face framing shared by every path that makes 224x224 face clips: preprocess.py (owner's clips, test set),
newdata/vision.py (collector) and fetch/run.py (MultiVSR replay).

The framing is MultiVSR's (multivsr/preprocess/run_pipeline.py: track_shot + crop_video): an S3FD box per frame,
s = max(h, w) / 2 and the box centre, each median-filtered over 13 frames, then a crop of cy - s .. cy + 1.8 s
by cx -+ 1.4 s (crop_scale 0.4) with gray padding 110 where it leaves the frame, resized to 224x224.
mvsr.read_faces later resizes to 160 and keeps the centre 96x96.

Box sources: S3FD itself (preprocess.py, fetch/run.py) or a FaceMesh landmark box mapped to the S3FD box with
newdata/calib.json (collector, see facemesh_to_s3fd). tests/test_facecrop.py compares the two on the same video.
"""
from __future__ import annotations

import cv2
import numpy as np
from scipy import signal

CROP_SCALE = 0.40
PAD_VALUE = 110
MEDIAN_WIN = 13
SIZE = 224


def boxes_to_sxy(boxes) -> np.ndarray:
    """(n, 4) boxes x0, y0, x1, y1 -> (n, 3) smoothed half-size s, centre x, centre y."""
    b = np.asarray(boxes, np.float64)
    s = np.maximum(b[:, 3] - b[:, 1], b[:, 2] - b[:, 0]) / 2
    x = (b[:, 0] + b[:, 2]) / 2
    y = (b[:, 1] + b[:, 3]) / 2
    return np.stack([signal.medfilt(v, kernel_size=MEDIAN_WIN) for v in (s, x, y)], 1)


def facemesh_to_s3fd(x0, y0, x1, y1, box_calib: dict):
    """FaceMesh landmark box -> the S3FD box of the same face (calib.json "box": kx, ky size ratios, dy centre shift
    in FaceMesh heights). Arrays or scalars."""
    fh, fw = y1 - y0, x1 - x0
    cx = (x0 + x1) / 2
    cy = (y0 + y1) / 2 + box_calib.get("dy", 0.0) * fh
    h, w = fh * box_calib["ky"], fw * box_calib["kx"]
    return cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2


def crop_frame(frame, s, x, y, crop_scale=CROP_SCALE) -> np.ndarray:
    bsi = int(s * (1 + 2 * crop_scale))
    padded = cv2.copyMakeBorder(frame, bsi, bsi, bsi, bsi, cv2.BORDER_CONSTANT, value=(PAD_VALUE,) * 3)
    my, mx = y + bsi, x + bsi
    face = padded[int(my - s):int(my + s * (1 + 2 * crop_scale)), int(mx - s * (1 + crop_scale)):int(mx + s * (1 + crop_scale))]
    return cv2.resize(face, (SIZE, SIZE))


def crop_frames(frames, sxy, crop_scale=CROP_SCALE) -> np.ndarray:
    """frames (n, h, w, 3) or a list, sxy (n, 3) from boxes_to_sxy -> (n, 224, 224, 3) uint8, same channel order."""
    out = np.empty((len(sxy), SIZE, SIZE, 3), np.uint8)
    for i, (s, x, y) in enumerate(sxy):
        out[i] = crop_frame(frames[i], s, x, y, crop_scale)
    return out
