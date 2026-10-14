"""Лицо, рот, синхронность звука и губ (MediaPipe FaceMesh + аудио-огибающая), кроп как у MultiVSR."""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import cv2
import numpy as np
from scipy import signal as sps
from scipy.ndimage import gaussian_filter1d, uniform_filter1d

sys.path.append(str(Path(__file__).resolve().parent.parent))  # facecrop.py: repo root here, copied next to this file on a pod
import facecrop  # noqa: E402

for _k in ("VECLIB_MAXIMUM_THREADS", "OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS"):
    os.environ.setdefault(_k, "1")  # иначе BLAS в нескольких процессах душит машину (load average > 700 было замечено)
os.environ.setdefault("GLOG_minloglevel", "3")
os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "3")

FPS = 25
SR = 16000
CALIB = Path(__file__).with_name("calib.json")  # масштаб рамки FaceMesh -> рамка S3FD, пороги синхронности

# индексы FaceMesh
I_UP, I_LO, I_L, I_R, I_NOSE, I_CL, I_CR, I_TOP, I_CHIN = 13, 14, 78, 308, 1, 234, 454, 10, 152
LIP_OUT = [61, 185, 40, 39, 37, 0, 267, 269, 270, 409, 291, 375, 321, 405, 314, 17, 84, 181, 91, 146]
LIP_INN = [78, 95, 88, 178, 87, 14, 317, 402, 318, 324, 308, 191, 80, 81, 82, 13, 312, 311, 310, 415]
ROI_W, ROI_H = 48, 32

_FM = {}


def face_mesh(n_faces=2, static=False):
    import mediapipe as mp
    import threading
    key = (os.getpid(), threading.get_ident(), n_faces, static)
    if key not in _FM:
        _FM[key] = mp.solutions.face_mesh.FaceMesh(static_image_mode=static, max_num_faces=n_faces, refine_landmarks=False,
                                                    min_detection_confidence=0.5, min_tracking_confidence=0.5)
    return _FM[key]


def load_calib():
    d = {"box": {"kx": 1.0, "ky": 1.0, "dy": 0.0}}
    if CALIB.exists():
        d.update(json.loads(CALIB.read_text()))
    return d


def decode_frames(path, ss=None, t=None, out_h=None):
    """ffmpeg -> RGB кадры 25 fps. Возвращает (n,h,w,3) uint8. Для коротких отрезков (<= ~60 с) / проб."""
    cmd = ["nice", "-n", "10", "ffmpeg", "-v", "error", "-nostdin"]
    if ss is not None:
        cmd += ["-ss", f"{ss:.3f}"]
    cmd += ["-i", str(path)]
    if t is not None:
        cmd += ["-t", f"{t:.3f}"]
    cmd += ["-an", "-r", str(FPS)]
    if out_h:
        cmd += ["-vf", f"scale=-2:{out_h}"]
    cmd += ["-f", "rawvideo", "-pix_fmt", "rgb24", "-"]
    w, h = _dims(path, out_h)
    raw = subprocess.run(cmd, capture_output=True).stdout
    n = len(raw) // (w * h * 3)
    return np.frombuffer(raw, np.uint8, n * w * h * 3).reshape(n, h, w, 3)


def _dims(path, out_h=None):
    p = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of", "csv=p=0:s=x",
                        str(path)], capture_output=True, text=True)
    w, h = map(int, p.stdout.strip().splitlines()[0].split("x"))
    if out_h:
        w = int(round(w * out_h / h / 2)) * 2
        h = out_h
    return w, h


def decode_audio(path, ss=None, t=None):
    cmd = ["ffmpeg", "-v", "error", "-nostdin"]
    if ss is not None:
        cmd += ["-ss", f"{ss:.3f}"]
    cmd += ["-i", str(path)]
    if t is not None:
        cmd += ["-t", f"{t:.3f}"]
    # aresample first_pts=0: учесть смещение старта звуковой дорожки относительно контейнера (иначе рассинхрон до секунд)
    cmd += ["-vn", "-af", "aresample=async=1:first_pts=0", "-ac", "1", "-ar", str(SR), "-f", "f32le", "-"]
    raw = subprocess.run(cmd, capture_output=True).stdout
    return np.frombuffer(raw, np.float32)


