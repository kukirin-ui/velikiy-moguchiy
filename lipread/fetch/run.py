"""Шаг 3: скачивание YouTube (по ролику целиком, <=360p, без звука) и кроп лица по рамкам MultiVSR.

Конвейер (два независимых пула):
  * пул загрузки (потоки, 16 -> максимум 24 со ступенью +1 каждые 5 мин, пока своп плоский и нет блокировок YouTube):
    один вызов yt-dlp на ролик -> data/tmp/<ролик>/video.*  (ролик >70 мин: откат на секции по клипам);
  * пул кропа (процессы, ядра-2, nice 10): ffmpeg -ss режет каждый клип локально, масштаб рамок датасета к скачанному
    разрешению находится по S3FD на 3-6 кадрах клипа, кроп лица как multivsr/dataset/preprocess.py (медиана 13, запас
    0.4, серое поле 110) -> 224x224, 25 fps, H.264 -> data/public/<id>.mp4 + <id>.txt + <id>.json (json последним);
    сырой ролик удаляется сразу после нарезки.
Возобновляемо: клип готов, если есть data/public/<id>.json.
Остановка: touch fetch/STOP (мягко) или kill <PID> (SIGTERM, дорезает текущие ролики).
Куки YouTube: --cookies fetch/cookies.txt (если файл есть), передаются только в yt-dlp. Файл не читается и не копируется.
Блокировки YouTube (429/403/bot-check): потоков вдвое меньше (мин. 2), общая пауза 10 мин; 3 bot-check подряд - пауза
60 мин и снова вдвое меньше потоков; рост потоков возобновляется после 30 мин без блокировок. Прогон сам не
останавливается (только fetch/STOP). Ошибки bot-check пишутся в failures.jsonl с причиной "bot-check".
Диск: свободно < 15 ГБ - загрузка на паузе (возобновление > 20 ГБ).
Ускорения кропа: источник H.264 (дешёвое декодирование); масштаб S3FD полностью считается, пока у ролика нет надёжного
(2 клипа в пределах 5%), дальше по клипу ОДНО обнаружение лица в среднем кадре (наличие и положение относительно рамки).
Метки: вместе с видео качается звук; GigaAM (fetch/asr_service.py, один процесс, батчи) пишет в json asr_text и label_cer.
Переменные: LIPREAD_DATA_DIR (data/ в другом месте, там же STOP/progress.log/failures.jsonl - для проверок),
LIPREAD_ASR=0 (без звука/меток), LIPREAD_SCALE_ONCE=0 (всегда полная проверка), LIPREAD_FMT (формат видео yt-dlp),
LIPREAD_ASR_PY (интерпретатор сервиса меток).
"""
from __future__ import annotations

import argparse, collections, json, os, random, re, shutil, signal, subprocess, sys, threading, time
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import cv2
import numpy as np
from scipy import signal as sps

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))  # asr_service (в дочерних процессах кропа тоже)
sys.path.append(str(ROOT))
import facecrop  # noqa: E402
FETCH = ROOT / "fetch"
_dd = os.environ.get("LIPREAD_DATA_DIR")
DATA = Path(_dd).resolve() if _dd else ROOT / "data"
PUB = DATA / "public"
TMP = DATA / "tmp"
META = DATA / "public_meta"
CTL = DATA if _dd else FETCH  # STOP, progress.log, failures.jsonl (отдельно от боевых при LIPREAD_DATA_DIR)
STOPF = CTL / "STOP"
PROGRESS = CTL / "progress.log"
FAILS = CTL / "failures.jsonl"
SPOOL = DATA / "asr_spool"
NICE = ["nice", "-n", "10"]
MAX_DUR = 4200  # с; ролики длиннее качаем секциями по клипам

TM_KEYS = ("dec", "s3fd", "enc", "acut")
lock = threading.Lock()
stop = threading.Event()
state = {"done": 0, "failed": 0, "hours": 0.0, "bytes": 0, "t0": time.time(), "dl_bytes": 0, "videos": 0,
         "target": 16, "min_workers": 2, "last_notify": 0.0, "active_dl": 0, "queued": 0,
         "backoff_until": 0.0, "last_block_ts": 0.0, "consec_bot": 0, "cookies": False,
         "n_proc": 0, "n_acc": 0, "n_full": 0, "n_quick": 0, "tm": dict.fromkeys(TM_KEYS, 0.0)}
# a RunPod pod (harvester/) has more cores, a GPU and no swap to protect
MAX_WORKERS_CAP = int(os.environ.get("HARVEST_MAX_WORKERS", 24))
MAX_CROP_PROCS = int(os.environ.get("HARVEST_MAX_CROP", 8))
ON_POD = os.environ.get("HARVEST_POD") == "1"
BACKOFF_S = 600
LONG_BACKOFF_S = 3600
BOT_LIMIT = 3
QUIET_RAMP_S = 1800
reqs = collections.deque()  # (ts, is_throttle) за последние 10 минут
HW = {"enc": False}
WANT_ASR = os.environ.get("LIPREAD_ASR", "1") != "0"
SCALE_ONCE = os.environ.get("LIPREAD_SCALE_ONCE", "1") != "0"
_tl = threading.local()


# ---------------------------------------------------------------- общее
def log(msg):
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}"
    with lock:
        with open(PROGRESS, "a") as f:
            f.write(line + "\n")
    print(line, flush=True)


def clip_id(c):
    return f"{c['video_id']}__{c['track']}_{c['start']:06d}"


def fail(c, reason, detail=""):
    with lock:
        state["failed"] += 1
        with open(FAILS, "a") as f:
            f.write(json.dumps({"id": c["clip_id_out"], "clip_id": c["clip_id"], "video_id": c["video_id"],
                                "reason": reason, "detail": str(detail)[-300:], "ts": time.strftime("%F %T")},
                               ensure_ascii=False) + "\n")


