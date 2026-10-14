"""Обёртки над yt-dlp / ffmpeg: поиск, метаданные, проба (30 с из середины), полная загрузка."""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import time
from pathlib import Path

NICE = ["nice", "-n", "10"]
THROTTLE = ("429", "Too Many Requests", "HTTP Error 403", "Sign in to confirm you", "confirm you’re not a bot",
            "confirm you're not a bot", "rate-limit", "rate limit", "page needs to be reloaded")
PERMANENT = ("Video unavailable", "Private video", "has been removed", "This video is not available", "copyright",
             "no longer available", "members-only", "Join this channel", "age-restricted",
             "Sign in to confirm your age", "terminated", "not made this video available", "live event",
             "This video has been", "is not available")
# куки пользователя (lipread/fetch/cookies.txt или YTDL_COOKIES); содержимое не печатать и не копировать
COOKIES = os.environ.get("YTDL_COOKIES") or str(Path(__file__).resolve().parent.parent / "fetch" / "cookies.txt")
YT = ["yt-dlp", "--no-warnings", "--no-playlist", "--retries", "3", "--fragment-retries", "3", "--socket-timeout", "30",
      "--sleep-requests", "1", "--sleep-interval", "2", "--max-sleep-interval", "6"]
# не более 2 одновременных обращений к YouTube (договорённость с основным сборщиком, тот же аккаунт)
import contextlib
import tempfile
import threading
NET = threading.BoundedSemaphore(2)


@contextlib.contextmanager
def cookie_args():
    """yt-dlp переписывает файл куки при выходе: параллельные запуски портят общий файл, поэтому у каждого вызова своя
    приватная копия (режим 600, удаляется сразу). Содержимое не читается и не логируется."""
    fd, tmp = tempfile.mkstemp(prefix=".ck_", suffix=".txt", dir=str(Path(__file__).resolve().parent / "work"))
    os.close(fd)
    try:
        shutil.copyfile(COOKIES, tmp)
        os.chmod(tmp, 0o600)
        yield ["--cookies", tmp]
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass
TRANSCRIPT = os.environ.get("YT_TRANSCRIPT_BIN") or str(Path.home() / "youtubetraskript-mcp-video/.build/release/transcript")


def classify(err: str) -> str:
    if any(k in err for k in THROTTLE):
        return "throttle"
    if any(k in err for k in PERMANENT):
        return "permanent"
    return "error" if err.strip() else "ok"


def search_flat(query: str, n: int = 50, timeout: int = 120):
    """ytsearchN: (entries, kind). entries: id,title,duration,channel,channel_id,description,view_count."""
    with NET:
        with cookie_args() as ck:
            p = subprocess.run(["yt-dlp", "--no-warnings", "--flat-playlist", *ck, "-J", f"ytsearch{n}:{query}"],
                               capture_output=True, text=True, timeout=timeout)
    if p.returncode != 0 or not p.stdout.strip():
        return [], classify(p.stderr)
    return json.loads(p.stdout).get("entries", []) or [], "ok"


def channel_videos(url: str, n: int = 30, timeout: int = 180):
    with NET:
        with cookie_args() as ck:
            p = subprocess.run(["yt-dlp", "--no-warnings", "--flat-playlist", *ck, "-J", "--playlist-end", str(n), url],
                               capture_output=True, text=True, timeout=timeout)
    if p.returncode != 0 or not p.stdout.strip():
        return [], classify(p.stderr)
    return json.loads(p.stdout).get("entries", []) or [], "ok"


def transcript_find(query: str, limit: int = 30, lang="ru", min_dur=300, max_dur=7200, timeout=180):
    """Dwnldio `transcript find`: видео с ручными субтитрами. -> список dict(video_id,title,channel,duration_sec,...)."""
    p = subprocess.run([TRANSCRIPT, "find", query, "--lang", lang, "--limit", str(limit), "--min-duration", str(min_dur),
                        "--max-duration", str(max_dur), "--format", "json"], capture_output=True, text=True, timeout=timeout)
    try:
        return json.loads(p.stdout).get("videos", [])
    except Exception:
        return []


def transcript_manual(vid: str, timeout=60):
    """Ручные русские субтитры -> [{start,end,text}] или None."""
    p = subprocess.run([TRANSCRIPT, "get", vid, "--lang", "ru", "--manual-only", "--format", "json"],
                       capture_output=True, text=True, timeout=timeout)
    try:
        d = json.loads(p.stdout)
    except Exception:
        return None
    if d.get("isGenerated") or d.get("isTranslated"):
        return None
    out = []
    for s in d.get("segments", []):
        out.append({"start": float(s["start"]), "end": float(s["start"]) + float(s["duration"]), "text": s["text"]})
    return out or None