# ------------------------------------------------------------------ лицо
KEYS = ("face", "cx", "cy", "fh", "fw", "yaw", "open", "mw", "second", "jump", "x0", "y0", "x1", "y1", "mot", "dark", "area", "sharp")


class FaceFeat:
    """Покадровые признаки доминантного (самого большого) лица и рта. step(rgb_frame) -> dict (face=0 если нет лица).

    face: лицо найдено; cx,cy,fh,fw,x0..y1 - рамка по всем 468 точкам (px); yaw: |нос между скулами - 0.5|;
    open: расстояние внутренних губ / высота лица; mw: ширина рта / ширина лица; second: высота второго лица / первого;
    jump: центр лица прыгнул > 0.7 высоты (смена человека); mot: |ROI рта_t - ROI рта_t-1| (ROI выровнена по уголкам рта);
    dark: тёмность внутри внутреннего контура губ; area: его площадь; sharp: дисперсия лапласиана по лицу 96x96.
    """

    def __init__(self, n_faces=2, static=False):
        self.fm = face_mesh(n_faces, static)
        self.prev = None
        self.prev_roi = None

    def reset(self):
        self.prev = None
        self.prev_roi = None

    def step(self, frame):
        H, W = frame.shape[:2]
        o = dict.fromkeys(KEYS, 0.0)
        res = self.fm.process(frame)
        if not res.multi_face_landmarks:
            self.reset()
            return o
        cand = []
        for lm in res.multi_face_landmarks:
            a = np.array([(p.x * W, p.y * H) for p in lm.landmark], np.float32)
            x0, y0 = a.min(0)
            x1, y1 = a.max(0)
            cand.append((a, x0, y0, x1, y1, (y1 - y0) * (x1 - x0)))
        cand.sort(key=lambda c: -c[5])
        a, x0, y0, x1, y1, _ = cand[0]
        fh = float(np.linalg.norm(a[I_TOP] - a[I_CHIN]))
        fw = float(np.linalg.norm(a[I_CL] - a[I_CR]))
        if fh < 1 or fw < 1:
            self.reset()
            return o
        cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
        o.update(face=1.0, cx=cx, cy=cy, fh=y1 - y0, fw=x1 - x0, x0=x0, y0=y0, x1=x1, y1=y1)
        o["yaw"] = abs((a[I_NOSE][0] - a[I_CL][0]) / (a[I_CR][0] - a[I_CL][0] + 1e-6) - 0.5)
        o["open"] = float(np.linalg.norm(a[I_UP] - a[I_LO])) / fh
        o["mw"] = float(np.linalg.norm(a[I_L] - a[I_R])) / fw
        if len(cand) > 1:
            o["second"] = (cand[1][4] - cand[1][2]) / max(y1 - y0, 1)
        if self.prev is not None and np.hypot(cx - self.prev[0], cy - self.prev[1]) > 0.7 * self.prev[2]:
            o["jump"] = 1.0
            self.prev_roi = None
        self.prev = (cx, cy, y1 - y0)
        c = a[LIP_OUT].mean(0)
        mwid = float(np.linalg.norm(a[61] - a[291]))
        ang = np.degrees(np.arctan2(a[291][1] - a[61][1], a[291][0] - a[61][0]))
        M = cv2.getRotationMatrix2D((float(c[0]), float(c[1])), ang, ROI_W / (1.8 * mwid + 1e-6))
        M[0, 2] += ROI_W / 2 - c[0]
        M[1, 2] += ROI_H / 2 - c[1]
        g = cv2.cvtColor(frame, cv2.COLOR_RGB2GRAY)
        roi = cv2.warpAffine(g, M, (ROI_W, ROI_H), flags=cv2.INTER_LINEAR).astype(np.float32)
        if self.prev_roi is not None:
            o["mot"] = float(np.abs(roi - self.prev_roi).mean())
        self.prev_roi = roi
        poly = cv2.transform(a[LIP_INN].reshape(-1, 1, 2), M).reshape(-1, 2).astype(np.int32)
        mask = np.zeros((ROI_H, ROI_W), np.uint8)
        cv2.fillPoly(mask, [poly], 1)
        o["area"] = float(mask.sum()) / (ROI_W * ROI_H)
        if mask.sum() > 2:
            o["dark"] = float((255 - roi[mask > 0]).mean())
        xa, ya, xb, yb = [int(max(0, v)) for v in (x0, y0, x1, y1)]
        if xb - xa >= 20 and yb - ya >= 20:
            gf = cv2.resize(g[ya:yb, xa:xb], (96, 96), interpolation=cv2.INTER_AREA)
            o["sharp"] = float(cv2.Laplacian(gf, cv2.CV_64F).var())
        return o


