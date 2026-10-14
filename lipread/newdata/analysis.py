"""VAD, нарезка на сегменты 2-10 с, модель «звук -> движения губ» с перекрёстной проверкой (персональная для ролика)."""
from __future__ import annotations

import os

import numpy as np

for _k in ("VECLIB_MAXIMUM_THREADS", "OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS"):
    os.environ.setdefault(_k, "1")

import vision as V

FPS = V.FPS
_VAD = {}


def vad_intervals(audio: np.ndarray, min_silence=0.25, min_speech=0.3):
    """Silero VAD -> [(start_s, end_s)]."""
    import torch
    from silero_vad import get_speech_timestamps, load_silero_vad
    torch.set_num_threads(1)
    if "m" not in _VAD:
        _VAD["m"] = load_silero_vad()
    ts = get_speech_timestamps(torch.from_numpy(audio), _VAD["m"], sampling_rate=V.SR, threshold=0.5,
                               min_speech_duration_ms=int(min_speech * 1000), min_silence_duration_ms=int(min_silence * 1000),
                               speech_pad_ms=30, return_seconds=True)
    return [(float(t["start"]), float(t["end"])) for t in ts]


def pack_segments(speech, env, dur, cue_bounds=None, min_len=2.0, max_len=10.0, pad=0.12):
    """Склейка речевых интервалов в сегменты 2-10 с с разрезом по паузам. env - огибающая 25 к/с для разреза
    затянувшихся фраз. cue_bounds - времена границ субтитров (предпочтительные точки разреза)."""
    cue = np.array(sorted(cue_bounds)) if cue_bounds else np.array([])
    out = []
    N = len(speech)
    i = 0
    while i < N:
        s0 = speech[i][0]
        best, bj = None, None
        for j in range(i, N):
            L = speech[j][1] - s0
            if L > max_len:
                break
            if L < min_len:
                continue
            gap = (speech[j + 1][0] - speech[j][1]) if j + 1 < N else 1.0
            sc = min(gap, 1.0) + (0.2 if 3.0 <= L <= 9.0 else 0.0)
            if len(cue) and np.min(np.abs(cue - speech[j][1])) < 0.35:
                sc += 0.4
            if best is None or sc >= best:
                best, bj = sc, j
        if bj is not None:
            gb = (s0 - speech[i - 1][1]) if i > 0 else 1.0
            ga = (speech[bj + 1][0] - speech[bj][1]) if bj + 1 < N else 1.0
            out.append((max(0.0, s0 - min(pad, gb / 2)), min(dur, speech[bj][1] + min(pad, ga / 2))))
            i = bj + 1
        else:
            L = speech[i][1] - s0
            if L > max_len:  # одна длинная фраза без пауз: режем по минимуму энергии в окне 4-9 с
                a, b = int((s0 + 4.0) * FPS), int((s0 + 9.0) * FPS)
                a, b = max(a, 0), min(b, len(env))
                cut = (a + int(np.argmin(env[a:b]))) / FPS if b > a else s0 + 6.0
                out.append((max(0.0, s0 - pad), cut))
                speech[i] = (cut, speech[i][1])
                continue
            i += 1  # короткий одиночный фрагмент
    return out


# ------------------------------------------------------------------ аудио-признаки и модель звук->губы
def _mel_fb(n_mels, n_fft, sr, fmin=80, fmax=4000):
    hz2mel = lambda f: 2595 * np.log10(1 + f / 700)
    mel2hz = lambda m: 700 * (10 ** (m / 2595) - 1)
    hz = mel2hz(np.linspace(hz2mel(fmin), hz2mel(fmax), n_mels + 2))
    bins = np.floor((n_fft + 1) * hz / sr).astype(int)
    fb = np.zeros((n_mels, n_fft // 2 + 1))
    for i in range(n_mels):
        l, c, r = bins[i], bins[i + 1], bins[i + 2]
        for k in range(l, c):
            fb[i, k] = (k - l) / max(c - l, 1)
        for k in range(c, r):
            fb[i, k] = (r - k) / max(r - c, 1)
    return fb


_FB = {}


def audio_mels(a: np.ndarray, n_frames: int, n_mels=16):
    """log-мел (16 полос 80-4000 Гц), 25 кадров/с, окно 64 мс."""
    hop, nfft = V.SR // FPS, 1024
    if (n_mels, nfft) not in _FB:
        _FB[(n_mels, nfft)] = _mel_fb(n_mels, nfft, V.SR)
    pad = np.pad(a, (nfft // 2, nfft // 2))
    m = max(1, (len(pad) - nfft) // hop + 1)
    idx = np.arange(nfft)[None, :] + hop * np.arange(m)[:, None]
    X = np.abs(np.fft.rfft(pad[idx] * np.hanning(nfft), axis=1)) ** 2
    M = np.log(X @ _FB[(n_mels, nfft)].T + 1e-8).astype(np.float32)
    if len(M) < n_frames:
        M = np.pad(M, ((0, n_frames - len(M)), (0, 0)), mode="edge")
    return M[:n_frames]


def stack_lags(M, lags=(-3, -2, -1, 0, 1, 2, 3)):
    return np.concatenate([np.roll(M, -l, axis=0) for l in lags], axis=1)


def lipact(o, valid_face=None):
    """Составной сигнал активности рта: среднее z-оценок (open, area, dark) по ролику, пропуски - интерполяцией."""
    f = (o["face"] > 0) if valid_face is None else valid_face
    zs = []
    for k in ("open", "area", "dark"):
        x = V.interp_missing(np.asarray(o[k], np.float64), f)
        zs.append((x - x[f].mean()) / (x[f].std() + 1e-9) if f.any() else x * 0)
    return np.mean(zs, 0)


def rmax(m, e, max_lag=5):
    """max по сдвигам +-max_lag кадров корреляции подготовленных сигналов (V._prep)."""
    n = len(m)
    best = -1.0
    for l in range(-max_lag, max_lag + 1):
        if l >= 0:
            if n - l < 12:
                continue
            r = float(np.mean(m[l:] * e[: n - l]))
        else:
            if n + l < 12:
                continue
            r = float(np.mean(m[: n + l] * e[-l:]))
        best = max(best, r)
    return best


def seg_sync(la, env, a, b, e_shift=0):
    """Синхронность сегмента [a,b) кадров: rmax(губы, огибающая звука); e_shift - для нулевой модели (звук из другого места)."""
    n = len(env)
    if e_shift:
        idx = (np.arange(a, b) + e_shift) % n
        e = env[idx]
    else:
        e = env[a:b]
    m = V._prep(la[a:b])
    return rmax(m, V._prep(e))