def swap_used_mb():
    try:
        out = subprocess.run(["sysctl", "-n", "vm.swapusage"], capture_output=True, text=True).stdout
        return float(re.search(r"used = ([\d.]+)M", out).group(1))
    except Exception:
        return 0.0


_disk_cache = {"t": 0.0, "paused": False, "why": "", "data_t": 0.0, "data_gb": 0.0}
DISK_PAUSE_GB, DISK_RESUME_GB = 15, 20
MAX_DATA_GB = float(os.environ.get("HARVEST_MAX_DATA_GB", 60))


def disk_ok():
    """Пауза загрузки, если свободно < 15 ГБ (возобновление выше 20 ГБ) или data/ > 60 ГБ. Не останавливает прогон."""
    with lock:
        if time.time() - _disk_cache["t"] < 30:
            return not _disk_cache["paused"], _disk_cache["why"]
        need_walk = time.time() - _disk_cache["data_t"] > 600
    free = shutil.disk_usage(ROOT).free / 1e9
    if need_walk:
        used, seen = 0, set()
        for root, _, files in os.walk(DATA):
            for f in files:
                try:
                    st = os.stat(os.path.join(root, f))
                except OSError:
                    continue
                if (st.st_dev, st.st_ino) not in seen:  # pod backups are hard-linked into public/
                    seen.add((st.st_dev, st.st_ino))
                    used += st.st_size
        with lock:
            _disk_cache["data_gb"], _disk_cache["data_t"] = used / 1e9, time.time()
    with lock:
        paused, why = _disk_cache["paused"], ""
        if free < DISK_PAUSE_GB:
            paused, why = True, f"свободно {free:.1f} ГБ < {DISK_PAUSE_GB}"
        elif _disk_cache["data_gb"] > MAX_DATA_GB:
            paused, why = True, f"data/ {_disk_cache['data_gb']:.1f} ГБ > {MAX_DATA_GB}"
        elif paused and free < DISK_RESUME_GB:
            why = f"свободно {free:.1f} ГБ, жду {DISK_RESUME_GB}"
        else:
            paused = False
        was = _disk_cache["paused"]
        _disk_cache.update(t=time.time(), paused=paused, why=why)
    if paused and not was:
        log(f"ПАУЗА по диску: {why}")
    elif was and not paused:
        log(f"диск: свободно {free:.1f} ГБ, загрузка возобновлена")
    return not paused, why


def wait_disk():
    while not stop.is_set():
        if STOPF.exists():
            stop.set()
            return
        ok, _ = disk_ok()
        if ok:
            return
        time.sleep(30)


def notify(kind):
    """ВНИМАНИЕ в лог всегда; уведомление macOS не чаще раза в 15 минут."""
    log(f"ВНИМАНИЕ: YouTube ограничивает загрузку: {kind}, потоков сейчас {state['target']}")
    with lock:
        if time.time() - state["last_notify"] < 900:
            return
        state["last_notify"] = time.time()
    msg = f"YouTube начал ограничивать загрузку: {kind}, потоков сейчас {state['target']}".replace('"', "'")
    if sys.platform != "darwin":
        return
    subprocess.run(["osascript", "-e", f'display notification "{msg}" with title "Сбор данных для губ"'],
                   capture_output=True)


# ---------------------------------------------------------------- yt-dlp
PERMANENT = ("Video unavailable", "Private video", "has been removed", "This video is not available", "copyright",
             "This video is no longer available", "members-only", "Join this channel", "age-restricted",
             "Sign in to confirm your age", "terminated", "not made this video available", "live event",
             "This video has been", "is not available")
BOTCHECK = ("not a bot",)  # "Sign in to confirm you’re not a bot"; "Sign in to confirm your age" - это age-restricted, не оно
THROTTLE = ("429", "Too Many Requests", "HTTP Error 403", "rate-limit", "rate limit", "try again later")
# H.264 дешевле декодировать, чем VP9/AV1; без него - любой кодек. Звук (worst: m4a/opus, мелкий) - отдельным форматом
# в том же вызове yt-dlp; "dl_%(vcodec.:4)s" даёт имя dl_none.* для звука и dl_avc1.* / dl_vp09.* для видео
FMT = os.environ.get("LIPREAD_FMT") or "bv*[height<=360][vcodec^=avc1]/bv*[height<=360]/b[height<=360]"
FMT_A = "wa[language^=?ru][ext=m4a]/wa[language^=?ru][acodec^=opus]/wa[language^=?ru]"  # только русская дорожка: у ролика бывают дубляжи (en-US dubbed-auto), а "worst" берёт именно их
YT = NICE + ["yt-dlp", "--no-warnings", "--no-playlist", "--retries", "3", "--fragment-retries", "3",
             "-N", "8", "--sleep-requests", "1"]
# aria2c в системе нет: -N 8 = параллельные фрагменты; "--cookies <путь>" добавляется в main()


def classify(err, out=""):
    if any(k in err for k in BOTCHECK):
        return "botcheck"
    # YouTube answers an account it distrusts with "...unavailable... use --cookies for the authentication";
    # that is a block on us, not a dead video (age gates are the exception)
    if "for the authentication" in err and "confirm your age" not in err:
        return "botcheck"
    if any(k in err for k in THROTTLE):
        return "throttle"
    if any(k in err for k in PERMANENT):
        return "permanent"
    return "error" if err.strip() else "ok"


COOKIES = [None]