def stack_rows(rows):
    return {k: np.array([r[k] for r in rows], np.float32) for k in KEYS}


def analyze_frames(frames: np.ndarray, n_faces=2):
    """Массив кадров RGB -> dict массивов признаков (см. FaceFeat)."""
    ff = FaceFeat(n_faces)
    return stack_rows([ff.step(f) for f in frames])


def iter_frames(path, ss=None, t=None, out_h=360):
    """Потоковое декодирование (ffmpeg pipe) -> кадры RGB (h,w,3) по одному, 25 к/с."""
    w, h = _dims(path, out_h)
    cmd = ["nice", "-n", "10", "ffmpeg", "-v", "error", "-nostdin"]
    if ss is not None:
        cmd += ["-ss", f"{ss:.3f}"]
    cmd += ["-i", str(path)]
    if t is not None:
        cmd += ["-t", f"{t:.3f}"]
    cmd += ["-an", "-r", str(FPS), "-vf", f"scale=-2:{out_h}", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"]
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, bufsize=w * h * 3 * 8)
    sz = w * h * 3
    try:
        while True:
            buf = p.stdout.read(sz)
            if len(buf) < sz:
                break
            yield np.frombuffer(buf, np.uint8).reshape(h, w, 3)
    finally:
        p.stdout.close()
        p.kill()
        p.wait()


def s3fd_equiv_h(mesh_h):
    """Высота рамки S3FD по высоте рамки FaceMesh (калибровка calib.json)."""
    b = load_calib()["box"]
    return mesh_h * b["ky"]


# ------------------------------------------------------------------ аудио -> огибающая и синхронность
def audio_envelope(audio: np.ndarray, n_frames: int):
    """log-энергия в полосе речи 100-3500 Гц, 25 кадров/с (окно 40 мс, шаг 40 мс), длина n_frames."""
    if len(audio) < SR // 10:
        return np.zeros(n_frames, np.float32)
    sos = sps.butter(4, [100, 3500], btype="band", fs=SR, output="sos")
    x = sps.sosfilt(sos, audio)
    hop = SR // FPS
    m = len(x) // hop
    e = np.sqrt(np.mean(x[: m * hop].reshape(m, hop) ** 2, axis=1) + 1e-10)
    e = np.log(e + 1e-4)
    if m < n_frames:
        e = np.pad(e, (0, n_frames - m), mode="edge")
    return e[:n_frames].astype(np.float32)


def _prep(x, sigma=1.0, win=38):
    x = np.asarray(x, np.float64)
    x = gaussian_filter1d(x, sigma, mode="nearest")
    x = x - uniform_filter1d(x, win, mode="nearest")  # убрать медленный дрейф (окно ~1.5 с)
    s = x.std()
    return (x - x.mean()) / (s + 1e-9)


def interp_missing(v, valid):
    v = v.copy()
    if valid.sum() < 2:
        return v
    idx = np.arange(len(v))
    v[~valid] = np.interp(idx[~valid], idx[valid], v[valid])
    return v


