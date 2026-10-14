"""Finds the close-up talking-head stretches of a video from its 144p version, so only those are fetched at 720p.

  .venv/bin/python harvester/scout.py VIDEO_144p.mp4   ->  prints JSON [[start, end], ...] in seconds

A classical Haar face detector on the CPU (no neural network, a few MB of memory): the Mac may not run ML models
(RULES.md R11). A stretch counts when one frontal face fills at least MIN_FACE of the frame height (120 px at 720p,
the collector's close-up threshold) for at least MIN_LEN seconds; short gaps are bridged.
"""
import json
import sys

import cv2

STEP_S = 0.5
MIN_FACE = 120 / 720
MIN_LEN = 4.0
MAX_GAP = 1.0
PAD = 0.5


def stretches(path):
    cap = cv2.VideoCapture(path)
    fps = cap.get(cv2.CAP_PROP_FPS) or 25
    n = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    det = cv2.CascadeClassifier(cv2.data.haarcascades + "haarcascade_frontalface_default.xml")
    hits = []
    step = max(1, round(fps * STEP_S))
    # sequential grab() skips frames without decoding them; seeking per sample was ~4x slower
    for i in range(n):
        if not cap.grab():
            break
        if i % step:
            continue
        ok, frame = cap.retrieve()
        if not ok:
            break
        h = frame.shape[0]
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        faces = det.detectMultiScale(gray, scaleFactor=1.1, minNeighbors=4, minSize=(int(h * MIN_FACE * 0.8),) * 2)
        big = [f for f in faces if f[3] >= h * MIN_FACE]
        hits.append((i / fps, len(big) == 1))
    cap.release()
    out, start, last = [], None, None
    for t, ok in hits:
        if ok:
            if start is None:
                start = t
            last = t
        elif start is not None and t - last > MAX_GAP:
            if last + STEP_S - start >= MIN_LEN:
                out.append([max(0.0, start - PAD), last + STEP_S + PAD])
            start = None
    if start is not None and last + STEP_S - start >= MIN_LEN:
        out.append([max(0.0, start - PAD), last + STEP_S + PAD])
    return out


if __name__ == "__main__":
    print(json.dumps([[round(a, 2), round(b, 2)] for a, b in stretches(sys.argv[1])]))
