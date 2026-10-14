#!/usr/bin/env python3
"""Сборщик НОВОГО русского talking-head видео для обучения чтению по губам (ролики, которых нет в MultiVSR).

Стадии (каждое сито пишет событие в state.db, из них считаются проценты прохождения: `collect.py report`):
  s1_flat   метаданные из поиска (без загрузки): длительность 5-120 мин, жанр/ключевые слова, кириллица в названии
  s1b_thumb 3 автокадра превью (i.ytimg.com, без API видео): лицо крупное в >= 2 из 3 (дёшево отсекает видео без лиц)
  s2_meta   полные метаданные yt-dlp: категория, язык, описание, live, есть формат 240-360p, не более 3 роликов на канал
  s2b_story раскадровка YouTube (sb0, ~54 кадра по всему ролику, тоже картинки): доля кадров с крупным одиночным лицом
  s3_tech   проба 30 с из середины (360p, без перекодирования): fps >= 24, битрейт, чёткость лица
  s4_face   лицо в >70% кадров, высота рамки (в терминах S3FD) >= 90 px при 360p, одно доминантное лицо, анфас
  s5_speech речь в пробе (Silero VAD) и разборчивые слова (GigaAM, >= 1.2 слова/с)
  s6_sync   пробная синхронность губ и звука (корреляция раскрытия рта и речевой энергии)
  s7_video  по всему ролику (после загрузки): доля сегментов, прошедших порог синхронности, и разница с нулевой моделью
  s8_clips  сегменты 2-10 с: непрерывный трек лица, синхронность сегмента, метка GigaAM, WER к ручным субтитрам <= 15%,
            без тегов [музыка]; кроп лица как у MultiVSR (preprocess.py) -> data/public_new/<id>.{mp4,txt,json}

Запуск:
  collect.py run [--target-hours 100] [--limit-videos N] [--workers 4] [--procs 3]   # сбор, возобновляемо
  collect.py report                                                                  # проценты по ситам, часы, распределение
Остановка: touch newdata/STOP (мягко) или kill <PID>. Сеть: куки пользователя (fetch/cookies.txt), не более 2 одновременных
обращений к YouTube; 3 подряд бот-проверки -> остановка с уведомлением.
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import json
import os
import random
import re
import shutil
import signal
import sqlite3
import subprocess
import sys
import threading
import time
import zlib
from pathlib import Path

for _k in ("VECLIB_MAXIMUM_THREADS", "OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS"):
    os.environ.setdefault(_k, "1")

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
ROOT = HERE.parent
PUB = ROOT / "data" / "public_new"
META_RU = ROOT / "data" / "public_meta" / "ru.jsonl"
TMP = HERE / "work" / "tmp"
DB_PATH = HERE / "state.db"
LOG = HERE / "progress.log"
STOP = HERE / "STOP"
GIGAAM_PY = os.path.expanduser("~/.venvs/gigaam/bin/python")
DISK_CAP_GB = 30.0
MIN_FREE_GB = 12.0

SIEVES = ["s1_flat", "s1b_thumb", "s2_meta", "s2b_story", "s3_tech", "s4_face", "s5_speech", "s6_sync", "s7_video", "s8_clips"]

# пороги (calib.json: probe_sync_min задаётся калибровкой, см. README)
TH = {
    "dur_min": 300, "dur_max": 7200, "title_cyr": 0.4, "text_cyr": 0.5,
    "channel_cap_accept": 3, "channel_cap_probe": 6,
    "fps_min": 24.0, "kbps_eq_min": 100.0, "sharp_min": 25.0,
    "thumb_h_min": 60.0, "thumb_ok_min": 2, "story_face_frac": 0.30, "story_h_min": 80.0, "story_second_max": 0.30, "story_yaw_frac": 0.30,
    "face_frac_min": 0.70, "face_h_min": 90.0, "second_face_max": 0.20, "frontal_min": 0.60, "yaw_max": 0.30,
    "speech_frac_min": 0.40, "wps_min": 1.2,
    "probe_sync_min": 0.10,
    "seg_face_frac": 0.97, "seg_face_h_p10": 80.0, "seg_yaw_p90": 0.30, "seg_second_max": 0.10, "seg_sharp_med": 25.0,
    "seg_sync_floor": 0.12, "video_pass_frac": 0.18, "video_delta": 0.04,
    "wer_max": 0.15, "wps_seg_min": 0.8, "wps_seg_max": 5.5, "words_min": 3,
}

# ----------------------------------------------------------------------------------------------- ключевые слова
KW = {
    "music": r"клип|official (music )?video|lyric|\bпесн|\bпесня|\bmix\b|ремикс|remix|саундтрек|\bost\b|концерт|караоке|"
             r"\bкавер|\bcover\b|альбом|\bмузык|нарезка песен|\bsong\b|\bmv\b|\bfeat\b|\bft\.",
    "cartoon": r"мульт|аниме|анимаци|\bcartoon|animat",
    "gaming": r"прохожден|геймплей|gameplay|летсплей|let'?s play|minecraft|майнкрафт|\bdota|\bcs ?2\b|\bcs:go|\bgta\b|"
              r"fortnite|роблокс|roblox|\bстрим по игр|\bигровой стрим",
    "movie_dub": r"озвучк|дубляж|дублиров|\bперевод\b|\bперевод[ё]н|субтитр|закадров|\bфильм\b|сериал|трейлер|\bкино\b|"
                 r"\bсезон\b|\bсерия\b|полный фильм|\bdub\b|\bdubbed\b|на русском языке \(|rus ?sub|\bhdrezka|lostfilm",
    "voiceover_doc": r"документальн|документалк|голос за кадром|дикторск|дискавери|discovery|\bbbc earth|национальн\w+ географи",
    "screen": r"туториал|tutorial|скринкаст|как установить|настройк\w+ программ|урок по (excel|python|photoshop|word)|"
              r"обзор программ|\bexcel\b|photoshop|\bpython\b урок",
    "reaction": r"реакци[яи] на|\breaction\b|react to|разбор клип|смотрим вместе",
    "compilation": r"нарезка|сборник|подборка|лучшие моменты|best moments|\bshorts\b|#shorts|\basmr\b|тикток|tiktok",
}
KW_RE = {k: re.compile(v, re.I) for k, v in KW.items()}
BAD_CATEGORIES = {"Music", "Gaming", "Film & Animation", "Pets & Animals"}


def cyr_share(text: str) -> float:
    letters = re.findall(r"[A-Za-zА-Яа-яЁё]", text)
    if not letters:
        return 0.0
    return sum(1 for c in letters if "А" <= c <= "я" or c in "Ёё") / len(letters)


def kw_reject(text: str):
    for k, rx in KW_RE.items():
        if rx.search(text):
            return k
    return None


GENRES = ["интервью", "подкаст", "разговор", "влог", "лекция", "выступление", "TEDx на русском", "новости ведущий",
          "стрим разговорный", "монолог", "беседа с гостем", "публичная лекция", "ток-шоу", "доклад на конференции",
          "пресс-конференция", "рассказываю", "блог о жизни", "ответы на вопросы", "мнение эксперта", "откровенный разговор"]
TOPICS = ["психология", "экономика", "история", "наука", "политика", "технологии", "здоровье", "бизнес", "образование", "философия",
          "искусство", "литература", "медицина", "право", "путешествия", "отношения", "карьера", "дети и воспитание", "спорт",
          "религия", "космос", "программирование", "маркетинг", "инвестиции", "иностранные языки", "архитектура", "психотерапия",
          "предпринимательство", "общество", "культура"]


def query_list():
    base = [f"{g} {t}" for g in GENRES for t in TOPICS]
    random.Random(7).shuffle(base)
    qs = list(base)
    for y in (2025, 2024, 2023, 2022, 2021, 2020, 2019, 2018):  # расширение: тот же набор с годом (другая выдача)
        ys = [f"{q} {y}" for q in base]
        random.Random(y).shuffle(ys)
        qs += ys
    return qs


# ----------------------------------------------------------------------------------------------- состояние
class DB:
    def __init__(self, path=DB_PATH):
        self.lock = threading.RLock()
        self.c = sqlite3.connect(str(path), check_same_thread=False, timeout=60)
        self.c.executescript("""
        CREATE TABLE IF NOT EXISTS videos(video_id TEXT PRIMARY KEY, title TEXT, channel TEXT, channel_id TEXT, dur REAL,
            source TEXT, status TEXT, stage TEXT, reason TEXT, info TEXT, probe TEXT, clips INTEGER DEFAULT 0, clip_sec REAL DEFAULT 0,
            added REAL, updated REAL);
        CREATE TABLE IF NOT EXISTS events(video_id TEXT, sieve TEXT, passed INTEGER, reason TEXT, ts REAL);
        CREATE TABLE IF NOT EXISTS queries(q TEXT PRIMARY KEY, ts REAL, n INTEGER, kind TEXT);
        CREATE TABLE IF NOT EXISTS kv(k TEXT PRIMARY KEY, v TEXT);
        CREATE INDEX IF NOT EXISTS ev_s ON events(sieve);
        CREATE INDEX IF NOT EXISTS v_status ON videos(status);
        """)
        self.c.commit()

    def q(self, sql, args=(), one=False, commit=False):
        with self.lock:
            cur = self.c.execute(sql, args)
            if commit:
                self.c.commit()
            return (cur.fetchone() if one else cur.fetchall())

    def event(self, vid, sieve, passed, reason=""):
        self.q("INSERT INTO events VALUES(?,?,?,?,?)", (vid, sieve, int(passed), reason, time.time()), commit=True)

    def set(self, vid, **kw):
        kw["updated"] = time.time()
        cols = ",".join(f"{k}=?" for k in kw)
        self.q(f"UPDATE videos SET {cols} WHERE video_id=?", (*kw.values(), vid), commit=True)

    def add_candidate(self, e: dict, source: str):
        with self.lock:
            cur = self.c.execute(
                "INSERT OR IGNORE INTO videos(video_id,title,channel,channel_id,dur,source,status,added,updated) VALUES(?,?,?,?,?,?,?,?,?)",
                (e["id"], e.get("title"), e.get("channel"), e.get("channel_id") or e.get("channel"), e.get("duration"), source, "new",
                 time.time(), time.time()))
            self.c.commit()
            return cur.rowcount > 0

    def kv_get(self, k, default=None):
        r = self.q("SELECT v FROM kv WHERE k=?", (k,), one=True)
        return json.loads(r[0]) if r else default

    def kv_set(self, k, v):
        self.q("INSERT OR REPLACE INTO kv VALUES(?,?)", (k, json.dumps(v)), commit=True)


DBH: DB = None  # type: ignore
log_lock = threading.Lock()


def log(msg):
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}"
    with log_lock:
        with open(LOG, "a") as f:
            f.write(line + "\n")
    print(line, flush=True)


def notify(msg):
    last = DBH.kv_get("last_notify", 0)
    if time.time() - last < 900:
        return
    DBH.kv_set("last_notify", time.time())
    msg = msg.replace('"', "'")
    subprocess.run(["osascript", "-e", f'display notification "{msg}" with title "Сбор данных для губ"'], capture_output=True)


def load_calib():
    p = HERE / "calib.json"
    if p.exists():
        d = json.loads(p.read_text())
        for k in list(TH):
            if k in d:
                TH[k] = d[k]
        return d
    return {}


# ----------------------------------------------------------------------------------------------- сито 1
_multivsr_ids: set | None = None


def multivsr_ids():
    global _multivsr_ids
    if _multivsr_ids is None:
        ids = set()
        for p in (META_RU, ROOT / "data" / "public_meta" / "ru_csv.jsonl", ROOT / "fetch" / "selection_ru.jsonl"):
            if p.exists():
                with open(p) as f:
                    for line in f:
                        m = re.search(r'"video_id": "([^"]+)"', line)
                        if m:
                            ids.add(m.group(1))
        _multivsr_ids = ids
    return _multivsr_ids


def s1_flat(e: dict):
    """-> причина отказа или None."""
    dur = e.get("duration")
    if not dur:
        return "no_duration"
    if e.get("live_status") in ("is_live", "is_upcoming"):
        return "live"
    if not (TH["dur_min"] <= dur <= TH["dur_max"]):
        return "duration"
    title = e.get("title") or ""
    if cyr_share(title) < TH["title_cyr"]:
        return "lang_title"
    k = kw_reject(f"{title} {e.get('description') or ''}")
    if k:
        return f"kw_{k}"
    return None


_retries: dict = {}


class Throttle(Exception):
    pass


class BotCheckStop(Exception):
    pass


_consec_throttle = [0]
_stop = threading.Event()


def net_result(kind: str):
    """Учёт подряд идущих блокировок. 3 подряд -> остановка."""
    with log_lock:
        if kind == "throttle":
            _consec_throttle[0] += 1
        elif kind == "ok":
            _consec_throttle[0] = 0
        n = _consec_throttle[0]
    if kind == "throttle":
        log(f"ВНИМАНИЕ: бот-проверка/429 от YouTube ({n} подряд)")
        if n >= 3:
            _stop.set()
            (HERE / "STOPPED_BOT").write_text(time.strftime("%F %T") + " 3 подряд бот-проверки, сбор остановлен\n")
            notify("YouTube: 3 подряд бот-проверки, сбор newdata остановлен")
            raise BotCheckStop()
        time.sleep(30 * n)


def discover(limit_new: int):
    """Один шаг поиска: следующий запрос -> новые кандидаты прошли s1. Возвращает число новых прошедших."""
    import ytdl
    done = {r[0] for r in DBH.q("SELECT q FROM queries")}
    todo = [q for q in query_list() if q not in done]
    if not todo:
        return 0
    q = todo[0]
    kind = "find" if sum(map(ord, q)) % 3 == 0 else "search"
    entries = []
    if kind == "find":
        for v in ytdl.transcript_find(q, limit=30, min_dur=TH["dur_min"], max_dur=TH["dur_max"]):
            entries.append({"id": v["video_id"], "title": v.get("title"), "channel": v.get("channel"),
                            "duration": v.get("duration_sec"), "manual_caps": True})
        res_kind = "ok"
    else:
        entries, res_kind = ytdl.search_flat(q, 40)
    if res_kind == "throttle":
        net_result("throttle")
    else:
        net_result("ok")
    DBH.q("INSERT OR REPLACE INTO queries VALUES(?,?,?,?)", (q, time.time(), len(entries), kind), commit=True)
    new = add_entries(entries, kind)
    log(f"поиск [{kind}] «{q}»: {len(entries)} результатов, прошли s1: {new}")
    return new


def add_entries(entries, source):
    """S0 (исключить MultiVSR и уже известные) + сито s1_flat. -> число прошедших."""
    new = 0
    ids = multivsr_ids()
    for e in entries:
        vid = e.get("id")
        if not vid or len(vid) != 11:
            continue
        if vid in ids:
            continue  # S0: уже в MultiVSR (не считается ситом, только исключение)
        if not DBH.add_candidate(e, source):
            continue
        why = s1_flat(e)
        DBH.event(vid, "s1_flat", why is None, why or "")
        if why:
            DBH.set(vid, status="rej", stage="s1_flat", reason=why)
        else:
            DBH.set(vid, status="s1_ok")
            new += 1
    return new


def channel_boost(vid):
    """Канал принятого ролика - хороший источник: добавляем его другие ролики в начало очереди (лимит 3 принятых на канал сохраняется)."""
    import ytdl
    chan = DBH.q("SELECT channel_id FROM videos WHERE video_id=?", (vid,), one=True)[0]
    if not chan or not str(chan).startswith("UC"):
        return
    entries, kind = ytdl.channel_videos(f"https://www.youtube.com/channel/{chan}/videos", 40)
    net_result("throttle" if kind == "throttle" else "ok")
    for e in entries:
        e.setdefault("channel_id", chan)
    n = add_entries(entries, "channel")
    log(f"канал {chan}: добавлено кандидатов {n} из {len(entries)}")


# ----------------------------------------------------------------------------------------------- проба
_asr_lock = threading.Lock()
_asr_proc = {}


class ASR:
    """Постоянный подпроцесс GigaAM v3 (окружение ~/.venvs/gigaam)."""

    def __init__(self):
        self.p = subprocess.Popen([GIGAAM_PY, str(HERE / "asr_worker.py")], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, text=True, bufsize=1)
        line = self.p.stdout.readline()
        if '"ready"' not in line:
            raise RuntimeError(f"ASR не стартовал: {line!r}")
        self.n = 0

    def transcribe(self, wav: Path) -> str:
        self.n += 1
        self.p.stdin.write(json.dumps({"id": self.n, "wav": str(wav)}) + "\n")
        self.p.stdin.flush()
        r = json.loads(self.p.stdout.readline())
        if "error" in r:
            raise RuntimeError(r["error"])
        return r["text"]

    def close(self):
        try:
            self.p.stdin.close()
            self.p.wait(timeout=10)
        except Exception:
            self.p.kill()


def get_asr():
    key = os.getpid()  # один подпроцесс GigaAM на процесс (доступ под _asr_lock)
    if key not in _asr_proc:
        _asr_proc[key] = ASR()
    return _asr_proc[key]


_probe_lock = threading.Lock()  # FaceMesh/Silero в родительском процессе - по одному


def write_wav(path: Path, audio):
    import soundfile as sf
    sf.write(str(path), audio, 16000, subtype="PCM_16")


def analyze_probe(path: Path, tbr_info: dict):
    """Анализ 30-секундной пробы. Возвращает (метрики, sieve, reason) - первое сработавшее сито отказа или (m, None, None)."""
    import numpy as np
    import analysis as A
    import ytdl
    import vision as V
    m = {}
    st = ytdl.ffprobe_stream(path)
    kbps = ytdl.video_kbps(path)
    codec_k = {"h264": 1.0, "vp9": 1.4, "av1": 1.9, "hevc": 1.5}.get(st["codec"], 1.0)
    m.update(fps=round(st["fps"], 2), codec=st["codec"], kbps=round(kbps), kbps_eq=round(kbps * codec_k), h=st["h"], w=st["w"])
    if st["fps"] < TH["fps_min"] - 0.5:
        return m, "s3_tech", "fps"
    if kbps * codec_k < TH["kbps_eq_min"]:
        return m, "s3_tech", "bitrate"
    t = min(30.0, st["dur"])
    with _probe_lock:
        frames = V.decode_frames(path, None, t, out_h=360)
        if len(frames) < 100:
            return m, "s3_tech", "short"
        o = V.analyze_frames(frames)
        audio = V.decode_audio(path, None, t)
        n = len(frames)
        env = V.audio_envelope(audio, n)
        speech = A.vad_intervals(audio)
    face = o["face"] > 0
    ky = V.load_calib()["box"]["ky"]
    fh = o["fh"] * ky
    m["face_frac"] = round(float(face.mean()), 3)
    m["sharp"] = round(float(np.median(o["sharp"][face])), 1) if face.any() else 0.0
    if face.any() and m["sharp"] < TH["sharp_min"]:
        return m, "s3_tech", "blurry"
    m["face_h"] = round(float(np.median(fh[face])), 1) if face.any() else 0.0
    m["second"] = round(float((o["second"] > 0.5).mean()), 3)
    m["yaw_ok"] = round(float(((o["yaw"] <= TH["yaw_max"]) & face).sum() / max(face.sum(), 1)), 3)
    if m["face_frac"] < TH["face_frac_min"]:
        return m, "s4_face", "face_frac"
    if m["face_h"] < TH["face_h_min"]:
        return m, "s4_face", "face_small"
    if m["second"] > TH["second_face_max"]:
        return m, "s4_face", "multi_face"
    if m["yaw_ok"] < TH["frontal_min"]:
        return m, "s4_face", "not_frontal"
    sm = np.zeros(n, bool)
    for s, e in speech:
        sm[int(s * 25):int(e * 25)] = True
    m["speech_frac"] = round(float(sm.mean()), 3)
    if m["speech_frac"] < TH["speech_frac_min"]:
        return m, "s5_speech", "no_speech"
    wav = path.with_suffix(".wav")
    write_wav(wav, audio)
    with _asr_lock:
        text = get_asr().transcribe(wav)
    wav.unlink(missing_ok=True)
    import textnorm
    nw = len(textnorm.words(text))
    m["wps"] = round(nw / max(float(sm.sum()) / 25, 1.0), 2)
    m["asr_text"] = text[:120]
    if m["wps"] < TH["wps_min"]:
        return m, "s5_speech", "asr_sparse"
    la = A.lipact(o, face)
    r = A.rmax(V._prep(la), V._prep(env))
    nulls = [A.rmax(V._prep(la), V._prep(np.roll(env, s))) for s in range(100, n - 100, 60)]
    m["sync_r"] = round(r, 3)
    m["sync_null_p95"] = round(float(np.percentile(nulls, 95)), 3)
    if r < TH["probe_sync_min"]:
        return m, "s6_sync", "low_sync"
    return m, None, None


def _fetch_img(url, tries=2):
    import urllib.request
    import cv2
    import numpy as np
    for _ in range(tries):
        try:
            d = urllib.request.urlopen(url, timeout=20).read()
            return cv2.cvtColor(cv2.imdecode(np.frombuffer(d, np.uint8), 1), cv2.COLOR_BGR2RGB)
        except Exception:
            time.sleep(1)
    return None


def thumb_check(vid):
    """3 автокадра превью (480x360, видео 16:9 с чёрными полосами: масштаб к 360p ~0.75). -> (ok, reason, stats)."""
    import vision as V
    good = 0
    hs = []
    got = 0
    for k in ("hq1", "hq2", "hq3"):
        img = _fetch_img(f"https://i.ytimg.com/vi/{vid}/{k}.jpg")
        if img is None:
            continue
        got += 1
        with _probe_lock:
            r = V.FaceFeat(2, static=True).step(img)
        h = r["fh"] * V.load_calib()["box"]["ky"]
        if r["face"] and h >= TH["thumb_h_min"] and r["second"] < 0.5 and r["yaw"] <= 0.35:
            good += 1
            hs.append(round(h))
    st = {"thumb_good": good, "thumb_got": got, "thumb_h": hs}
    if got == 0:
        return True, "", st  # превью недоступны - не отсекаем
    return good >= TH["thumb_ok_min"], "no_face_thumbs", st


def story_check(info, vf):
    """Раскадровка sb0: ~54 кадра по всему ролику. Лицо крупное/одиночное/анфас. -> (ok, reason, stats)."""
    import cv2
    import numpy as np
    import vision as V
    sb = [f for f in info.get("formats", []) if f.get("format_id") == "sb0" and f.get("fragments")]
    if not sb:
        return True, "", {"story": "none"}
    sb = sb[0]
    fr = sb["fragments"]
    tw, th, rows, cols = sb["width"], sb["height"], sb["rows"], sb["columns"]
    scale = tw / float(vf.get("width") or 640)  # масштаб плитки относительно кадра видео
    idx = sorted(set(np.linspace(0, len(fr) - 1, min(6, len(fr))).astype(int).tolist()))
    n = face = ok_yaw = multi = 0
    hs = []
    for i in idx:
        sheet = _fetch_img(fr[i]["url"])
        if sheet is None:
            continue
        for rr in range(rows):
            for cc in range(cols):
                t = sheet[rr * th:(rr + 1) * th, cc * tw:(cc + 1) * tw]
                if t.shape[0] < th or t.shape[1] < tw or t.mean() < 6:
                    continue
                n += 1
                with _probe_lock:
                    r = V.FaceFeat(2, static=True).step(np.ascontiguousarray(t))
                if r["face"]:
                    face += 1
                    hs.append(r["fh"] * V.load_calib()["box"]["ky"] / scale * (360.0 / float(vf.get("height") or 360)))
                    ok_yaw += r["yaw"] <= 0.35
                    multi += r["second"] > 0.5
    if n < 12:
        return True, "", {"story": f"few_tiles_{n}"}
    st = {"story_n": n, "story_face_frac": round(face / n, 2), "story_h_med": round(float(np.median(hs)), 1) if hs else 0.0,
          "story_multi": round(multi / max(face, 1), 2), "story_yaw_ok": round(ok_yaw / max(face, 1), 2)}
    if st["story_face_frac"] < TH["story_face_frac"]:
        return False, "story_face", st
    if st["story_h_med"] < TH["story_h_min"]:
        return False, "story_small", st
    if st["story_multi"] > TH["story_second_max"]:
        return False, "story_multi", st
    if st["story_yaw_ok"] < TH["story_yaw_frac"]:
        return False, "story_yaw", st
    return True, "", st


def process_probe(vid: str):
    """Сито 2 (полные метаданные) + проба. Возвращает info-light dict при успехе, иначе None (статус и причина записаны)."""
    import ytdl
    row = DBH.q("SELECT channel_id,title FROM videos WHERE video_id=?", (vid,), one=True)
    chan = row[0]
    # лимит проб на канал
    nprobe = DBH.q("SELECT COUNT(DISTINCT e.video_id) FROM events e JOIN videos v ON v.video_id=e.video_id "
                   "WHERE v.channel_id=? AND e.sieve='s3_tech'", (chan,), one=True)[0]
    nacc = DBH.q("SELECT COUNT(*) FROM videos WHERE channel_id=? AND status IN ('probe_ok','inflight','done')", (chan,), one=True)[0]
    if nacc >= TH["channel_cap_accept"] or nprobe >= TH["channel_cap_probe"]:
        DBH.event(vid, "s2_meta", 0, "channel_cap")
        DBH.set(vid, status="rej", stage="s2_meta", reason="channel_cap")
        return None
    ok, why, tst = thumb_check(vid)
    DBH.event(vid, "s1b_thumb", ok, "" if ok else why)
    if not ok:
        DBH.set(vid, status="rej", stage="s1b_thumb", reason=why, probe=json.dumps(tst))
        return None
    DBH.set(vid, status="meta")
    info, kind, err = ytdl.yt_info(vid)
    if info is None:
        net_result(kind)
        if kind == "permanent":
            DBH.event(vid, "s2_meta", 0, "unavailable")
            DBH.set(vid, status="rej", stage="s2_meta", reason="unavailable")
        else:
            _retries[vid] = _retries.get(vid, 0) + 1
            if _retries[vid] >= 2:
                DBH.event(vid, "s2_meta", 0, "info_error")
                DBH.set(vid, status="rej", stage="s2_meta", reason="info_error")
            else:
                DBH.set(vid, status="s1_ok")  # повторим позже
            log(f"info {vid}: {kind} {err[-120:]}")
        return None
    net_result("ok")
    why = None
    cats = set(info.get("categories") or [])
    lang = (info.get("language") or "")
    desc = (info.get("description") or "")
    if info.get("is_live") or info.get("was_live"):
        why = "live"
    elif cats & BAD_CATEGORIES:
        why = "category_" + sorted(cats & BAD_CATEGORIES)[0].split()[0].lower()
    elif lang and not lang.lower().startswith("ru"):
        why = "lang_field"
    elif kw_reject(f"{info.get('title','')} {desc[:600]}"):
        why = "kw_" + kw_reject(f"{info.get('title','')} {desc[:600]}")
    elif cyr_share(f"{info.get('title','')} {desc[:500]}") < TH["text_cyr"]:
        why = "lang_text"
    vf = af = None
    if not why:
        vf, af = ytdl.pick_formats(info)
        if vf is None:
            why = "no_360p"
        elif (vf.get("fps") or 25) < TH["fps_min"] - 0.5:
            why = "fps_meta"
    if why:
        DBH.event(vid, "s2_meta", 0, why)
        DBH.set(vid, status="rej", stage="s2_meta", reason=why)
        return None
    DBH.event(vid, "s2_meta", 1)
    ok, why, sst = story_check(info, vf)
    DBH.event(vid, "s2b_story", ok, "" if ok else why)
    if not ok:
        DBH.set(vid, status="rej", stage="s2b_story", reason=why, probe=json.dumps(sst))
        return None
    light = {"title": info.get("title"), "channel": info.get("channel"), "dur": info.get("duration"), "cats": sorted(cats),
             "manual_ru": "ru" in (info.get("subtitles") or {}), "vf": vf["format_id"], "af": af["format_id"] if af else None,
             "codec": vf.get("vcodec"), "tbr": vf.get("tbr")}
    light["story"] = sst
    DBH.set(vid, status="probing", info=json.dumps(light, ensure_ascii=False))
    # проба: 30 с из середины (в пределах 25% - 75%)
    dur = float(info.get("duration") or 0)
    t0 = max(0.0, dur / 2 - 15)
    pdir = TMP / vid
    pdir.mkdir(parents=True, exist_ok=True)
    pf = pdir / "probe.mkv"
    ok, kind, err = ytdl.download_probe(info, vf, af, t0, 30, pf)
    if not ok:
        net_result(kind)
        DBH.event(vid, "s3_tech", 0, f"probe_dl_{kind}")
        DBH.set(vid, status="rej", stage="s3_tech", reason=f"probe_dl_{kind}")
        shutil.rmtree(pdir, ignore_errors=True)
        return None
    net_result("ok")
    try:
        m, sieve, reason = analyze_probe(pf, light)
    finally:
        shutil.rmtree(pdir, ignore_errors=True)
    # события по всем пройденным ситам до отказа
    order = ["s3_tech", "s4_face", "s5_speech", "s6_sync"]
    for s in order:
        if sieve is not None and order.index(s) > order.index(sieve):
            break
        passed = sieve != s
        DBH.event(vid, s, passed, "" if passed else reason)
    if sieve:
        DBH.set(vid, status="rej", stage=sieve, reason=reason, probe=json.dumps(m, ensure_ascii=False))
        return None
    DBH.set(vid, status="probe_ok", probe=json.dumps(m, ensure_ascii=False))
    light["probe"] = m
    return light


# ----------------------------------------------------------------------------------------------- полный ролик -> клипы
def seg_arrays_ok(o, a, b, ky):
    import numpy as np
    sl = slice(a, b)
    f = o["face"][sl] > 0
    n = b - a
    if f.mean() < TH["seg_face_frac"]:
        return "face_gap"
    # непрерывность: не более 3 подряд пропущенных кадров и нет смены лица
    miss = np.flatnonzero(~f)
    if len(miss):
        runs = np.split(miss, np.flatnonzero(np.diff(miss) > 1) + 1)
        if max(len(r) for r in runs) > 3:
            return "face_gap"
    if o["jump"][sl].sum() > 0:
        return "face_jump"
    fh = o["fh"][sl][f] * ky
    if np.percentile(fh, 10) < TH["seg_face_h_p10"]:
        return "face_small"
    if np.percentile(o["yaw"][sl][f], 90) > TH["seg_yaw_p90"]:
        return "not_frontal"
    if (o["second"][sl] > 0.5).mean() > TH["seg_second_max"]:
        return "multi_face"
    if np.median(o["sharp"][sl][f]) < TH["seg_sharp_med"]:
        return "blurry"
    return None


def label_text(text: str) -> str:
    import textnorm
    t = re.sub(r"[^0-9a-zа-яё\s]", " ", textnorm.TAG_RE.sub(" ", text.lower()))
    return re.sub(r"\s+", " ", t).strip()


def process_video(vid: str, video_path: str, light: dict, caps, workdir: str, seed: int = 0):
    """Выполняется в дочернем процессе. Все сито s7/s8. Возвращает dict-отчёт (клипы уже записаны в PUB)."""
    import numpy as np
    import analysis as A
    import textnorm
    import vision as V
    rng = np.random.default_rng(seed)
    path = Path(video_path)
    wd = Path(workdir)
    rep = {"vid": vid, "events": [], "clips": [], "stats": {}}
    t_start = time.time()
    audio = V.decode_audio(path)
    dur = len(audio) / V.SR
    n_total = int(dur * V.FPS)
    env = V.audio_envelope(audio, n_total)
    speech = A.vad_intervals(audio)
    cue_b = []
    if caps:
        for c in caps:
            cue_b += [c["start"], c["end"]]
    segs = A.pack_segments([tuple(x) for x in speech], env, dur, cue_b)
    rep["stats"].update(dur=round(dur, 1), speech_s=round(sum(e - s for s, e in speech), 1), n_seg=len(segs))
    if not segs:
        rep["events"].append(("s7_video", 0, "no_segments"))
        return rep
    # покадровые признаки лица только внутри сегментов (кадры вне сегментов пропускаются, но декодируются)
    mask = np.zeros(n_total + 50, bool)
    for s, e in segs:
        mask[int(s * V.FPS):int(e * V.FPS) + 2] = True
    ff = V.FaceFeat(2)
    rows = {k: np.zeros(n_total + 50, np.float32) for k in V.KEYS}
    last = -10
    for i, fr in enumerate(V.iter_frames(path, out_h=360)):
        if i >= len(mask):
            break
        if not mask[i]:
            continue
        if i != last + 1:
            ff.reset()
        last = i
        r = ff.step(fr)
        for k in V.KEYS:
            rows[k][i] = r[k]
    n = min(n_total, i + 1)
    ky = V.load_calib()["box"]["ky"]
    face = rows["face"] > 0
    la = A.lipact(rows, face & mask)
    # --- s8 сегментные проверки лица, затем синхронность
    cand = []
    seg_rej = {}
    for (s, e) in segs:
        a, b = int(round(s * V.FPS)), int(round(e * V.FPS))
        if b > n or b - a < 25 * 2 - 1:
            continue
        why = seg_arrays_ok(rows, a, b, ky)
        if why:
            seg_rej[why] = seg_rej.get(why, 0) + 1
            continue
        cand.append((a, b))
    rep["stats"]["seg_face_ok"] = len(cand)
    rep["stats"]["seg_face_rej"] = seg_rej
    if len(cand) < 5:
        rep["events"].append(("s7_video", 0, "few_face_segments"))
        return rep
    # синхронность сегментов и нулевая модель (звук из другого места ролика)
    r_seg = np.array([A.seg_sync(la, env, a, b) for a, b in cand])
    r_null = []
    for a, b in cand:
        for _ in range(2):
            sh = int(rng.integers(15 * V.FPS, max(15 * V.FPS + 1, n - 15 * V.FPS)))
            r_null.append(A.seg_sync(la, env, a, b, e_shift=sh))
    r_null = np.array(r_null)
    thr = max(TH["seg_sync_floor"], float(np.percentile(r_null, 95)))
    pass_frac = float((r_seg >= thr).mean())
    delta = float(r_seg.mean() - r_null.mean())
    rep["stats"].update(sync_thr=round(thr, 3), sync_pass_frac=round(pass_frac, 3), sync_delta=round(delta, 3),
                        sync_r_mean=round(float(r_seg.mean()), 3), sync_null_mean=round(float(r_null.mean()), 3))
    if pass_frac < TH["video_pass_frac"] or delta < TH["video_delta"]:
        rep["events"].append(("s7_video", 0, "low_sync"))
        rep["sync_r"] = r_seg.tolist()
        rep["sync_null"] = r_null.tolist()
        return rep
    rep["events"].append(("s7_video", 1, ""))
    keep = [(a, b, float(r)) for (a, b), r in zip(cand, r_seg) if r >= thr]
    # --- s8: ASR -> метка, WER к ручным субтитрам, теги
    asr = ASR()
    drops = {}
    out_clips = []
    cap_words = None
    if caps:
        cap_words = [(c["start"], c["end"], c["text"]) for c in caps]
    try:
        for a, b, r in keep:
            s, e = a / V.FPS, b / V.FPS
            wav = wd / f"seg_{a}.wav"
            write_wav(wav, audio[int(s * V.SR):int(e * V.SR)])
            try:
                text = asr.transcribe(wav)
            finally:
                wav.unlink(missing_ok=True)
            words = textnorm.words(text)
            dsec = e - s
            if len(words) < TH["words_min"]:
                drops["asr_empty"] = drops.get("asr_empty", 0) + 1
                continue
            wps = len(words) / dsec
            if not (TH["wps_seg_min"] <= wps <= TH["wps_seg_max"]):
                drops["wps"] = drops.get("wps", 0) + 1
                continue
            wer = None
            if cap_words is not None:
                ov = [c for c in cap_words if c[1] > s - 0.2 and c[0] < e + 0.2]
                if not ov:
                    drops["no_caption"] = drops.get("no_caption", 0) + 1
                    continue
                if any(textnorm.has_noise_tag(c[2]) for c in ov):
                    drops["noise_tag"] = drops.get("noise_tag", 0) + 1
                    continue
                ctx = [w for c in cap_words if c[1] > s - 2.0 and c[0] < e + 2.0 for w in textnorm.words(c[2])]
                wer = textnorm.wer_substring(ctx, words)
                if wer > TH["wer_max"]:
                    drops["wer"] = drops.get("wer", 0) + 1
                    continue
            if textnorm.has_noise_tag(text):
                drops["noise_tag"] = drops.get("noise_tag", 0) + 1
                continue
            out_clips.append((a, b, r, text, wer))
    finally:
        asr.close()
    rep["stats"]["s8_drops"] = drops
    rep["stats"]["s8_in"] = len(keep)
    rep["stats"]["s8_out"] = len(out_clips)
    for key, v in drops.items():
        pass
    # --- кроп и запись
    import cv2
    for a, b, r, text, wer in out_clips:
        L = b - a
        s = a / V.FPS
        frames = V.decode_frames(path, s, L / V.FPS + 0.2, out_h=360)
        if len(frames) < L - 3:
            drops["decode_short"] = drops.get("decode_short", 0) + 1
            continue
        if len(frames) < L:
            frames = np.concatenate([frames, np.repeat(frames[-1:], L - len(frames), 0)])
        frames = frames[:L][..., ::-1].copy()  # RGB->BGR для cv2/ffmpeg bgr24
        sxy = V.s3fd_like_track(rows, slice(a, b))
        arr = V.crop_clip(frames, sxy)
        cid = f"{vid}__00000_{a:06d}"
        V.write_mp4(arr, PUB / f"{cid}.mp4")
        (PUB / f"{cid}.txt").write_text(label_text(text) + "\n", encoding="utf-8")
        meta = {"video_id": vid, "start": round(a / V.FPS, 3), "end": round(b / V.FPS, 3), "source": "newdata-ru",
                "clip_id": f"{vid}/00000", "frames": L, "src_height": 360,
                "face_px_src": round(float(np.mean(sxy[:, 0]) * 2), 1),
                "label": "gigaam-v3-rnnt", "captions": bool(caps),
                "scores": {"sync_r": round(r, 3), "sync_thr": round(thr, 3), "wer_captions": None if wer is None else round(wer, 3),
                           "face_h_p10": round(float(np.percentile(rows["fh"][a:b] * ky, 10)), 1),
                           "sharp": round(float(np.median(rows["sharp"][a:b])), 1),
                           "wps": round(len(textnorm.words(text)) / (L / V.FPS), 2)}}
        tmpj = PUB / f"{cid}.json.tmp"
        tmpj.write_text(json.dumps(meta, ensure_ascii=False))
        os.replace(tmpj, PUB / f"{cid}.json")
        rep["clips"].append({"id": cid, "sec": L / V.FPS, "sync_r": r, "wer": wer})
    rep["events"].append(("s8_clips", 1 if rep["clips"] else 0, "" if rep["clips"] else "no_clips"))
    rep["stats"]["s8_written"] = len(rep["clips"])
    rep["stats"]["sec"] = round(time.time() - t_start, 1)
    rep["sync_r"] = r_seg.tolist()
    rep["sync_null"] = r_null.tolist()
    return rep


def child_init():
    os.nice(10)
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)


# ----------------------------------------------------------------------------------------------- диск
def disk_state():
    used = 0
    if PUB.exists():
        for f in PUB.iterdir():
            try:
                used += f.stat().st_size
            except OSError:
                pass
    free = shutil.disk_usage(ROOT).free / 1e9
    return used / 1e9, free


def total_hours():
    r = DBH.q("SELECT COALESCE(SUM(clip_sec),0) FROM videos", one=True)[0]
    return r / 3600


# ----------------------------------------------------------------------------------------------- рабочий поток
class Runner:
    def __init__(self, args):
        self.args = args
        self.pool = cf.ProcessPoolExecutor(args.procs, initializer=child_init)
        self.lock = threading.Lock()
        self.entered_s2 = 0
        self.sync_all = {"r": [], "null": []}

    def next_candidate(self):
        with self.lock:
            if self.args.limit_videos and DBH.q("SELECT COUNT(*) FROM events WHERE sieve='s2_meta'", one=True)[0] >= self.args.limit_videos:
                return None  # тестовая партия: N роликов дошли до сита s2 (после s1 и превью)
            r = DBH.q("SELECT video_id FROM videos WHERE status='s1_ok' ORDER BY (source='channel') DESC, random() LIMIT 1", one=True)
            if not r:
                return "EMPTY"
            DBH.set(r[0], status="meta")
            self.entered_s2 += 1
            return r[0]

    def handle(self, vid):
        import ytdl
        light = process_probe(vid)
        if light is None:
            return
        # полная загрузка
        if self.args.probe_only:
            return
        up, free = disk_state()
        if up > DISK_CAP_GB or free < MIN_FREE_GB:
            log(f"СТОП по диску: public_new {up:.1f} ГБ, свободно {free:.1f} ГБ")
            _stop.set()
            return
        DBH.set(vid, status="inflight")
        wd = TMP / vid
        shutil.rmtree(wd, ignore_errors=True)
        wd.mkdir(parents=True, exist_ok=True)
        vf = {"format_id": light["vf"]}
        af = {"format_id": light["af"]} if light.get("af") else None
        path, kind, err = ytdl.download_full(vid, None, vf, af, wd)
        if path is None:
            net_result(kind)
            DBH.event(vid, "s7_video", 0, f"download_{kind}")
            DBH.set(vid, status="rej", stage="s7_video", reason=f"download_{kind}")
            shutil.rmtree(wd, ignore_errors=True)
            return
        net_result("ok")
        caps = None
        if light.get("manual_ru"):
            try:
                caps = ytdl.transcript_manual(vid)
            except Exception:
                caps = None
        try:
            rep = self.pool.submit(process_video, vid, str(path), light, caps, str(wd), zlib.crc32(vid.encode()) & 0xffff).result()
        except BaseException as e:  # noqa
            log(f"ОШИБКА обработки {vid}: {type(e).__name__}: {e}")
            DBH.set(vid, status="failed", stage="s8_clips", reason=f"exception:{type(e).__name__}")
            shutil.rmtree(wd, ignore_errors=True)
            return
        finally:
            shutil.rmtree(wd, ignore_errors=True)
        for s, passed, reason in rep["events"]:
            DBH.event(vid, s, passed, reason)
        if rep["events"] and rep["events"][-1][1] == 0:
            DBH.set(vid, status="rej", stage=rep["events"][-1][0], reason=rep["events"][-1][2],
                    probe=json.dumps({**light["probe"], "video": rep["stats"]}, ensure_ascii=False))
            with self.lock:
                self.sync_all["r"] += rep.get("sync_r", [])
                self.sync_all["null"] += rep.get("sync_null", [])
            return
        n = len(rep["clips"])
        sec = sum(c["sec"] for c in rep["clips"])
        DBH.set(vid, status="done", stage="s8_clips", clips=n, clip_sec=sec,
                probe=json.dumps({**light["probe"], "video": rep["stats"]}, ensure_ascii=False))
        with self.lock:
            self.sync_all["r"] += rep.get("sync_r", [])
            self.sync_all["null"] += rep.get("sync_null", [])
        log(f"{vid}: клипов {n}, {sec/60:.1f} мин | {json.dumps(rep['stats'], ensure_ascii=False)} | всего {total_hours():.2f} ч")
        if n > 0:
            try:
                channel_boost(vid)
            except BotCheckStop:
                raise
            except Exception as e:  # noqa
                log(f"channel_boost {vid}: {type(e).__name__}: {e}")

    def worker(self):
        while not _stop.is_set() and not STOP.exists():
            if total_hours() >= self.args.target_hours:
                return
            vid = self.next_candidate()
            if vid is None:
                return
            if vid == "EMPTY":
                try:
                    with self.lock:
                        n = discover(0)
                except BotCheckStop:
                    return
                except Exception as e:  # noqa
                    log(f"ошибка поиска: {type(e).__name__}: {e}")
                    time.sleep(20)
                if not query_list_left():
                    log("запросы закончились")
                    return
                continue
            try:
                self.handle(vid)
            except BotCheckStop:
                return
            except Exception as e:  # noqa
                import traceback
                log(f"ОШИБКА {vid}: {type(e).__name__}: {e}\n{traceback.format_exc()[-600:]}")
                DBH.set(vid, status="failed", reason=f"exception:{type(e).__name__}")

    def run(self):
        ths = [threading.Thread(target=self.worker, daemon=True) for _ in range(self.args.workers)]
        for t in ths:
            t.start()
        last_report = 0
        while any(t.is_alive() for t in ths):
            time.sleep(5)
            if time.time() - last_report > 300:
                last_report = time.time()
                print_report(short=True)
        for t in ths:
            t.join()
        self.pool.shutdown(wait=True)
        try:
            old = json.loads((HERE / "sync_dist.json").read_text()) if (HERE / "sync_dist.json").exists() else {"r": [], "null": []}
            old["r"] = (old["r"] + self.sync_all["r"])[-200000:]
            old["null"] = (old["null"] + self.sync_all["null"])[-200000:]
            (HERE / "sync_dist.json").write_text(json.dumps(old))
        except Exception as e:  # noqa
            log(f"sync_dist: {e}")
        print_report()


def query_list_left():
    done = {r[0] for r in DBH.q("SELECT q FROM queries")}
    return any(q not in done for q in query_list())


# ----------------------------------------------------------------------------------------------- отчёт
def print_report(short=False):
    lines = ["Проценты прохождения по ситам (события):"]
    for s in SIEVES:
        r = DBH.q("SELECT COUNT(*), SUM(passed) FROM events WHERE sieve=?", (s,), one=True)
        n, p = r[0], r[1] or 0
        if n:
            lines.append(f"  {s:10s} вошло {n:5d}  прошло {p:5d}  {100*p/n:5.1f}%")
    rej = DBH.q("SELECT sieve, reason, COUNT(*) FROM events WHERE passed=0 GROUP BY sieve, reason ORDER BY 1, 3 DESC")
    if not short:
        lines.append("Причины отказов:")
        for s, rsn, c in rej:
            lines.append(f"  {s:10s} {rsn:28s} {c}")
    st = DBH.q("SELECT status, COUNT(*) FROM videos GROUP BY status")
    lines.append("Статусы: " + ", ".join(f"{a}={b}" for a, b in st))
    up, free = disk_state()
    nclips = DBH.q("SELECT COALESCE(SUM(clips),0) FROM videos", one=True)[0]
    lines.append(f"Клипов {nclips}, часов {total_hours():.2f}, public_new {up:.2f} ГБ, свободно на диске {free:.0f} ГБ")
    try:
        import numpy as np
        sc = [json.loads(p.read_text())["scores"] for p in PUB.glob("*.json")]
        if sc:
            for key in ("sync_r", "wer_captions", "face_h_p10", "wps"):
                v = np.array([x[key] for x in sc if x.get(key) is not None], float)
                if len(v):
                    lines.append(f"  {key}: n={len(v)} p5={np.percentile(v,5):.2f} p25={np.percentile(v,25):.2f} "
                                 f"медиана={np.median(v):.2f} p75={np.percentile(v,75):.2f} p95={np.percentile(v,95):.2f}")
        sd = HERE / "sync_dist.json"
        if sd.exists():
            d = json.loads(sd.read_text())
            for key in ("r", "null"):
                v = np.array(d[key], float)
                if len(v):
                    lines.append(f"  сегменты с хорошим лицом, r_{key}: n={len(v)} p5={np.percentile(v,5):.2f} p25={np.percentile(v,25):.2f} "
                                 f"медиана={np.median(v):.2f} p75={np.percentile(v,75):.2f} p95={np.percentile(v,95):.2f}")
    except Exception as e:  # noqa
        lines.append(f"(распределения недоступны: {e})")
    log("\n".join(lines))


def main():
    global DBH
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--target-hours", type=float, default=100.0)
    r.add_argument("--limit-videos", type=int, default=0, help="тестовая партия: остановиться, когда N роликов дошли до сита s2_meta (прошли s1 и превью)")
    r.add_argument("--workers", type=int, default=4)
    r.add_argument("--procs", type=int, default=3)
    r.add_argument("--probe-only", action="store_true")
    sub.add_parser("report")
    args = ap.parse_args()
    PUB.mkdir(parents=True, exist_ok=True)
    TMP.mkdir(parents=True, exist_ok=True)
    DBH = DB()
    load_calib()
    if args.cmd == "report":
        print_report()
        return
    if (HERE / "STOPPED_BOT").exists():
        print("Есть STOPPED_BOT (3 подряд бот-проверки). Удалите файл после разбора и запустите снова.")
        sys.exit(3)
    STOP.unlink(missing_ok=True)
    signal.signal(signal.SIGTERM, lambda *a: (_stop.set(), log("SIGTERM: дорабатываем текущие ролики")))
    # сбросить зависшие статусы прошлого запуска
    DBH.q("UPDATE videos SET status='s1_ok' WHERE status IN ('meta','probing')", commit=True)
    DBH.q("UPDATE videos SET status='probe_ok' WHERE status='inflight'", commit=True)
    # probe_ok без обработки (прерванный прошлый запуск) пересчитываем заново
    DBH.q("UPDATE videos SET status='s1_ok' WHERE status='probe_ok'", commit=True)
    log(f"СТАРТ: цель {args.target_hours} ч, потоков {args.workers}, процессов {args.procs}, MultiVSR-исключений {len(multivsr_ids())}")
    Runner(args).run()
    log("КОНЕЦ")
    if (HERE / "STOPPED_BOT").exists():
        sys.exit(3)


if __name__ == "__main__":
    main()