def sync_score(mouth: np.ndarray, env: np.ndarray, valid: np.ndarray, max_lag=4):
    """Корреляция раскрытия рта и речевой энергии. Возвращает (r_max, lag, r_at_0, z).

    z - превосходство над контролем: корреляция с той же огибающей, сдвинутой на >= 3 с (циклически), в сигмах.
    На коротких сегментах (< 6 с) z ненадёжен, основной критерий r_max.
    """
    n = len(mouth)
    if n < 25 or valid.sum() < 0.6 * n:
        return 0.0, 0, 0.0, 0.0
    m = _prep(interp_missing(mouth, valid))
    e = _prep(env)
    best, bl = -2.0, 0
    r0 = float(np.mean(m * e))
    for lag in range(-max_lag, max_lag + 1):
        if lag >= 0:
            r = np.mean(m[lag:] * e[: n - lag]) if n - lag > 10 else 0
        else:
            r = np.mean(m[: n + lag] * e[-lag:]) if n + lag > 10 else 0
        if r > best:
            best, bl = float(r), lag
    z = 0.0
    if n >= 100:
        nulls = []
        for sh in range(75, n - 74, max(1, (n - 150) // 12 or 1)):
            e2 = np.roll(e, sh)
            nulls.append(max((np.mean(m[l:] * e2[: n - l]) if l >= 0 else np.mean(m[:n + l] * e2[-l:])) for l in range(-max_lag, max_lag + 1)))
        if len(nulls) >= 4:
            z = (best - float(np.mean(nulls))) / (float(np.std(nulls)) + 1e-3)
    return best, bl, r0, z


# ------------------------------------------------------------------ чёткость лица
def face_sharpness(frames, o, step=5):
    """Медианная дисперсия лапласиана по кропу лица, приведённому к 96x96 (грубая мера пережатия/мыла)."""
    vals = []
    for i in range(0, len(frames), step):
        if not o["face"][i]:
            continue
        x0, y0, x1, y1 = [int(max(0, v)) for v in (o["x0"][i], o["y0"][i], o["x1"][i], o["y1"][i])]
        if x1 - x0 < 20 or y1 - y0 < 20:
            continue
        g = cv2.cvtColor(frames[i][y0:y1, x0:x1], cv2.COLOR_RGB2GRAY)
        g = cv2.resize(g, (96, 96), interpolation=cv2.INTER_AREA)
        vals.append(cv2.Laplacian(g, cv2.CV_64F).var())
    return float(np.median(vals)) if vals else 0.0


# ------------------------------------------------------------------ кроп (facecrop.py, как у MultiVSR)
def s3fd_like_track(o, sl=slice(None)):
    """Рамка S3FD из FaceMesh (калибровка calib.json) -> (s, x, y) с медианой 13, как в multivsr/preprocess."""
    valid = o["face"][sl] > 0
    cx = interp_missing(o["cx"][sl], valid)
    cy = interp_missing(o["cy"][sl], valid)
    fh = interp_missing(o["fh"][sl], valid)
    fw = interp_missing(o["fw"][sl], valid)
    box = facecrop.facemesh_to_s3fd(cx - fw / 2, cy - fh / 2, cx + fw / 2, cy + fh / 2, load_calib()["box"])
    return facecrop.boxes_to_sxy(np.stack(box, 1))


def crop_clip(frames_bgr, sxy, crop_scale=facecrop.CROP_SCALE):
    return facecrop.crop_frames(frames_bgr, sxy, crop_scale)


def write_mp4(arr_bgr, dst: Path):
    tmp = dst.with_suffix(".tmp.mp4")
    cmd = ["nice", "-n", "10", "ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "bgr24", "-s", "224x224", "-r", "25",
           "-i", "-", "-an", "-c:v", "libx264", "-crf", "23", "-preset", "veryfast", "-threads", "2", "-pix_fmt", "yuv420p",
           "-r", "25", "-movflags", "+faststart", str(tmp)]
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    p.communicate(arr_bgr.tobytes())
    if p.returncode != 0:
        raise RuntimeError("ffmpeg encode failed")
    os.replace(tmp, dst)