def yt(outdir: Path):
    """yt-dlp rewrites its cookie file on exit; parallel runs sharing one file can corrupt it, so each video gets a
    private 0600 copy inside its temp dir (removed with the dir after cropping)."""
    if not COOKIES[0]:
        return list(YT)
    own = outdir / ".cookies.txt"
    if not own.exists():
        outdir.mkdir(parents=True, exist_ok=True)
        fd = os.open(own, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as f, open(COOKIES[0], "rb") as src:
            shutil.copyfileobj(src, f)
    return YT + ["--cookies", str(own)]


def ytdlp_whole(vid, outdir: Path):
    """-> (видео, звук|None, kind, err)"""
    cmd = yt(outdir) + ["-f", FMT + ("," + FMT_A if WANT_ASR else ""), "--match-filter", f"duration<={MAX_DUR}",
                        "-o", str(outdir / "dl_%(vcodec.:4)s.%(ext)s"), f"https://www.youtube.com/watch?v={vid}"]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=1500)
    except subprocess.TimeoutExpired:
        return None, None, "timeout", "timeout"
    files = [f for f in outdir.glob("dl_*") if f.suffix not in (".part", ".ytdl")]
    vids = [f for f in files if not f.name.startswith("dl_none.")]
    auds = [f for f in files if f.name.startswith("dl_none.")]
    err = (p.stderr or "")[-3000:]
    if vids:
        return vids[0], (auds[0] if auds else None), "ok", ""
    if "does not pass filter" in (p.stdout or "") + err:
        return None, None, "toolong", ""
    return None, None, classify(err) if p.returncode else "error", err


def ytdlp_sections(vid, clips, outdir: Path):
    cmd = yt(outdir) + ["--force-keyframes-at-cuts", "-f", FMT, "-o", str(outdir / "sec_%(section_start)s-%(section_end)s.%(ext)s")]
    for c in clips:
        cmd += ["--download-sections", f"*{c['t_start']:.2f}-{c['t_end']:.2f}"]
    cmd.append(f"https://www.youtube.com/watch?v={vid}")
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=3000)
    except subprocess.TimeoutExpired:
        return "timeout", "error"
    err = (p.stderr or "")[-3000:]
    k = classify(err)
    if k == "permanent" and list(outdir.glob("sec_*")):
        k = "error"
    return err, ("ok" if p.returncode == 0 else k)


def match_sections(outdir: Path, clips):
    got = {}
    for f in outdir.glob("sec_*"):
        if f.suffix in (".part", ".ytdl"):
            continue
        m = re.match(r"sec_(\d+(?:\.\d+)?)-(\d+(?:\.\d+)?)\.\w+$", f.name)
        if m:
            for c in clips:
                if abs(c["t_start"] - float(m.group(1))) < 0.02:
                    got[c["clip_id_out"]] = f
    return got


# ---------------------------------------------------------------- кроп (в дочерних процессах)
def child_init():
    os.nice(10)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)  # дорезаем текущий ролик
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    cv2.setNumThreads(1)
    import torch
    torch.set_num_threads(1)


def detector():
    if not hasattr(_tl, "det"):
        sys.path.insert(0, str(ROOT / "multivsr" / "preprocess"))
        from detectors import S3FD  # type: ignore
        _tl.det = S3FD(device=os.environ.get("LIPREAD_DET_DEVICE", "cpu"))
    return _tl.det


def video_tracks(vid):
    if getattr(_tl, "tkey", None) == vid:
        return _tl.tval
    z = np.load(META / "tracks" / f"{vid}.npz")
    out = {}
    for k in z.files:
        if k.endswith("_bbox"):
            t = k[:-5]
            b = z[k].astype(np.float64)
            s = np.maximum(b[:, 3] - b[:, 1], b[:, 2] - b[:, 0]) / 2
            y = (b[:, 1] + b[:, 3]) / 2
            x = (b[:, 0] + b[:, 2]) / 2
            out[t] = (int(z[t + "_frame0"]), b, np.stack([sps.medfilt(s, 13), sps.medfilt(x, 13), sps.medfilt(y, 13)], 1))
    _tl.tkey, _tl.tval = vid, out
    return out


def probe_size(path):
    p = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height",
                        "-of", "csv=p=0", str(path)], capture_output=True, text=True)
    try:
        return [int(x) for x in p.stdout.strip().splitlines()[0].split(",") if x][:2]
    except Exception:
        raise RuntimeError(f"ffprobe не прочитал {Path(path).name}: {p.stdout!r} {p.stderr[-100:]}")


def decode_clip(src, ss, dur, w, h):
    cmd = NICE + ["ffmpeg", "-v", "error", "-ss", f"{ss:.3f}", "-t", f"{dur:.3f}", "-i", str(src), "-an", "-r", "25",
                  "-f", "rawvideo", "-pix_fmt", "bgr24", "-"]
    raw = subprocess.run(cmd, capture_output=True).stdout
    n = len(raw) // (w * h * 3)
    return np.frombuffer(raw, np.uint8, n * w * h * 3).reshape(n, h, w, 3)


NO_FACE = "лицо S3FD не найдено / не совпало с рамкой датасета"
QUICK_TOL = 0.25  # одиночное обнаружение шумнее медианы 3-х: допуск к масштабу ролика шире, чем 0.15 у полной проверки


def detect_ratio(det, frame, b, fixed_scale=None):
    """Одно обнаружение S3FD в кадре. -> отношение размера лица к рамке датасета или None (нет лица / не на рамке).
    fixed_scale: положение сверяется с рамкой, умноженной на известный масштаб ролика (а не на найденное отношение)."""
    bw, bh = b[2] - b[0], b[3] - b[1]
    d = det.detect_faces(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB), conf_th=0.9, scales=[0.5])
    if len(d) == 0:
        return None
    d = d[np.argmax((d[:, 2] - d[:, 0]) * (d[:, 3] - d[:, 1]))]
    r = ((d[2] - d[0]) + (d[3] - d[1])) / (bw + bh)
    cd = np.array([(d[0] + d[2]) / 2, (d[1] + d[3]) / 2])
    cb = np.array([(b[0] + b[2]) / 2, (b[1] + b[3]) / 2]) * (fixed_scale or r)
    if np.abs(cd - cb).max() > 0.3 * (d[2] - d[0]):
        return None
    return float(r)


