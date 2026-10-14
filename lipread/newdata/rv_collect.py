#!/usr/bin/env python3
"""Сборщик русского talking-head видео с RuTube и VK Video -> клипы 224x224 в data/public (формат MultiVSR). Работает на поде.

Использует сита и вспомогательный код YouTube-сборщика (collect.py, vision.py, analysis.py, textnorm.py), заменены:
источники (rv_sources.py) и проверка синхронности (SyncNet вместо корреляции энергии рта, gpu_server.py).

Сита (события в rv_state.db, проценты в progress.log каждые 5 мин):
  s1_flat   метаданные листинга: длительность 3-120 мин, не эфир/18+/платное, категория, кириллица в названии, ключевые слова
  s2_meta   yt-dlp -J: формат 360-480p, fps >= 23.5, лимит принятых/проб на канал
  s3_tech   проба 30 с из середины: fps, чёткость лица
  s4_face   MediaPipe: лицо > 70% кадров, высота >= 90 px (360p, в терминах S3FD), одно лицо, анфас
  s5_speech Silero VAD + GigaAM: речь >= 40%, >= 1.2 слова/с
  s6_sync   SyncNet на пробе: уверенность >= probe_conf_min, сдвиг в окне
  s7_video  полный ролик: доля сегментов с лицом, прошедших SyncNet, и отрыв от нулевой модели (звук из другого места)
  s8_clips  сегмент 2-10 с: непрерывный трек лица, SyncNet сегмента, метка GigaAM (слов/с, >= 3 слов), запись клипа

Запуск: venv/bin/python rv_collect.py run --procs 6 ; остановка: touch /root/newdata/STOP ; отчёт: rv_collect.py report
"""
from __future__ import annotations

import argparse
import json
import multiprocessing as mp
import os
import random
import re
import shutil
import sqlite3
import subprocess
import sys
import threading
import time
import traceback
from pathlib import Path

for _k in ("VECLIB_MAXIMUM_THREADS", "OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS"):
    os.environ.setdefault(_k, "1")

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "multivsr" / "preprocess"))

PUB = Path(os.environ.get("RV_PUB", "/root/lr/data/public"))
WORK = HERE / "work"
DB_PATH = HERE / "rv_state.db"
LOG = HERE / "progress.log"
STOP = HERE / "STOP"
OFFSET_FILE = HERE / "rv_thresholds.json"

# пороги SyncNet: перекрываются rv_thresholds.json (калибровка rv_calib.py)
RTH = {"probe_conf_min": 3.0, "seg_conf_min": 3.0, "off_center": 0, "off_tol": 3, "video_pass_frac": 0.30, "video_delta": 1.5,
       "channel_accept_cap": 6, "channel_probe_cap": 12, "clip_cap_per_video": 600, "dur_min": 180, "dur_max": 7200}

DOMAIN_PAR = {"rutube": 4, "vk": 2, "youtube": int(os.environ.get("RV_YT_PAR", "4"))}  # одновременных обращений к домену (info/проба/загрузка) на все воркеры


def load_thresholds():
    if OFFSET_FILE.exists():
        RTH.update(json.loads(OFFSET_FILE.read_text()))


def log(msg):
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}"
    with open(LOG, "a") as f:
        f.write(line + "\n")
    print(line, flush=True)