def yt_info(vid: str, timeout=120):
    """Полные метаданные (yt-dlp -j). -> (info|None, kind, err)."""
    try:
        with NET:
            with cookie_args() as ck:
                p = subprocess.run(YT + ck + ["-j", "--skip-download", f"https://www.youtube.com/watch?v={vid}"],
                                   capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None, "error", "timeout"
    if p.returncode != 0 or not p.stdout.strip():
        return None, classify(p.stderr), p.stderr[-300:]
    return json.loads(p.stdout.splitlines()[0]), "ok", ""


def pick_formats(info: dict):
    """Видео: высота 240..360 (макс.), https раньше HLS, затем bitrate; аудио: дорожка оригинала."""
    vf = [f for f in info.get("formats", []) if f.get("vcodec") not in (None, "none") and f.get("acodec") in (None, "none")
          and f.get("height") and 240 <= f["height"] <= 360 and f.get("url")]
    if not vf:
        return None, None
    vf.sort(key=lambda f: (f["height"], (f.get("fps") or 0) >= 24, f.get("protocol", "").startswith("http") and "m3u8" not in f.get("protocol", ""),
                           f.get("tbr") or 0), reverse=True)
    af = [f for f in info.get("formats", []) if f.get("acodec") not in (None, "none") and f.get("vcodec") in (None, "none") and f.get("url")]
    if not af:
        return vf[0], None
    af.sort(key=lambda f: ((f.get("language_preference") or 0) >= 0, "original" in (f.get("format_note") or "").lower() or "default" in (f.get("format_note") or "").lower(),
                           "drc" not in f.get("format_id", ""), f.get("abr") or f.get("tbr") or 0), reverse=True)
    return vf[0], af[0]


def _hdr(f):
    return "".join(f"{k}: {v}\r\n" for k, v in (f.get("http_headers") or {}).items())


def download_probe(info: dict, vf, af, t0: float, dur: float, out: Path, timeout=180):
    """30-секундная проба через ffmpeg по прямым ссылкам, без перекодирования (-c copy). -> (ok, kind, err)."""
    cmd = NICE + ["ffmpeg", "-v", "error", "-y", "-nostdin", "-headers", _hdr(vf), "-ss", f"{t0:.2f}", "-i", vf["url"]]
    if af:
        cmd += ["-headers", _hdr(af), "-ss", f"{t0:.2f}", "-i", af["url"]]
    cmd += ["-t", f"{dur:.2f}", "-map", "0:v:0"] + (["-map", "1:a:0"] if af else []) + ["-c", "copy", str(out)]
    try:
        with NET:
            p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        out.unlink(missing_ok=True)
        return False, "error", "timeout"
    if p.returncode != 0 or not out.exists() or out.stat().st_size < 10000:
        out.unlink(missing_ok=True)
        return False, classify(p.stderr), p.stderr[-300:]
    return True, "ok", ""


def download_full(vid: str, info: dict, vf, af, outdir: Path, timeout=3600):
    """Полная загрузка выбранных форматов (видео<=360p + звук) в один mkv. Параллельные фрагменты -N 8."""
    outdir.mkdir(parents=True, exist_ok=True)
    ckcm = cookie_args()
    ck = ckcm.__enter__()
    cmd = NICE + YT + ck + ["-N", "8", "-f", f"{vf['format_id']}+{af['format_id']}" if af else vf["format_id"],
                       "--merge-output-format", "mkv", "-o", str(outdir / "video.%(ext)s"),
                       f"https://www.youtube.com/watch?v={vid}"]
    try:
        with NET:
            p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None, "error", "timeout"
    finally:
        ckcm.__exit__(None, None, None)
    files = [f for f in outdir.glob("video.*") if f.suffix not in (".part", ".ytdl")]
    if files:
        return files[0], "ok", ""
    return None, classify(p.stderr), p.stderr[-400:]


def ffprobe_stream(path: Path):
    p = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                        "stream=codec_name,width,height,avg_frame_rate,r_frame_rate,nb_frames:format=duration,bit_rate,size",
                        "-of", "json", str(path)], capture_output=True, text=True)
    d = json.loads(p.stdout)
    s = d["streams"][0]
    def fr(x):
        a, b = x.split("/")
        return float(a) / float(b) if float(b) else 0.0
    return {"codec": s["codec_name"], "w": s["width"], "h": s["height"], "fps": fr(s["avg_frame_rate"]) or fr(s["r_frame_rate"]),
            "dur": float(d["format"].get("duration") or 0), "size": int(d["format"].get("size") or 0)}


def video_kbps(path: Path):
    """Битрейт видеопотока по пакетам (kbit/s)."""
    p = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "packet=size,pts_time",
                        "-of", "csv=p=0", str(path)], capture_output=True, text=True)
    sz, ts = 0, []
    for l in p.stdout.splitlines():
        a = l.split(",")
        try:
            sz += int(a[1]); ts.append(float(a[0]))
        except Exception:
            pass
    if len(ts) < 2:
        return 0.0
    return sz * 8 / 1000 / max(max(ts) - min(ts), 1e-3)