def quick_check(frames, boxes, vs):
    """Масштаб ролика vs уже надёжен: одно обнаружение в среднем кадре - есть ли лицо, там ли оно, где рамка, и в
    масштабе ли ролика. -> (масштаб ролика | None, причина)"""
    i = min(len(frames) - 1, len(frames) // 2)
    r = detect_ratio(detector(), frames[i], boxes[i], vs)
    if r is None:
        return None, NO_FACE
    if abs(r / vs - 1) > QUICK_TOL:
        return None, f"масштаб {r:.3f} не совпал с масштабом ролика {vs:.3f}"
    return vs, ""


def cut_audio(src, ss, dur):
    """Аудио-сегмент клипа -> int16 16 кГц моно."""
    cmd = NICE + ["ffmpeg", "-v", "error", "-ss", f"{ss:.3f}", "-t", f"{dur:.3f}", "-i", str(src), "-vn", "-ac", "1",
                  "-ar", "16000", "-f", "s16le", "-"]
    return np.frombuffer(subprocess.run(cmd, capture_output=True).stdout, np.int16)


def estimate_scale(frames, boxes, h, prior):
    det = detector()
    n = len(frames)
    ratios = []
    for q in (0.15, 0.5, 0.85, 0.3, 0.7, 0.4):
        i = min(n - 1, int(n * q))
        r = detect_ratio(det, frames[i], boxes[i])
        if r is None:
            continue
        ratios.append(r)
        if len(ratios) >= 3:
            break
    if not ratios:
        return None, NO_FACE
    if len(ratios) < 2 and prior is None:
        return None, "одна проверка, нет априорного масштаба"
    if max(ratios) / min(ratios) > 1.25:
        return None, f"разброс масштаба {min(ratios):.2f}-{max(ratios):.2f}"
    s = float(np.median(ratios))
    cands = [h / H0 for H0 in (144, 240, 360, 480, 540, 720, 1080, 1440, 2160)]
    c = min(cands, key=lambda v: abs(v / s - 1))
    if abs(c / s - 1) < 0.1:
        s = c
    if prior is not None and abs(s / prior - 1) > 0.15:
        return None, f"масштаб {s:.3f} не совпал с масштабом ролика {prior:.3f}"
    return s, ""


def crop_clip(frames, sxy, scale, length):
    """sxy: рамки датасета MultiVSR (уже сглажены), scale: их масштаб к скачанному разрешению."""
    return facecrop.crop_frames([frames[min(i, len(frames) - 1)] for i in range(length)], sxy[:length] * scale)


def write_mp4(arr, dst: Path, hw_enc=False):
    tmp = dst.with_suffix(".tmp.mp4")
    base = NICE + ["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "bgr24", "-s", "224x224", "-r", "25",
                   "-i", "-", "-an"]
    encs = ([["-c:v", "h264_videotoolbox", "-q:v", "55", "-allow_sw", "1"]] if hw_enc else []) + \
           [["-c:v", "libx264", "-crf", "23", "-preset", "veryfast", "-threads", "2"]]
    for e in encs:
        p = subprocess.Popen(base + e + ["-pix_fmt", "yuv420p", "-r", "25", "-movflags", "+faststart", str(tmp)],
                             stdin=subprocess.PIPE)
        p.communicate(arr.tobytes())
        if p.returncode == 0:
            os.replace(tmp, dst)
            return
    raise RuntimeError("ffmpeg encode failed")


def spool_label(c, ss, audio, meta):
    """Принятый клип: звук в спул и заявка сервису меток (json допишет он). False - сервис недоступен/нет звука."""
    if not audio or (SPOOL / "DISABLED").exists():
        return False
    pcm = cut_audio(audio, ss, c["length"] / 25)
    if len(pcm) < 8000:  # < 0.5 с звука: считать нечего
        return False
    cid = c["clip_id_out"]
    SPOOL.mkdir(parents=True, exist_ok=True)
    np.save(SPOOL / f"{cid}.tmp.npy", pcm)
    os.replace(SPOOL / f"{cid}.tmp.npy", SPOOL / f"{cid}.npy")
    (SPOOL / f"{cid}.req.tmp").write_text(json.dumps({"pub": str(PUB), "ref": c["transcript"], "meta": meta},
                                                     ensure_ascii=False))
    os.replace(SPOOL / f"{cid}.req.tmp", SPOOL / f"{cid}.req")
    return True


def process_clip(c, src, ss, w, h, vs, audio, hw_enc, tm):
    """vs: состояние масштаба ролика {"first": первый принятый, "hist": [...], "rel": надёжный или None}. tm: секунды."""
    cid = c["clip_id_out"]
    L = c["length"]
    t = time.time()
    frames = decode_clip(src, ss, L / 25 + 0.2, w, h)
    tm["dec"] += time.time() - t
    if len(frames) < L - 4:
        return None, f"кадров {len(frames)} < {L}"
    frames = frames[:L]
    _, bbox, sxy = video_tracks(c["video_id"])[c["track"]]
    sl = slice(c["start"], c["start"] + L)
    t = time.time()
    quick = SCALE_ONCE and vs["rel"] is not None
    if quick:
        scale, why = quick_check(frames, bbox[sl], vs["rel"])
    else:
        scale, why = estimate_scale(frames, bbox[sl], h, vs["first"])
    tm["s3fd"] += time.time() - t
    tm["n_quick" if quick else "n_full"] += 1
    if scale is None:
        return None, why
    if not quick:  # надёжный масштаб ролика: два полных клипа в пределах 5%
        for p in vs["hist"]:
            if abs(scale / p - 1) <= 0.05:
                vs["rel"] = float((scale * p) ** 0.5)
                break
        vs["hist"].append(scale)
    face_px = float(np.mean(sxy[sl, 0]) * 2 * scale)
    if face_px < 36:
        return None, f"лицо слишком мелкое: {face_px:.0f} px"
    t = time.time()
    write_mp4(crop_clip(frames, sxy[sl], scale, L), PUB / f"{cid}.mp4", hw_enc)
    tm["enc"] += time.time() - t
    (PUB / f"{cid}.txt").write_text(c["transcript"].strip() + "\n", encoding="utf-8")
    meta = {"video_id": c["video_id"], "start": c["t_start"], "end": c["t_end"], "source": "multivsr-ru",
            "clip_id": c["clip_id"], "split": c["split"], "frames": L, "src_height": h, "box_scale": round(scale, 4),
            "face_px_src": round(face_px, 1), "scale_check": "quick" if quick else "full"}
    t = time.time()
    try:
        spooled = spool_label(c, ss, audio, meta)
    except Exception:  # noqa  звук не критичен: клип остаётся без asr_text
        spooled = False
    tm["acut"] += time.time() - t
    if not spooled:
        from asr_service import write_json
        write_json(str(PUB), cid, meta)
    return scale, ""


def crop_job(job):
    """Выполняется в дочернем процессе. -> список результатов по клипам."""
    res, dims = [], None
    vs = {"first": None, "hist": [], "rel": None}
    try:
        for c in job["clips"]:
            r = {"id": c["clip_id_out"], "length": c["length"]}
            tm = dict.fromkeys(TM_KEYS, 0.0)
            tm.update(n_quick=0, n_full=0)
            try:
                if job["mode"] == "whole":
                    src, ss = job["path"], c["t_start"]
                    dims = dims or probe_size(src)
                else:
                    src, ss = c["seg"], 0.0
                    dims = probe_size(src)
                s, why = process_clip(c, src, ss, dims[0], dims[1], vs, job.get("audio") if job["mode"] == "whole" else None,
                                      job["hw_enc"], tm)
            except Exception as e:  # noqa
                s, why = None, f"исключение: {type(e).__name__}: {e}"
            if s is None:
                for ext in ("mp4", "txt", "json", "json.tmp", "tmp.mp4"):
                    (PUB / f"{c['clip_id_out']}.{ext}").unlink(missing_ok=True)
                r.update(ok=False, reason="crop_failed", detail=why)
            else:
                vs["first"] = vs["first"] or s
                r.update(ok=True, bytes=(PUB / f"{c['clip_id_out']}.mp4").stat().st_size)
            r["tm"] = tm
            res.append(r)
    finally:
        shutil.rmtree(job["dir"], ignore_errors=True)
    return res


# ---------------------------------------------------------------- загрузка (потоки в главном процессе)
def wait_backoff():
    """Общая пауза после блокировки YouTube; прерывается STOP/stop."""
    while not stop.is_set():
        if STOPF.exists():
            stop.set()
            return
        left = state["backoff_until"] - time.time()
        if left <= 0:
            return
        time.sleep(min(left, 5))


def on_block(kind, t_req, err):
    """Блокировка YouTube: потоков вдвое меньше (минимум 2), пауза 10 мин. 3 bot-check подряд: пауза 60 мин, потом
    снова вдвое меньше потоков; счётчик обнуляется, прогон не останавливается сам (только fetch/STOP). Запрос, начатый
    до уже зафиксированной блокировки (хвост того же эпизода), не считается заново."""
    last = err.strip().splitlines()[-1][:80] if err.strip() else ""
    with lock:
        now = time.time()
        fresh = t_req >= state["last_block_ts"]
        long_pause = False
        if fresh:
            state["last_block_ts"] = now
            state["consec_bot"] = state["consec_bot"] + 1 if kind == "botcheck" else 0
            long_pause = state["consec_bot"] >= BOT_LIMIT
            state["backoff_until"] = now + (LONG_BACKOFF_S if long_pause else BACKOFF_S)
            state["target"] = max(state["min_workers"], state["target"] // 2)
            if long_pause:
                state["consec_bot"] = 0
        n = state["consec_bot"]
    if long_pause and ON_POD:
        # an idle pod still bills: stop instead of waiting an hour
        log(f"{BOT_LIMIT} bot-check подряд на поде: cookies rejected, останавливаюсь")
        STOPF.touch()
        stop.set()
    elif long_pause:
        log(f"{BOT_LIMIT} bot-check подряд (куки {'есть' if state['cookies'] else 'нет'}): пауза {LONG_BACKOFF_S // 60} мин, "
            f"потом потоков {state['target']}")
    elif fresh:
        log(f"{kind}: пауза {BACKOFF_S // 60} мин, потоков {state['target']}, bot-check подряд {n}")
    notify(f"{kind}: {last}".strip())


def block_ok():
    with lock:
        state["consec_bot"] = 0


def record_req(throttled):
    now = time.time()
    with lock:
        reqs.append((now, throttled))
        while reqs and reqs[0][0] < now - 600:
            reqs.popleft()


def on_job_done(clips_by_id, slots):
    def cb(fut):
        slots.release()
        with lock:
            state["queued"] -= 1
        try:
            res = fut.result()
        except Exception as e:  # noqa
            log(f"ОШИБКА пула кропа: {type(e).__name__}: {e}")
            return
        ok = 0
        with lock:
            for r in res:
                tm = r.get("tm") or {}
                state["n_proc"] += 1
                state["n_acc"] += bool(r["ok"])
                state["n_full"] += tm.get("n_full", 0)
                state["n_quick"] += tm.get("n_quick", 0)
                for k in TM_KEYS:
                    state["tm"][k] += tm.get(k, 0.0)
        for r in res:
            if r["ok"]:
                ok += 1
                with lock:
                    state["done"] += 1
                    state["hours"] += r["length"] / 25 / 3600
                    state["bytes"] += r["bytes"]
            else:
                fail(clips_by_id[r["id"]], r["reason"], r["detail"])
        with lock:
            state["videos"] += 1
        el = (time.time() - state["t0"]) / 60
        v = next(iter(clips_by_id.values()))["video_id"]
        log(f"{v}: готово {ok}/{len(res)} | сессия: {state['done']} клипов, {state['hours']:.2f} ч, "
            f"{state['done']/max(el,1e-9):.1f} клип/мин, {state['hours']/max(el/60,1e-9):.2f} ч/ч, "
            f"mp4 {state['bytes']/1e6:.0f} МБ, ошибок {state['failed']}")
    return cb


def download_and_submit(vid, clips, pool, slots, args):
    todo = [c for c in clips if not (PUB / f"{c['clip_id_out']}.json").exists()]
    if not todo:
        return
    byid = {c["clip_id_out"]: c for c in todo}
    outdir = TMP / vid
    last_block, last_err = "", ""
    for attempt in range(5):
        wait_backoff()
        if stop.is_set():
            if last_block:
                for c in todo:
                    fail(c, "bot-check" if last_block == "botcheck" else "throttle", last_err.strip().splitlines()[-1] if last_err.strip() else "")
            return
        wait_disk()
        if stop.is_set():
            return
        time.sleep(random.uniform(0, 0.5))
        shutil.rmtree(outdir, ignore_errors=True)
        outdir.mkdir(parents=True)
        with lock:
            state["active_dl"] += 1
        t_req = time.time()
        try:
            path, apath, kind, err = ytdlp_whole(vid, outdir)
            if kind == "toolong":
                for rnd in range(3):
                    have = match_sections(outdir, todo)
                    need = [c for c in todo if c["clip_id_out"] not in have]
                    if not need:
                        break
                    err, k2 = ytdlp_sections(vid, need, outdir)
                    if k2 in ("throttle", "botcheck", "permanent"):
                        kind = k2
                        break
                else:
                    pass
                if kind == "toolong":
                    kind = "ok" if match_sections(outdir, todo) else "error"
        finally:
            with lock:
                state["active_dl"] -= 1
        record_req(kind in ("throttle", "botcheck"))
        if kind in ("throttle", "botcheck"):
            shutil.rmtree(outdir, ignore_errors=True)
            last_block, last_err = kind, err
            on_block(kind, t_req, err)
            continue
        block_ok()
        if kind == "permanent":
            for c in todo:
                fail(c, "video_unavailable", err.strip().splitlines()[-1] if err.strip() else "")
            log(f"{vid}: ролик недоступен ({len(todo)} клипов)")
            shutil.rmtree(outdir, ignore_errors=True)
            return
        if kind in ("error", "timeout") and path is None and not match_sections(outdir, todo):
            if attempt < 2:
                time.sleep(random.uniform(2, 6))
                continue
            for c in todo:
                fail(c, "download_error", err.strip().splitlines()[-1] if err.strip() else kind)
            shutil.rmtree(outdir, ignore_errors=True)
            return
        break
    else:
        for c in todo:
            fail(c, "bot-check" if last_block == "botcheck" else "throttle_retries_exhausted",
                 last_err.strip().splitlines()[-1] if last_err.strip() else "")
        shutil.rmtree(outdir, ignore_errors=True)
        return
    if path is not None:  # целый ролик
        job = {"mode": "whole", "path": str(path), "audio": str(apath) if apath else None, "dir": str(outdir),
               "clips": todo, "hw_enc": HW["enc"]}
        with lock:
            state["dl_bytes"] += path.stat().st_size + (apath.stat().st_size if apath else 0)
    else:
        got = match_sections(outdir, todo)
        cl = []
        for c in todo:
            if c["clip_id_out"] in got:
                cl.append({**c, "seg": str(got[c["clip_id_out"]])})
                with lock:
                    state["dl_bytes"] += got[c["clip_id_out"]].stat().st_size
            else:
                fail(c, "section_missing", err.strip().splitlines()[-1] if err.strip() else "")
        job = {"mode": "sections", "dir": str(outdir), "clips": cl, "hw_enc": HW["enc"]}
    slots.acquire()  # не копим на диске роликов больше, чем успевает резать пул
    with lock:
        state["queued"] += 1
    fut = pool.submit(crop_job, job)
    fut.add_done_callback(on_job_done(byid, slots))


def tmp_inprogress_bytes():
    t = 0
    try:
        for root, _, files in os.walk(TMP):
            for f in files:
                try:
                    t += os.path.getsize(os.path.join(root, f))
                except OSError:
                    pass
    except Exception:
        pass
    return t


def timing_stat():
    """Среднее время на клип (с): декод ffmpeg, S3FD, энкод (кроп+x264), ASR (нарезка звука + GPU) - за сессию."""
    with lock:
        n, na, tm = max(state["n_proc"], 1), max(state["n_acc"], 1), dict(state["tm"])
        nf, nq = state["n_full"], state["n_quick"]
    asr = ""
    try:
        st = json.loads((SPOOL / "stats.json").read_text())
        gpu = f"{st['sec'] / max(st['n'], 1):.3f}"
    except Exception:
        gpu = "-"
    if WANT_ASR:
        asr = f", ASR {tm['acut'] / na:.3f}+{gpu} (звук+GPU, в очереди {len(list(SPOOL.glob('*.req'))) if SPOOL.is_dir() else 0})"
    return (f"с/клип: декод {tm['dec'] / n:.3f}, S3FD {tm['s3fd'] / n:.3f} (полных {nf}, быстрых {nq}), "
            f"энкод {tm['enc'] / na:.3f}{asr}")


def monitor(args):
    """Раз в 30 с: пропускная способность; раз в 5 мин: рост числа потоков / снижение при ошибках."""
    last_t, last_b = time.time(), state["dl_bytes"] + tmp_inprogress_bytes()
    swap0, last_ramp = swap_used_mb(), time.time()
    last_err_check = time.time()
    while not stop.is_set():
        time.sleep(30)
        now = time.time()
        b = state["dl_bytes"] + tmp_inprogress_bytes()
        mbps = max(0.0, (b - last_b) / (now - last_t) / 1e6)
        last_t, last_b = now, b
        swap = swap_used_mb()
        with lock:
            recent = [t for ts, t in reqs if ts > now - 300]
        err_rate = (sum(recent) / len(recent)) if recent else 0.0
        el = (now - state["t0"]) / 60
        log(f"СТАТ: {timing_stat()} | загрузка {mbps:.1f} МБ/с ({mbps*8:.0f} Мбит/с), потоков {state['target']} (активных {state['active_dl']}), "
            f"в очереди кропа {state['queued']}, клипов {state['done']}, {state['done']/max(el,1e-9):.1f} клип/мин, "
            f"{state['hours']/max(el/60,1e-9):.2f} ч/ч, своп {swap:.0f} МБ ({swap - swap0:+.0f}), "
            f"запросов за 5 мин {len(recent)}, блокировок {err_rate*100:.0f}%")
        if len(recent) >= 20 and err_rate > 0.30 and now - last_err_check > 300:
            last_err_check = now
            with lock:
                state["target"] = max(state["min_workers"], state["target"] // 2)
            log(f"ВНИМАНИЕ: ошибок {err_rate*100:.0f}% запросов за 5 мин - потоков загрузки вдвое меньше: {state['target']}")
            sys.platform == "darwin" and subprocess.run(["osascript", "-e", f'display notification "YouTube блокирует {err_rate*100:.0f}% запросов, '
                            f'потоков уменьшено до {state["target"]}" with title "Сбор данных для губ"'], capture_output=True)
            last_ramp, swap0 = now, swap
        elif now - last_ramp >= 300:
            if swap - swap0 < 300 and err_rate == 0 and state["target"] < args.max_workers and time.time() - state["last_block_ts"] > QUIET_RAMP_S \
                    and time.time() >= state["backoff_until"]:
                with lock:
                    state["target"] = min(args.max_workers, state["target"] + 2)
                log(f"рост: потоков загрузки {state['target']}")
            last_ramp, swap0 = now, swap


# ---------------------------------------------------------------- сервис меток (GigaAM, один процесс)
ASR = {"proc": None, "closing": False, "ready": False}


def spool_pending():
    """Клипы, ждущие сервис меток: у них уже есть mp4/txt, json допишет сервис."""
    out = set()
    if SPOOL.is_dir():
        out |= {p.name[:-4] for p in SPOOL.glob("*.req")}
        out |= {p.name.split(".claimed.")[0] for p in SPOOL.glob("*.claimed.*")}
    return out


def spool_recover():
    """Заявки, взятые умершим сервисом, возвращаем в очередь; мусор убираем."""
    if not SPOOL.is_dir():
        return
    for c in SPOOL.glob("*.claimed.*"):
        try:
            os.kill(int(c.name.rsplit(".", 1)[1]), 0)
        except ProcessLookupError:
            os.replace(c, c.with_name(c.name.split(".claimed.")[0] + ".req"))
        except Exception:
            pass
    for f in list(SPOOL.glob("*.tmp*")) + [x for x in SPOOL.glob("*.npy") if time.time() - x.stat().st_mtime > 900
                                            and not (SPOOL / f"{x.stem}.req").exists()]:
        f.unlink(missing_ok=True)


def spool_flush_unlabeled(why):
    """Сервис недоступен: заявки превращаем в обычные json без asr_text/label_cer (клипы не теряем)."""
    from asr_service import write_json
    n = 0
    for r in list(SPOOL.glob("*.req")):
        try:
            req = json.loads(r.read_text())
            write_json(req["pub"], r.stem, req["meta"])
            n += 1
        except Exception as e:  # noqa
            log(f"метки: заявка {r.name}: {type(e).__name__}: {e}")
        r.unlink(missing_ok=True)
        (SPOOL / f"{r.stem}.npy").unlink(missing_ok=True)
    if n:
        log(f"метки: {n} клипов записано без asr_text ({why})")


def asr_supervisor():
    """Держит один процесс fetch/asr_service.py; 3 сбоя за 10 мин или нет бэкенда -> метки отключены (флаг DISABLED),
    сборщик работает дальше без них."""
    py = os.environ.get("LIPREAD_ASR_PY") or sys.executable
    fails = []
    SPOOL.mkdir(parents=True, exist_ok=True)
    (SPOOL / "DISABLED").unlink(missing_ok=True)
    while not ASR["closing"]:
        t0 = time.time()
        ASR["ready"] = False
        p = subprocess.Popen([py, str(FETCH / "asr_service.py"), "--spool", str(SPOOL)], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, text=True)
        ASR["proc"] = p

        def rd(pp=p):
            for line in pp.stdout:
                if '"ready"' in line:
                    ASR["ready"] = True
                    log(f"метки: сервис GigaAM готов {line.strip()} (pid {pp.pid})")
        threading.Thread(target=rd, daemon=True).start()
        while p.poll() is None:
            if not ASR["ready"] and time.time() - t0 > 600:
                log("метки: сервис не поднялся за 10 мин, убиваю")
                p.kill()
            time.sleep(1)
        if ASR["closing"]:
            return
        fails = [t for t in fails if t > time.time() - 600] + [time.time()]
        log(f"ВНИМАНИЕ: сервис меток завершился с кодом {p.returncode} (сбоев за 10 мин: {len(fails)})")
        if p.returncode == 3 or len(fails) >= 3:
            (SPOOL / "DISABLED").touch()
            log("ВНИМАНИЕ: метки GigaAM отключены, клипы пишутся без asr_text")
            time.sleep(1)
            spool_flush_unlabeled("сервис меток отключён")
            return
        time.sleep(5)


def asr_stop():
    ASR["closing"] = True
    p = ASR["proc"]
    if p is None:
        return
    try:
        p.stdin.close()
        p.wait(timeout=300)
    except Exception:  # noqa
        p.kill()
    spool_flush_unlabeled("сервис меток остановлен")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--selection", default=str(FETCH / "selection_ru.jsonl"))
    ap.add_argument("--target-hours", type=float, default=15.0, help="остановиться, когда готово столько часов")
    ap.add_argument("--workers", type=int, default=16, help="стартовое число потоков загрузки")
    ap.add_argument("--max-workers", type=int, default=24, help="потолок роста потоков (жёстко не больше 24)")
    ap.add_argument("--cookies", default=None, help="файл cookies (Netscape) для yt-dlp; по умолчанию fetch/cookies.txt, если есть")
    ap.add_argument("--crop-procs", type=int, default=5, help="процессов кропа (каждый ~600 МБ из-за torch; 12 давали своп; жёстко не больше 8)")
    ap.add_argument("--hw-encode", action="store_true", help="h264_videotoolbox (на 224x224 медленнее libx264, по замеру)")
    ap.add_argument("--no-cookies", action="store_true", help="не использовать fetch/cookies.txt (проверки)")
    ap.add_argument("--limit-videos", type=int, default=0)
    args = ap.parse_args()
    args.max_workers = min(args.max_workers, MAX_WORKERS_CAP)
    args.workers = min(args.workers, args.max_workers)
    args.crop_procs = min(args.crop_procs, MAX_CROP_PROCS)
    cpath = args.cookies or (str(FETCH / "cookies.txt") if (FETCH / "cookies.txt").is_file() and not args.no_cookies else None)
    if cpath:
        if not os.path.isfile(cpath):
            sys.exit(f"файл cookies не найден: {cpath}")
        if os.stat(cpath).st_mode & 0o077:
            os.chmod(cpath, 0o600)
        COOKIES[0] = cpath  # содержимое не читаем и не логируем, только копируем в личный файл ролика
        state["cookies"] = True
    HW["enc"] = args.hw_encode
    PUB.mkdir(parents=True, exist_ok=True)
    shutil.rmtree(TMP, ignore_errors=True)
    TMP.mkdir(parents=True, exist_ok=True)
    state["target"] = args.workers
    # осиротевшие файлы оборванных клипов (json пишется последним; ждущие метку - не сироты)
    spool_recover()
    waiting = spool_pending()
    for ext in ("mp4", "txt", "npy", "tmp.mp4", "tmp.npy"):
        for f in PUB.glob(f"*.{ext}"):
            stem = f.name[: -len(ext) - 1]
            if stem.endswith(".tmp"):
                stem = stem[:-4]
            if not (PUB / f"{stem}.json").exists() and stem not in waiting:
                f.unlink(missing_ok=True)
    signal.signal(signal.SIGTERM, lambda *_: (log("SIGTERM: останавливаюсь после текущих роликов"), stop.set()))
    signal.signal(signal.SIGINT, lambda *_: (log("SIGINT: останавливаюсь после текущих роликов"), stop.set()))

    byv = collections.OrderedDict()
    for l in open(args.selection):
        c = json.loads(l)
        c["clip_id_out"] = clip_id(c)
        byv.setdefault(c["video_id"], []).append(c)
    base_h, n0 = 0.0, 0
    for j in PUB.glob("*.json"):
        try:
            base_h += json.loads(j.read_text()).get("frames", 0) / 25 / 3600
            n0 += 1
        except Exception:
            pass
    log(f"СТАРТ pid={os.getpid()} роликов {len(byv)}, клипов {sum(map(len, byv.values()))}; уже готово {n0} клипов, "
        f"{base_h:.2f} ч; цель {args.target_hours} ч; потоков загрузки {args.workers}->{args.max_workers}, "
        f"процессов кропа {args.crop_procs}, hw-encode {args.hw_encode}, куки {'да (' + Path(cpath).name + ')' if cpath else 'нет'}")
    items = list(byv.items())
    if args.limit_videos:
        items = items[:args.limit_videos]
    it = iter(items)
    itlock = threading.Lock()
    slots = threading.Semaphore(args.crop_procs * 2)

    import multiprocessing as mp
    pool = ProcessPoolExecutor(args.crop_procs, mp_context=mp.get_context("spawn"), initializer=child_init)

    exhausted = threading.Event()

    def worker(idx):
        while not stop.is_set() and not exhausted.is_set():
            if idx >= state["target"]:
                time.sleep(3)
                continue
            if STOPF.exists():
                stop.set()
                break
            wait_backoff()
            if stop.is_set():
                break
            if base_h + state["hours"] >= args.target_hours:
                log(f"цель {args.target_hours} ч достигнута")
                stop.set()
                break
            with itlock:
                nxt = next(it, None)
            if nxt is None:
                exhausted.set()
                break
            try:
                download_and_submit(nxt[0], nxt[1], pool, slots, args)
            except Exception as e:  # noqa
                log(f"{nxt[0]}: необработанная ошибка {type(e).__name__}: {e}")

    threading.Thread(target=monitor, args=(args,), daemon=True).start()
    if WANT_ASR:
        threading.Thread(target=asr_supervisor, daemon=True).start()
    threads = [threading.Thread(target=worker, args=(i,)) for i in range(args.max_workers)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    pool.shutdown(wait=True)
    if WANT_ASR:
        asr_stop()
    stop.set()
    log(f"КОНЕЦ: клипов за сессию {state['done']}, {state['hours']:.2f} ч, ошибок {state['failed']}")


if __name__ == "__main__":
    main()