# ------------------------------------------------------------------------------------------------ сеть: домены
class Net:
    """Адаптивная (AIMD) конкурентность на домен, общая для всех воркеров пода.
    Старт: RV_YT_PAR (YouTube, 4) / 4 (RuTube) / 2 (VK). +1 раз в 5 мин без блокировок, до потолка (YouTube 16, RuTube 8, VK 4).
    Любой throttle/bot-check/"page needs to be reloaded"/"for the authentication": потоки /2 (минимум 1) и пауза 2 мин на новые запросы;
    3 блокировки за 10 мин: пауза 15 мин. Каждое изменение пишется в лог."""
    START = {"youtube": int(os.environ.get("RV_YT_PAR", "4")), "rutube": 4, "vk": 2}
    CAP = {"youtube": 16, "rutube": 8, "vk": 4}

    def __init__(self):
        self.lock = mp.Lock()
        self.cond = mp.Condition(self.lock)
        self.limit = {k: mp.Value("i", self.START[k], lock=False) for k in DOMAIN_PAR}
        self.active = {k: mp.Value("i", 0, lock=False) for k in DOMAIN_PAR}
        self.pause = {k: mp.Value("d", 0.0, lock=False) for k in DOMAIN_PAR}
        self.last_change = {k: mp.Value("d", time.time(), lock=False) for k in DOMAIN_PAR}
        self.blocks = {k: mp.Array("d", [0.0] * 8, lock=False) for k in DOMAIN_PAR}
        self.bidx = {k: mp.Value("i", 0, lock=False) for k in DOMAIN_PAR}
        self.nxt = {k: mp.Value("d", 0.0, lock=False) for k in DOMAIN_PAR}  # не чаще одного старта yt-dlp в GAP секунд на домен
        self.gap = {"youtube": float(os.environ.get("RV_YT_GAP", "3")), "rutube": 1.0, "vk": 3.0}

    def enter(self, site):
        with self.cond:
            while True:
                now = time.time()
                if now < self.pause[site].value:
                    self.cond.wait(min(self.pause[site].value - now, 5))
                elif self.active[site].value >= self.limit[site].value:
                    self.cond.wait(5)
                else:
                    break
            self.active[site].value += 1
            t = max(time.time(), self.nxt[site].value)
            self.nxt[site].value = t + self.gap[site]
        if t > time.time():
            time.sleep(t - time.time())

    def leave(self, site):
        with self.cond:
            self.active[site].value -= 1
            self.cond.notify_all()

    def result(self, site, kind):
        now = time.time()
        with self.cond:
            if kind == "throttle":
                if now < self.pause[site].value:
                    return  # параллельные отказы одного и того же инцидента
                b = self.blocks[site]
                recent = sum(1 for x in b if now - x < 600)
                b[self.bidx[site].value % 8] = now
                self.bidx[site].value += 1
                old = self.limit[site].value
                self.limit[site].value = max(1, old // 2)
                pause = 900 if recent + 1 >= 3 else 120
                self.pause[site].value = now + pause
                self.last_change[site].value = now
                log(f"потоков {site} {old} → {self.limit[site].value} после throttle, пауза {pause} с" + (" (3 блокировки за 10 мин)" if pause == 900 else ""))
            elif kind == "ok":
                if now - self.last_change[site].value >= 300 and now >= self.pause[site].value and self.limit[site].value < self.CAP[site]:
                    old = self.limit[site].value
                    self.limit[site].value = old + 1
                    self.last_change[site].value = now
                    log(f"потоков {site} {old} → {old + 1} (5 мин без блокировок)")
                    self.cond.notify_all()


# ------------------------------------------------------------------------------------------------ состояние
SHARD = tuple(int(x) for x in os.environ.get("RV_SHARD", "0/1").split("/"))  # (k, n): этот под берёт строки/запросы с индексом % n == k


def _retry(fn):
    """SQLite: при 'database is locked' откатить транзакцию (иначе соединение остаётся в устаревшем снимке WAL и все записи
    дальше падают с locked) и повторить с паузой."""
    def wrap(self, *a, **kw):
        for k in range(40):
            try:
                return fn(self, *a, **kw)
            except sqlite3.OperationalError as e:
                if "locked" not in str(e) and "busy" not in str(e):
                    raise
                try:
                    self.c.rollback()
                except Exception:
                    pass
                time.sleep(0.2 + 0.1 * k + random.random() * 0.3)
        return fn(self, *a, **kw)
    return wrap


def make_db_class():
    import collect

    class RDB(collect.DB):
        q = _retry(collect.DB.q)
        add_candidate = _retry(collect.DB.add_candidate)
        event = _retry(collect.DB.event)
        set = _retry(collect.DB.set)
        kv_set = _retry(collect.DB.kv_set)

        def __init__(self, path):
            super().__init__(path)
            # autocommit: no implicit transaction is left open between statements, so a writer never holds a stale
            # WAL snapshot that makes other processes' writes fail with "database is locked" despite busy_timeout
            self.c.isolation_level = None
            self.c.execute("PRAGMA journal_mode=WAL")
            self.c.execute("PRAGMA busy_timeout=60000")

        def claim(self, excl):
            for k in range(40):
                try:
                    with self.lock:
                        cur = self.c.execute("UPDATE videos SET status='claimed', updated=? WHERE video_id=(SELECT video_id FROM videos WHERE status='s1_ok' " + excl +
                                             "ORDER BY (source='manual') DESC, CASE WHEN source='manual' THEN rowid END, (source='channel') DESC, random() LIMIT 1) "
                                             "RETURNING video_id", (time.time(),))
                        r = cur.fetchone()
                        cur.close()
                        self.c.commit()
                        return r
                except sqlite3.OperationalError as e:
                    if "locked" not in str(e) and "busy" not in str(e):
                        raise
                    try:
                        self.c.rollback()
                    except Exception:
                        pass
                    time.sleep(0.2 + 0.1 * k + random.random() * 0.3)
            return None
    return RDB


def get_db():
    import collect
    db = make_db_class()(DB_PATH)
    db.c.execute("PRAGMA journal_mode=WAL")
    db.c.execute("PRAGMA busy_timeout=60000")
    return db


def s1_reject(e: dict):
    import collect
    dur = e.get("duration")
    if not dur:
        return "no_duration"
    if not (RTH["dur_min"] <= dur <= RTH["dur_max"]):
        return "duration"
    if e.get("category_id") in __import__("rv_sources").RT_BAD_CATEGORY_IDS or e.get("category") in __import__("rv_sources").RT_BAD_CATEGORY_NAMES:
        return "category_" + str(e.get("category"))
    title = e.get("title") or ""
    if title and collect.cyr_share(title) < collect.TH["title_cyr"]:
        return "lang_title"
    k = collect.kw_reject(f"{title} {e.get('description') or ''}")
    if k:
        return f"kw_{k}"
    return None


def add_entries(db, entries, kind="search"):
    """s1_flat. -> (новых, прошло)."""
    new = ok = 0
    for e in entries:
        if not db.add_candidate({"id": e["id"], "title": e["title"], "channel": e["channel_name"], "channel_id": e["channel"],
                                 "duration": e["duration"]}, e["site"]):
            continue
        new += 1
        db.q("UPDATE videos SET info=? WHERE video_id=?", (json.dumps({"url": e["url"], "raw_id": e["raw_id"], "cat": e["category"]}, ensure_ascii=False), e["id"]), commit=True)
        why = s1_reject(e)
        db.event(e["id"], "s1_flat", why is None, why or "")
        if why:
            db.set(e["id"], status="rej", stage="s1_flat", reason=why)
        else:
            db.set(e["id"], status="s1_ok")
            ok += 1
    return new, ok


# ------------------------------------------------------------------------------------------------ обнаружение
def discovery(db: "collect.DB", stop: threading.Event):
    import rv_sources as RS
    qs = [q for i, q in enumerate(RS.search_queries()) if i % SHARD[1] == SHARD[0]]
    if os.environ.get("RV_QREV"):
        qs = qs[::-1]  # под без ручной очереди идёт по запросам с конца
    cat_state = db.kv_get("cat_state", {})
    last_vk = db.kv_get("last_vk", 0)
    vk_seed_i = db.kv_get("vk_seed_i", 0)
    cats = [c for i, c in enumerate(RS.RT_CATEGORIES_OK) if i % SHARD[1] == SHARD[0]] or list(RS.RT_CATEGORIES_OK)
    turn = 0
    while not stop.is_set() and not STOP.exists():
        try:
            pending = db.q("SELECT COUNT(*) FROM videos WHERE status='s1_ok'", one=True)[0]
            if pending > 3000:
                time.sleep(30)
                continue
            # 0) канал-буст: каналы принятых роликов
            boosts = db.kv_get("boost_queue", [])
            if boosts:
                ch = boosts.pop(0)
                db.kv_set("boost_queue", boosts)
                if not ch.startswith("vk"):
                    tot_new = tot_ok = 0
                    for page in range(1, 11):
                        ents, more, kind = RS.rt_person(ch, page)
                        n, k = add_entries(db, ents, "channel")
                        tot_new += n
                        tot_ok += k
                        if not more or kind != "ok":
                            break
                    log(f"канал {ch}: новых {tot_new}, прошли s1 {tot_ok}")
                continue
            turn += 1
            # 1) VK: раз в 3 часа одна попытка листинга сообщества (анонимный листинг сейчас закрыт) + файл vk_urls.txt
            if time.time() - last_vk > 3 * 3600 and SHARD[0] == 0:
                last_vk = time.time()
                db.kv_set("last_vk", last_vk)
                slug = RS.VK_SEEDS[vk_seed_i % len(RS.VK_SEEDS)]
                vk_seed_i += 1
                db.kv_set("vk_seed_i", vk_seed_i)
                ents, kind = RS.vk_list(slug)
                n, k = add_entries(db, ents, "vk")
                db.q("INSERT OR REPLACE INTO queries VALUES(?,?,?,?)", (f"vk:{slug}:{int(last_vk)}", time.time(), len(ents), "vk_" + kind), commit=True)
                log(f"VK @{slug}: {kind}, найдено {len(ents)}, новых {n}, прошли s1 {k}")
                n, k = add_entries(db, RS.vk_file_entries(HERE / "vk_urls.txt"), "vk")
                if n:
                    log(f"VK vk_urls.txt: новых {n}, прошли s1 {k}")
            # 2) категории (глубоко) и поисковые запросы вперемешку 1:2
            if turn % 3 == 0:
                cid = cats[(turn // 3) % len(cats)]
                page = cat_state.get(str(cid), 1)
                if page <= 60:
                    ents, more, kind = RS.rt_category(cid, page)
                    n, k = add_entries(db, ents, "category")
                    cat_state[str(cid)] = page + 1 if more else 999
                    db.kv_set("cat_state", cat_state)
                    db.q("INSERT OR REPLACE INTO queries VALUES(?,?,?,?)", (f"cat:{cid}:{page}", time.time(), len(ents), "category"), commit=True)
                    log(f"RuTube категория {cid} стр.{page}: {len(ents)} результатов, новых {n}, прошли s1 {k}")
            else:
                done = {r[0] for r in db.q("SELECT q FROM queries WHERE kind='search'")}
                todo = [q for q in qs if q not in done]
                if not todo:
                    time.sleep(60)
                    continue
                q = todo[0]
                ents, kind = RS.rt_search(q)
                db.q("INSERT OR REPLACE INTO queries VALUES(?,?,?,?)", (q, time.time(), len(ents), "search"), commit=True)
                n, k = add_entries(db, ents, "search")
                log(f"RuTube поиск «{q}»: {len(ents)} результатов, новых {n}, прошли s1 {k}")
        except Exception as e:  # noqa
            log(f"ошибка обнаружения: {type(e).__name__}: {e}")
            time.sleep(20)


MANUAL_FILE = HERE / "manual_urls.txt"
INBOX = HERE / "inbox"  # файлы, скачанные на Mac и присланные на под: <id>.mp4 + <id>.info.json (появляются атомарно)


def manual_id(url):
    """URL -> (id, site) или None. youtube -> yt_<11>, rutube -> rt_<32 hex>, vk -> vk_<oid>_<id>."""
    m = re.search(r"(?:youtube\.com/watch\?(?:[^ ]*&)?v=|youtu\.be/|youtube\.com/(?:shorts|live)/)([\w-]{11})", url)
    if m:
        return "yt_" + m.group(1), "youtube"
    m = re.search(r"rutube\.ru/video/(?:private/)?([0-9a-f]{32})", url)
    if m:
        return "rt_" + m.group(1), "rutube"
    m = re.search(r"video(-?\d+_\d+)", url)
    if m and ("vk.com" in url or "vkvideo.ru" in url):
        return "vk_" + m.group(1).replace("-", "m"), "vk"
    return None


def manual_loop(db, stop):
    """Ручная очередь: manual_urls.txt перечитывается каждые 2 мин; новые URL идут раньше кандидатов, сита s1/s2/проба пропускаются."""
    while not stop.is_set() and not STOP.exists():
        try:
            if MANUAL_FILE.exists():
                for li, line in enumerate(MANUAL_FILE.read_text().splitlines()):
                    line = line.strip()
                    if not line or line.startswith("#"):
                        continue
                    if li % SHARD[1] != SHARD[0]:
                        continue  # строка другого пода
                    r = manual_id(line)
                    if not r:
                        log(f"ручная очередь: не распознан URL {line[:80]}")
                        continue
                    vid, site = r
                    if db.add_candidate({"id": vid, "title": "", "channel": "manual", "channel_id": "manual", "duration": 0}, "manual"):
                        db.q("UPDATE videos SET info=?, status='s1_ok' WHERE video_id=?", (json.dumps({"url": line, "manual": True, "site": site}), vid), commit=True)
                        log(f"ручная очередь: добавлен {vid} ({line})")
        except Exception as e:  # noqa
            log(f"ручная очередь: {type(e).__name__}: {e}")
        time.sleep(120)


# ------------------------------------------------------------------------------------------------ воркер
def pick_format(info):
    """Склеенный A+V поток (RuTube HLS): высота 360 предпочтительно, иначе до 480; иначе максимум 240-359."""
    fs = [f for f in info.get("formats", []) if f.get("vcodec") not in (None, "none") and f.get("acodec") not in (None, "none")
          and f.get("height") and f.get("url")]
    if not fs:  # раздельные дорожки (VK dash)
        fs = [f for f in info.get("formats", []) if f.get("vcodec") not in (None, "none") and f.get("height") and f.get("url")]
    ok = [f for f in fs if 360 <= f["height"] <= 480]
    ok.sort(key=lambda f: (-(f["height"] == 360), f["height"], f.get("tbr") or 0))
    if ok:
        return ok[0]
    low = [f for f in fs if 240 <= f["height"] < 360]
    low.sort(key=lambda f: -f["height"])
    return low[0] if low else None


class Worker:
    def __init__(self, wid, net, args):
        import collect
        import gpu_server as G
        self.wid = wid
        self.net = net
        self.args = args
        self.db = make_db_class()(DB_PATH)
        self.db.c.execute("PRAGMA busy_timeout=60000")
        self.db.c.execute("PRAGMA synchronous=NORMAL")
        self.cl = G.Client()
        self.G = G
        self.collect = collect

    # --- yt-dlp
    def ytdlp_info(self, url, site):
        import ytdl
        self.net.enter(site)
        try:
            p = subprocess.run(["yt-dlp", "-J", "--no-warnings", "--no-playlist", "--socket-timeout", "30", url], capture_output=True, text=True, timeout=180)
        except subprocess.TimeoutExpired:
            return None, "error", "timeout"
        finally:
            self.net.leave(site)
        if p.returncode != 0 or not p.stdout.strip() or p.stdout.strip() == "null":
            kind = ytdl.classify(p.stderr)
            self.net.result(site, kind)
            return None, kind, p.stderr[-200:]
        self.net.result(site, "ok")
        return json.loads(p.stdout.splitlines()[0]), "ok", ""

    def probe_dl(self, f, t0, out, site):
        import ytdl
        self.net.enter(site)
        try:
            hdr = ytdl._hdr(f)
            cmd = ["nice", "-n", "10", "ffmpeg", "-v", "error", "-y", "-nostdin", "-headers", hdr, "-ss", f"{t0:.2f}", "-i", f["url"],
                   "-t", "30", "-c", "copy", str(out)]
            p = subprocess.run(cmd, capture_output=True, text=True, timeout=240)
        except subprocess.TimeoutExpired:
            return False, "error"
        finally:
            self.net.leave(site)
        if p.returncode != 0 or not out.exists() or out.stat().st_size < 20000:
            out.unlink(missing_ok=True)
            kind = ytdl.classify(p.stderr)
            self.net.result(site, kind)
            return False, kind
        self.net.result(site, "ok")
        return True, "ok"

    def full_dl(self, url, fid, wd, site):
        import ytdl
        self.net.enter(site)
        try:
            p = subprocess.run(["nice", "-n", "10", "yt-dlp", "--no-warnings", "--no-playlist", "-N", "6", "--socket-timeout", "30", "--retries", "3",
                                "--fragment-retries", "3", "-f", fid, "--merge-output-format", "mkv", "-o", str(wd / "video.%(ext)s"), url],
                               capture_output=True, text=True, timeout=3600)
        except subprocess.TimeoutExpired:
            return None, "error"
        finally:
            self.net.leave(site)
        files = [f for f in wd.glob("video.*") if f.suffix not in (".part", ".ytdl")]
        if files:
            self.net.result(site, "ok")
            return files[0], "ok"
        kind = ytdl.classify(p.stderr)
        self.net.result(site, kind)
        return None, kind

    # --- проба
    def analyze_probe(self, path):
        import numpy as np
        import analysis as A
        import textnorm
        import vision as V
        import ytdl
        TH = self.collect.TH
        m = {}
        st = ytdl.ffprobe_stream(path)
        m.update(fps=round(st["fps"], 2), h=st["h"])
        if st["fps"] < TH["fps_min"] - 0.7:
            return m, "s3_tech", "fps"
        t = min(30.0, st["dur"])
        frames = V.decode_frames(path, None, t, out_h=360)
        if len(frames) < 100:
            return m, "s3_tech", "short"
        o = V.analyze_frames(frames)
        audio = V.decode_audio(path, None, t)
        n = len(frames)
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
        speech = A.vad_intervals(audio)
        sm = np.zeros(n, bool)
        for s, e in speech:
            sm[int(s * 25):int(e * 25)] = True
        m["speech_frac"] = round(float(sm.mean()), 3)
        if m["speech_frac"] < TH["speech_frac_min"]:
            return m, "s5_speech", "no_speech"
        k = int(min(20.0, n / 25) * 16000)
        text = self.cl.asr(audio[:k])
        nw = len(textnorm.words(text))
        m["wps"] = round(nw / max(float(sm[:int(k / 640)].sum()) / 25, 1.0), 2)
        if m["wps"] < TH["wps_min"]:
            return m, "s5_speech", "asr_sparse"
        sxy = V.s3fd_like_track(o)
        arr = V.crop_clip(frames[..., ::-1].copy(), sxy)
        a = audio[: int(n / 25 * 16000)]
        r = self.cl.sync(arr, self.G.mfcc_of(a))
        m["sync_conf"], m["sync_off"] = round(r["conf"], 2), r["offset"]
        if r["conf"] < RTH["probe_conf_min"] or abs(r["offset"] - RTH["off_center"]) > RTH["off_tol"] + 2:
            return m, "s6_sync", "low_sync"
        return m, None, None

    # --- ручная очередь (URL проверены пользователем): без сит s1/s2/пробы, только полная загрузка и проверки сегментов
    def yt_cookie_copy(self, wd):
        own = wd / ".cookies.txt"
        src = "/root/lr/fetch/cookies.txt"
        if not os.path.isfile(src):
            return []
        fd = os.open(own, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as f, open(src, "rb") as s_:
            shutil.copyfileobj(s_, f)
        return ["--cookies", str(own)]

    def handle_manual(self, vid, meta):
        import ytdl
        db = self.db
        url, site = meta["url"], meta["site"]
        wd = WORK / "tmp" / vid
        shutil.rmtree(wd, ignore_errors=True)
        wd.mkdir(parents=True, exist_ok=True)
        try:
            cmd = ["nice", "-n", "10", "yt-dlp", "--no-warnings", "--no-playlist", "-N", "6", "--retries", "3", "--fragment-retries", "3",
                   "--sleep-requests", "1", "--socket-timeout", "30", "--merge-output-format", "mkv", "-o", str(wd / "video.%(ext)s")]
            if site == "youtube":
                cmd += self.yt_cookie_copy(wd)
                # res = меньшая сторона кадра (вертикальные Shorts 360x640 тоже считаются 360p)
                cmd += ["-f", "bv*+ba/b", "-S", "res:360,vcodec:h264"]
            else:
                cmd += ["-f", "b[height<=480]/b"]
            self.net.enter(site)
            try:
                p = subprocess.run(cmd + [url], capture_output=True, text=True, timeout=3600)
            finally:
                self.net.leave(site)
            files = [f for f in wd.glob("video.*") if f.suffix not in (".part", ".ytdl")]
            if not files:
                err = p.stderr[-300:]
                kind = ytdl.classify(err)
                if "not a bot" in err or "for the authentication" in err:
                    kind = "throttle"
                self.net.result(site, kind)
                db.event(vid, "s7_video", 0, f"download_{kind}")
                if kind in ("throttle",):
                    db.set(vid, status="s1_ok")  # повторим после паузы
                else:
                    db.set(vid, status="rej", stage="s7_video", reason=f"download_{kind}", probe=err[-150:])
                log(f"{vid}: загрузка не удалась ({kind}): {err[-150:]!r}")
                return
            self.net.result(site, "ok")
            src = {"youtube": "youtube", "rutube": "rutube", "vk": "vk"}[site]
            rep = self.process_video(vid, files[0], url, src, wd, gate=False)
        finally:
            shutil.rmtree(wd, ignore_errors=True)
        for s_, passed, reason in rep["events"]:
            db.event(vid, s_, passed, reason)
        n, sec = rep["n_clips"], rep["sec"]
        db.set(vid, status="done", stage="s8_clips", clips=n, clip_sec=sec, probe=json.dumps({"video": rep["stats"]}, ensure_ascii=False))
        st = rep["stats"]
        reasons = {}
        for k, v in (st.get("seg_face_rej") or {}).items():
            reasons["face:" + k] = v
        for k, v in (st.get("s8_drops") or {}).items():
            reasons[k] = v
        top = sorted(reasons.items(), key=lambda kv: -kv[1])[:4]
        log(f"РУЧНОЙ {vid} ({url}): сегментов {st.get('n_seg')}, с лицом {st.get('seg_face_ok')}, SyncNet проверено {st.get('sync_checked')}, "
            f"принято клипов {n}, {sec/60:.1f} мин, отказы {dict(top)}, видео-уровень SyncNet: прошли {st.get('sync_pass_frac')}, "
            f"реальный {st.get('sync_real')} / нулевой {st.get('sync_null')}")

    def take_inbox(self):
        """Атомарно забрать один файл из inbox (rename в inbox/.work) -> Path | None."""
        wk = INBOX / ".work"
        try:
            for f in sorted(INBOX.glob("*.mp4")):
                wk.mkdir(exist_ok=True)
                try:
                    os.rename(f, wk / f.name)
                except FileNotFoundError:
                    continue  # забрал другой воркер
                try:
                    os.rename(INBOX / f"{f.stem}.info.json", wk / f"{f.stem}.info.json")
                except FileNotFoundError:
                    pass
                return wk / f.name
        except OSError:
            pass
        return None

    def handle_inbox(self, path):
        db = self.db
        raw = path.stem
        vid = "yt_" + raw if re.fullmatch(r"[\w-]{11}", raw) else raw
        info = {}
        ij = path.with_name(f"{raw}.info.json")
        try:
            info = json.loads(ij.read_text()) if ij.exists() else {}
        except Exception:
            info = {}
        url = info.get("webpage_url") or f"https://www.youtube.com/watch?v={raw}"
        db.add_candidate({"id": vid, "title": info.get("title") or "", "channel": "manual", "channel_id": "manual", "duration": info.get("duration") or 0}, "manual")
        if db.q("SELECT status FROM videos WHERE video_id=?", (vid,), one=True)[0] == "done":
            path.unlink(missing_ok=True)
            ij.unlink(missing_ok=True)
            return
        db.set(vid, status="inflight", info=json.dumps({"url": url, "manual": True, "site": "youtube", "inbox": True}))
        wd = WORK / "tmp" / vid
        shutil.rmtree(wd, ignore_errors=True)
        wd.mkdir(parents=True, exist_ok=True)
        try:
            rep = self.process_video(vid, path, url, "youtube", wd, gate=False)
        except Exception as e:  # noqa
            log(f"ОШИБКА inbox {vid}: {type(e).__name__}: {e} | {traceback.format_exc()[-400:]}")
            db.event(vid, "error", 0, type(e).__name__)
            db.set(vid, status="failed", reason=f"exception:{type(e).__name__}")
            (INBOX / ".failed").mkdir(exist_ok=True)
            os.rename(path, INBOX / ".failed" / path.name)
            return
        finally:
            shutil.rmtree(wd, ignore_errors=True)
        path.unlink(missing_ok=True)
        ij.unlink(missing_ok=True)
        for s_, passed, reason in rep["events"]:
            db.event(vid, s_, passed, reason)
        n, sec = rep["n_clips"], rep["sec"]
        db.set(vid, status="done", stage="s8_clips", clips=n, clip_sec=sec, probe=json.dumps({"video": rep["stats"], "inbox": True}, ensure_ascii=False))
        st = rep["stats"]
        reasons = {("face:" + k): v for k, v in (st.get("seg_face_rej") or {}).items()}
        reasons.update(st.get("s8_drops") or {})
        top = sorted(reasons.items(), key=lambda kv: -kv[1])[:4]
        log(f"РУЧНОЙ(inbox) {vid} ({url}): сегментов {st.get('n_seg')}, с лицом {st.get('seg_face_ok')}, SyncNet проверено {st.get('sync_checked')}, "
            f"принято клипов {n}, {sec/60:.1f} мин, отказы {dict(top)}, SyncNet видео: прошли {st.get('sync_pass_frac')}, dur {st.get('dur')} с, время {st.get('t')}")

    # --- ролик
    def handle(self, vid):
        db, collect = self.db, self.collect
        meta0 = json.loads(db.q("SELECT info FROM videos WHERE video_id=?", (vid,), one=True)[0] or "{}")
        if meta0.get("manual"):
            return self.handle_manual(vid, meta0)
        row = db.q("SELECT channel_id, info, source, dur FROM videos WHERE video_id=?", (vid,), one=True)
        chan, info0, site, dur0 = row
        meta = json.loads(info0)
        url = meta["url"]
        site = "vk" if vid.startswith("vk_") else "rutube"
        nacc = db.q("SELECT COUNT(*) FROM videos WHERE channel_id=? AND status IN ('probe_ok','inflight','done')", (chan,), one=True)[0]
        nprobe = db.q("SELECT COUNT(DISTINCT e.video_id) FROM events e JOIN videos v ON v.video_id=e.video_id WHERE v.channel_id=? AND e.sieve='s3_tech'", (chan,), one=True)[0]
        if nacc >= RTH["channel_accept_cap"] or nprobe >= RTH["channel_probe_cap"]:
            db.event(vid, "s2_meta", 0, "channel_cap")
            db.set(vid, status="rej", stage="s2_meta", reason="channel_cap")
            return
        info, kind, err = self.ytdlp_info(url, site)
        if info is None:
            why = "unavailable" if kind in ("permanent", "error") else "info_" + kind
            db.event(vid, "s2_meta", 0, why)
            db.set(vid, status="rej", stage="s2_meta", reason=why, probe=err[-120:])
            return
        why = None
        dur = float(info.get("duration") or dur0 or 0)
        if info.get("is_live") or info.get("was_live"):
            why = "live"
        elif not (RTH["dur_min"] <= dur <= RTH["dur_max"]):
            why = "duration"
        f = None if why else pick_format(info)
        if not why and f is None:
            why = "no_360p"
        elif not why and (f.get("fps") or 25) < 23.0:
            why = "fps_meta"
        if why:
            db.event(vid, "s2_meta", 0, why)
            db.set(vid, status="rej", stage="s2_meta", reason=why)
            return
        db.event(vid, "s2_meta", 1)
        wd = WORK / "tmp" / vid
        shutil.rmtree(wd, ignore_errors=True)
        wd.mkdir(parents=True, exist_ok=True)
        try:
            t0 = max(0.0, dur / 2 - 15)
            pf = wd / "probe.mkv"
            ok, kind = self.probe_dl(f, t0, pf, site)
            if not ok:
                db.event(vid, "s3_tech", 0, f"probe_dl_{kind}")
                db.set(vid, status="rej", stage="s3_tech", reason=f"probe_dl_{kind}")
                return
            m, sieve, reason = self.analyze_probe(pf)
            order = ["s3_tech", "s4_face", "s5_speech", "s6_sync"]
            for s in order:
                if sieve is not None and order.index(s) > order.index(sieve):
                    break
                db.event(vid, s, sieve != s, "" if sieve != s else reason)
            pf.unlink(missing_ok=True)
            if sieve:
                db.set(vid, status="rej", stage=sieve, reason=reason, probe=json.dumps(m, ensure_ascii=False))
                return
            db.set(vid, status="inflight", probe=json.dumps(m, ensure_ascii=False))
            path, kind = self.full_dl(url, f["format_id"], wd, site)
            if path is None:
                db.event(vid, "s7_video", 0, f"download_{kind}")
                db.set(vid, status="rej", stage="s7_video", reason=f"download_{kind}")
                return
            rep = self.process_video(vid, path, url, "vk" if site == "vk" else "rutube", wd)
        finally:
            shutil.rmtree(wd, ignore_errors=True)
        for s, passed, reason in rep["events"]:
            db.event(vid, s, passed, reason)
        n = rep["n_clips"]
        sec = rep["sec"]
        if rep["events"] and rep["events"][-1][1] == 0:
            db.set(vid, status="rej", stage=rep["events"][-1][0], reason=rep["events"][-1][2], clips=n, clip_sec=sec,
                   probe=json.dumps({**m, "video": rep["stats"]}, ensure_ascii=False))
            return
        db.set(vid, status="done", stage="s8_clips", clips=n, clip_sec=sec, probe=json.dumps({**m, "video": rep["stats"]}, ensure_ascii=False))
        log(f"{vid}: клипов {n}, {sec/60:.1f} мин | {json.dumps(rep['stats'], ensure_ascii=False)}")
        if n > 0 and chan and not chan.startswith("vk"):
            b = db.kv_get("boost_queue", [])
            seen = db.kv_get("boosted", [])
            if chan not in b and chan not in seen:
                db.kv_set("boost_queue", b + [chan])
                db.kv_set("boosted", seen + [chan])

    def process_video(self, vid, path, url, source, wd, gate=True):
        import numpy as np
        import analysis as A
        import textnorm
        import vision as V
        collect, TH = self.collect, self.collect.TH
        rng = np.random.default_rng(zlib_crc(vid))
        rep = {"events": [], "stats": {}, "n_clips": 0, "sec": 0.0}
        t_start = time.time()
        pw, ph = V._dims(path)
        H360 = 360 if pw >= ph else int(round(360 * ph / pw / 2) * 2)  # вертикальное видео: меньшая сторона 360 px
        rep["stats"]["portrait"] = pw < ph
        tm = Tm()
        tm('audio_decode')
        audio = V.decode_audio(path)
        dur = len(audio) / V.SR
        n_total = int(dur * V.FPS)
        env = V.audio_envelope(audio, n_total)
        tm('vad')
        speech = A.vad_intervals(audio)
        tm('precheck')
        segs = A.pack_segments([tuple(x) for x in speech], env, dur, None)
        rep["stats"].update(dur=round(dur, 1), speech_s=round(sum(e - s for s, e in speech), 1), n_seg=len(segs))
        if not segs:
            rep["events"].append(("s7_video", 0, "no_segments"))
            return rep
        # быстрая проверка: лицо в выборке кадров по всему ролику (12 окон по 2 с), иначе не тратим CPU на полный проход
        ffs = V.FaceFeat(2, static=False)
        hits = tot = 0
        mots = []
        for tpos in np.linspace(0.05, 0.95, 12) * dur:
            fr = V.decode_frames(path, float(tpos), 2.0, out_h=H360)
            ffs.reset()
            for k in range(0, len(fr), 5):
                r = ffs.step(fr[k])
                tot += 1
                hits += bool(r["face"]) and r["fh"] * V.load_calib()["box"]["ky"] >= 70
                if r["face"]:
                    mots.append(r["mot"])
        rep["stats"]["face_sample"] = round(hits / max(tot, 1), 2)
        if tot and hits / tot < 0.12:
            rep["events"].append(("s7_video", 0, "no_face_video"))
            return rep
        rep["stats"]["mouth_motion"] = round(float(np.median(mots)), 2) if mots else 0.0
        if mots and tot and hits / tot >= 0.12 and float(np.median(mots)) < 0.8:
            rep["events"].append(("s7_video", 0, "static_face"))  # неподвижная картинка с лицом (постер + аудио)
            return rep
        mask = np.zeros(n_total + 50, bool)
        for s, e in segs:
            mask[int(s * V.FPS):int(e * V.FPS) + 2] = True
        ff = V.FaceFeat(2)
        rows = {k: np.zeros(n_total + 50, np.float32) for k in V.KEYS}
        last = -10
        lastproc = -10
        prev = None
        stride = int(os.environ.get("RV_FACE_STRIDE", "2"))  # FaceMesh на каждом stride-м кадре, между ними признаки копируются
        i = 0
        tm('face_pass')
        for i, fr in enumerate(V.iter_frames(path, out_h=H360)):
            if i >= len(mask):
                break
            if not mask[i]:
                continue
            if i != last + 1:
                ff.reset()
                lastproc = -10
            last = i
            if lastproc < 0 or i - lastproc >= stride:
                r = ff.step(fr)
                lastproc = i
                prev = r
                for k in V.KEYS:
                    rows[k][i] = r[k]
            else:
                for k in V.KEYS:
                    rows[k][i] = 0.0 if k == "jump" else prev[k]
        n = min(n_total, i + 1)
        tm('seg_checks')
        ky = V.load_calib()["box"]["ky"]
        cand, seg_rej = [], {}
        for (s, e) in segs:
            a, b = int(round(s * V.FPS)), int(round(e * V.FPS))
            if b > n or b - a < 49:
                continue
            why = collect.seg_arrays_ok(rows, a, b, ky)
            if why:
                seg_rej[why] = seg_rej.get(why, 0) + 1
                continue
            cand.append((a, b))
        rep["stats"].update(seg_face_ok=len(cand), seg_face_rej=seg_rej)
        if len(cand) < (5 if gate else 1):
            rep["events"].append(("s7_video", 0, "few_face_segments"))
            return rep

        def crops(a, b):
            L = b - a
            tm('clip_decode')
            frames = V.decode_frames(path, a / V.FPS, L / V.FPS + 0.2, out_h=H360)
            if len(frames) < L - 3:
                return None
            if len(frames) < L:
                frames = np.concatenate([frames, np.repeat(frames[-1:], L - len(frames), 0)])
            frames = frames[:L][..., ::-1].copy()
            sxy = V.s3fd_like_track(rows, slice(a, b))
            tm('clip_crop')
            out = V.crop_clip(frames, sxy), sxy
            tm('other')
            return out

        # the checks above run on 360p frames; the written clip is cut from the source frames (R3)
        HSRC = min(ph, 2 * H360)

        def src_crop(a, b, sxy):
            L = b - a
            frames = V.decode_frames(path, a / V.FPS, L / V.FPS + 0.2, out_h=HSRC)
            if len(frames) < L - 3:
                return None
            if len(frames) < L:
                frames = np.concatenate([frames, np.repeat(frames[-1:], L - len(frames), 0)])
            return V.crop_clip(frames[:L][..., ::-1].copy(), sxy * (HSRC / H360))

        def sync_of(arr, a, b, shift_s=0.0):
            s0 = a / V.FPS + shift_s
            i0 = int(s0 * V.SR) if shift_s == 0.0 else int(s0 * V.SR) % max(len(audio) - (b - a) * 640, 1)
            seg_a = audio[i0:i0 + (b - a) * 640]
            if len(seg_a) < (b - a) * 640 - 640:
                return None
            tm('sync_mfcc')
            mf = self.G.mfcc_of(seg_a)
            tm('sync_gpu')
            r_ = self.cl.sync(arr, mf)
            tm('other')
            return r_

        def sync_ok(r):
            return r is not None and r["conf"] >= RTH["seg_conf_min"] and abs(r["offset"] - RTH["off_center"]) <= RTH["off_tol"]

        # --- s7: выборка сегментов, SyncNet с настоящим и подменённым звуком (для ручных URL пропускается: решают сегменты)
        cache = {}
        if gate:
            sample = [cand[j] for j in rng.permutation(len(cand))[:14]]
            reals, null = [], []
            for (a, b) in sample:
                c = crops(a, b)
                if c is None:
                    continue
                r = sync_of(c[0], a, b)
                cache[(a, b)] = r
                if r is not None:
                    reals.append(r)
                sh = float(rng.uniform(20, max(21, min(dur - 20, 600))))
                rn = sync_of(c[0], a, b, shift_s=sh)
                if rn is not None:
                    null.append(rn["conf"])
            if len(reals) < 5:
                rep["events"].append(("s7_video", 0, "few_face_segments"))
                return rep
            real = [r["conf"] for r in reals]
            pass_frac = float(np.mean([sync_ok(r) for r in reals]))
            delta = float(np.mean(real) - (np.mean(null) if null else 0.0))
            rep["stats"].update(sync_pass_frac=round(pass_frac, 2), sync_real=round(float(np.mean(real)), 2), sync_null=round(float(np.mean(null)), 2) if null else None)
            if pass_frac < RTH["video_pass_frac"] or delta < RTH["video_delta"]:
                rep["events"].append(("s7_video", 0, "low_sync"))
                return rep
        rep["events"].append(("s7_video", 1, ""))
        # --- s8: все сегменты
        drops = {}
        written = 0
        checked = 0
        for (a, b) in cand:
            if written >= RTH["clip_cap_per_video"] or STOP.exists():
                break
            c = crops(a, b)
            if c is None:
                drops["decode_short"] = drops.get("decode_short", 0) + 1
                continue
            arr, sxy = c
            r = cache.get((a, b)) if (a, b) in cache else sync_of(arr, a, b)
            checked += 1
            if not sync_ok(r):
                drops["sync"] = drops.get("sync", 0) + 1
                continue
            s, e = a / V.FPS, b / V.FPS
            tm('asr_gpu')
            text = self.cl.asr(audio[int(s * V.SR):int(e * V.SR)])
            tm('other')
            words = textnorm.words(text)
            if len(words) < TH["words_min"]:
                drops["asr_empty"] = drops.get("asr_empty", 0) + 1
                continue
            wps = len(words) / (e - s)
            if not (TH["wps_seg_min"] <= wps <= TH["wps_seg_max"]):
                drops["wps"] = drops.get("wps", 0) + 1
                continue
            if textnorm.has_noise_tag(text):
                drops["noise_tag"] = drops.get("noise_tag", 0) + 1
                continue
            L = b - a
            cid = f"{vid}__00000_{a:06d}"
            tm('encode_write')
            src_arr = src_crop(a, b, sxy) if HSRC > H360 else None
            V.write_mp4(arr if src_arr is None else src_arr, PUB / f"{cid}.mp4")
            (PUB / f"{cid}.txt").write_text(collect.label_text(text) + "\n", encoding="utf-8")
            meta = {"video_id": vid, "start": round(s, 3), "end": round(e, 3), "source": source, "url": url, "clip_id": f"{vid}/00000",
                    "split": "train_major", "frames": L, "src_height": round(min(pw, ph) * (HSRC if src_arr is not None else H360) / ph), "box_scale": 1.0,
                    "face_px_src": round(float(np.mean(sxy[:, 0]) * 2), 1), "label": "gigaam-v3-rnnt",
                    "scores": {"sync_conf": round(r["conf"], 2), "sync_offset": r["offset"], "wps": round(wps, 2),
                               "face_h_p10": round(float(np.percentile(rows["fh"][a:b] * ky, 10)), 1)}}
            tmpj = PUB / f"{cid}.json.tmp"
            tmpj.write_text(json.dumps(meta, ensure_ascii=False))
            os.replace(tmpj, PUB / f"{cid}.json")  # json последним: после него feature-воркер считает .npy
            tm('other')
            written += 1
            rep["n_clips"] += 1
            rep["sec"] += L / V.FPS
            if written % 10 == 0:
                self.db.set(vid, clips=rep["n_clips"], clip_sec=rep["sec"])
        rep["events"].append(("s8_clips", 1 if written else 0, "" if written else "no_clips"))
        rep["stats"].update(sync_pass_frac=round(1 - drops.get("sync", 0) / max(checked, 1), 2) if not gate else rep["stats"].get("sync_pass_frac"), sync_checked=checked, s8_drops=drops, s8_written=written, sec_proc=round(time.time() - t_start, 1))
        return rep


class Tm:
    """Накопитель времени по фазам ролика (секунды) для профилирования."""
    def __init__(self):
        self.t = {}
        self.cur = None

    def __call__(self, name):
        now = time.time()
        if self.cur:
            self.t[self.cur[0]] = self.t.get(self.cur[0], 0.0) + now - self.cur[1]
        self.cur = (name, now) if name else None


def zlib_crc(s):
    import zlib
    return zlib.crc32(s.encode()) & 0xffff


def worker_main(wid, net, args):
    os.nice(5)
    w = Worker(wid, net, args)
    db = w.db
    idle = 0
    while not STOP.exists():
        if wid >= args.rt_workers:
            ib = w.take_inbox()
            if ib is not None:
                try:
                    w.handle_inbox(ib)
                except Exception as e:  # noqa
                    log(f"ОШИБКА inbox: {type(e).__name__}: {e} | {traceback.format_exc()[-300:]}")
                    for nm in (ib.name, f"{ib.stem}.info.json"):  # вернуть файл в очередь (ошибка БД и т.п.)
                        try:
                            os.rename(INBOX / ".work" / nm, INBOX / nm)
                        except OSError:
                            pass
                    time.sleep(5)
                continue
        if os.environ.get("RV_INBOX_ONLY"):
            time.sleep(4)
            continue
        try:
            excl = "AND source!='manual' " if wid < args.rt_workers else ""  # первые rt_workers процессов только RuTube/VK
            r = db.claim(excl)
        except Exception as e:  # noqa
            log(f"claim: {type(e).__name__}: {e}")
            time.sleep(5)
            continue
        if not r or os.environ.get("RV_INBOX_ONLY"):
            time.sleep(4 if os.environ.get("RV_INBOX_ONLY") else 10)
            idle += 1
            continue
        vid = r[0]
        try:
            w.handle(vid)
        except Exception as e:  # noqa
            log(f"ОШИБКА {vid}: {type(e).__name__}: {e} | {traceback.format_exc()[-500:]}")
            db.event(vid, "error", 0, type(e).__name__)
            db.set(vid, status="failed", reason=f"exception:{type(e).__name__}")
            shutil.rmtree(WORK / "tmp" / vid, ignore_errors=True)


# ------------------------------------------------------------------------------------------------ отчёт
def report(db, t0=None, prev=None, final=False):
    sieves = ["s1_flat", "s2_meta", "s3_tech", "s4_face", "s5_speech", "s6_sync", "s7_video", "s8_clips"]
    parts = []
    for s in sieves:
        n, p = db.q("SELECT COUNT(*), COALESCE(SUM(passed),0) FROM events WHERE sieve=?", (s,), one=True)
        if n:
            parts.append(f"{s} {p}/{n} ({100*p/n:.0f}%)")
    total = db.q("SELECT COUNT(*) FROM videos", one=True)[0]
    pend = db.q("SELECT COUNT(*) FROM videos WHERE status='s1_ok'", one=True)[0]
    inflight = db.q("SELECT COUNT(*) FROM videos WHERE status IN ('claimed','inflight')", one=True)[0]
    done = db.q("SELECT COUNT(*) FROM videos WHERE status='done'", one=True)[0]
    clips, sec = db.q("SELECT COALESCE(SUM(clips),0), COALESCE(SUM(clip_sec),0) FROM videos", one=True)
    errs = db.q("SELECT COUNT(*) FROM events WHERE sieve='error'", one=True)[0]
    by_site = db.q("SELECT source, COUNT(*), COALESCE(SUM(clip_sec),0)/3600.0 FROM videos GROUP BY source")
    elapsed = (time.time() - t0) / 3600 if t0 else 0
    rate = ""
    if prev is not None:
        dt = max(time.time() - prev[0], 1)
        rate = f", клипов/мин {(clips - prev[1]) / dt * 60:.1f}"
    log(f"ОТЧЁТ: кандидатов {total} (ждут {pend}, в работе {inflight}), роликов принято {done}, сита: " + "; ".join(parts) +
        f" | клипов {int(clips)}, часов {sec/3600:.2f}{rate}, ошибок {errs}" + (f", часов/час работы {sec/3600/elapsed:.2f}" if elapsed > 0.02 else "") +
        " | по сайтам: " + ", ".join(f"{a}={c} роликов {h:.2f} ч" for a, c, h in by_site))
    return (time.time(), clips)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--procs", type=int, default=6)
    r.add_argument("--rt-workers", type=int, default=1, help="сколько процессов обрабатывает только RuTube/VK (остальные - сначала ручная очередь)")
    sub.add_parser("report")
    args = ap.parse_args()
    WORK.mkdir(exist_ok=True)
    (WORK / "tmp").mkdir(exist_ok=True)
    load_thresholds()
    db = get_db()
    if args.cmd == "report":
        report(db)
        return
    STOP.unlink(missing_ok=True)
    # GPU-сервис: поднять, если ещё не запущен
    import gpu_server as G
    gpu_procs = []
    for port in range(G.BASE_PORT, G.BASE_PORT + G.N_SERVERS):
        try:
            G.Client(port)._call("ping")
            continue
        except Exception:
            pass
        env = dict(os.environ, RV_GPU_PORT=str(port))
        gpu_procs.append(subprocess.Popen([sys.executable, str(HERE / "gpu_server.py")], env=env,
                                          stdout=open(HERE / "logs" / f"gpu_server_{port}.log", "a"), stderr=subprocess.STDOUT))
        for _ in range(120):
            time.sleep(2)
            try:
                G.Client(port)._call("ping")
                break
            except Exception:
                pass
    db.q("UPDATE videos SET status='s1_ok' WHERE status IN ('claimed','inflight')", commit=True)
    if SHARD[1] > 1 and MANUAL_FILE.exists():  # ручные URL чужих долей, попавшие в очередь до включения шардов
        own = set()
        for li, line in enumerate(MANUAL_FILE.read_text().splitlines()):
            r = manual_id(line.strip())
            if r and li % SHARD[1] == SHARD[0]:
                own.add(r[0])
        for (vid,) in db.q("SELECT video_id FROM videos WHERE source='manual' AND status='s1_ok'"):
            if vid not in own:
                db.set(vid, status="rej", stage="manual", reason="other_pod")
    log(f"СТАРТ: доля {SHARD[0]}/{SHARD[1]}, процессов {args.procs}, пороги {json.dumps(RTH)}")
    wk = INBOX / ".work"
    if wk.exists():  # файлы, застрявшие в обработке при перезапуске, вернуть в очередь
        for f in wk.iterdir():
            try:
                os.rename(f, INBOX / f.name)
            except OSError:
                pass
    net = Net()
    stop = threading.Event()
    inbox_only = bool(os.environ.get("RV_INBOX_ONLY"))
    if not inbox_only:  # inbox-only: под ничего не скачивает, работает только с файлами из inbox
        th = threading.Thread(target=discovery, args=(db, stop), daemon=True)
        th.start()
    if not os.environ.get("RV_NO_MANUAL") and not inbox_only:
        threading.Thread(target=manual_loop, args=(db, stop), daemon=True).start()
    ctx = mp.get_context("fork")
    procs = [ctx.Process(target=worker_main, args=(i, net, args)) for i in range(args.procs)]
    for p in procs:
        p.start()
    t0 = time.time()
    prev = None
    last = 0
    while any(p.is_alive() for p in procs):
        time.sleep(5)
        if time.time() - last >= 300:
            last = time.time()
            prev = report(db, t0, prev)
    stop.set()
    report(db, t0, prev, final=True)
    log("КОНЕЦ")
    for gp in gpu_procs:
        gp.terminate()


if __name__ == "__main__":
    main()
