#!/usr/bin/env python3
"""Сборщик статуса конвейеров (только чтение, stdlib). Печатает один JSON-объект.
Никого не сигналит, не запускает и не останавливает. Единственная запись - собственный кэш в
~/Library/Caches/pipeline-status/ (суммы длительностей клипов, счётчики журнала ошибок, история размера data/)."""
import ctypes
import glob
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import time



def _lipread_dir():
    """Lip-reading checkout: LIPREAD_RU_DIR, else ~/velikiy-moguchiy/lipread, or an older layout
    (~/velikiy-moguchiy/lipread-ru, ~/voice-dictation/lipread-ru) while only that exists."""
    if os.environ.get("LIPREAD_RU_DIR"):
        return os.path.expanduser(os.environ["LIPREAD_RU_DIR"])
    for d in ("~/velikiy-moguchiy/lipread", "~/velikiy-moguchiy/lipread-ru", "~/voice-dictation/lipread-ru"):
        if os.path.isdir(os.path.expanduser(d)):
            return os.path.expanduser(d)
    return os.path.expanduser("~/velikiy-moguchiy/lipread")


def _app_data_dir():
    """Data folder of the dictation app: ~/.velikiy-moguchiy, or ~/.koe from before the rename while only that exists."""
    new, old = os.path.expanduser("~/.velikiy-moguchiy"), os.path.expanduser("~/.koe")
    return old if not os.path.exists(new) and os.path.isdir(old) else new


LIP = _lipread_dir()
HARV = LIP + "/harvester"
FETCH = LIP + "/fetch"
DATA = LIP + "/data"
PUB = DATA + "/public"
TMPD = DATA + "/tmp"
NEWDATA = LIP + "/newdata"
HISTORY_DB = os.path.join(_app_data_dir(), "history.db")  # только sqlite ?mode=ro; config.yaml не читается
CACHE_DIR = os.path.expanduser("~/Library/Caches/pipeline-status")
CACHE = CACHE_DIR + "/cache.json"
FPS = 25.0
WINDOW = 600
TS_RE = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})")
NOW = time.time()


def run(cmd, timeout=3):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                              env={**os.environ, "LC_ALL": "C", "LANG": "C"}).stdout
    except Exception:
        return ""


def read_lines(path, nbytes=4 << 20):
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - nbytes))
            return f.read().decode("utf-8", "replace").splitlines()
    except Exception:
        return []


def to_ts(s):
    try:
        return time.mktime(time.strptime(s, "%Y-%m-%d %H:%M:%S"))
    except Exception:
        return None


def line_ts(line):
    m = TS_RE.match(line)
    return to_ts(m.group(1)) if m else None


def hhmm(ts):
    return time.strftime("%H:%M", time.localtime(ts)) if ts else None


def short(s, n=110):
    s = " ".join(s.split())
    return s if len(s) <= n else s[: n - 1] + "…"


# ---------------------------------------------------------------- кэш
def load_cache():
    try:
        with open(CACHE) as f:
            d = json.load(f)
            return d if isinstance(d, dict) else {}
    except Exception:
        return {}


def save_cache(c, old):
    if c == old:
        return
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        tmp = CACHE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(c, f)
        os.replace(tmp, CACHE)
    except Exception:
        pass


# ---------------------------------------------------------------- процессы
def etime_s(e):
    try:
        days = 0
        if "-" in e:
            d, e = e.split("-")
            days = int(d)
        p = [int(x) for x in e.split(":")]
        while len(p) < 3:
            p.insert(0, 0)
        return days * 86400 + p[0] * 3600 + p[1] * 60 + p[2]
    except Exception:
        return None


def process_table():
    out = []
    for ln in run(["ps", "-axo", "pid=,ppid=,pgid=,stat=,etime=,pcpu=,rss=,command="]).splitlines():
        p = ln.split(None, 7)
        if len(p) == 8 and p[0].isdigit():
            try:
                out.append({"pid": int(p[0]), "ppid": int(p[1]), "pgid": int(p[2]), "stat": p[3],
                            "up": etime_s(p[4]), "cpu": float(p[5]), "rss": int(p[6]), "cmd": p[7]})
            except Exception:
                pass
    return out


WRAPPERS = ("mem_guard", "caffeinate", "pkill", "pgrep", "grep ", "status.py", "tail ", "ps -axo")


def find_main(procs, needle, exclude=()):
    mine = [p for p in procs if needle in p["cmd"] and not any(w in p["cmd"] for w in WRAPPERS + tuple(exclude))]
    return min(mine, key=lambda p: p["pid"]) if mine else None


def group_stats(procs, main):
    """Процессы группы main: число yt-dlp / ffmpeg / прочих потомков, суммарный CPU и RAM."""
    if not main:
        return None
    g = [p for p in procs if p["pgid"] == main["pgid"] and p["pid"] != main["pid"]
         and not any(w in p["cmd"] for w in ("mem_guard", "caffeinate"))]
    allp = g + [main]
    return {"ytdlp": sum(1 for p in g if "yt-dlp" in p["cmd"]),
            "ffmpeg": sum(1 for p in g if re.match(r"\(?ffmpeg", p["cmd"]) and not p["stat"].startswith("Z")),
            "children": len(g), "cpu": round(sum(p["cpu"] for p in allp), 1),
            "rss_mb": round(sum(p["rss"] for p in allp) / 1024)}


def state_of(main):
    if not main:
        return "stopped"
    return "paused" if main["stat"].startswith("T") else "running"


# ---------------------------------------------------------------- журналы
def memguard_info(path):
    """У строк mem_guard нет времени: берём время ближайшей предыдущей строки со штампом (приблизительно)."""
    last_ts, ev = None, []
    for ln in read_lines(path, 2 << 20):
        t = line_ts(ln)
        if t:
            last_ts = t
        elif ln.startswith("[mem_guard]") and ("paused" in ln or "resumed" in ln):
            ev.append((last_ts, ln.strip()))
    pauses = sum(1 for t, l in ev if "paused" in l and t and NOW - t <= 3600)
    last = ev[-1] if ev else None
    last_line = None
    for ln in reversed(read_lines(path, 262144)):
        if ln.startswith("[mem_guard]"):
            last_line = ln.strip()[:200]
            break
    return {"last_event": last[1] if last else last_line,
            "last_event_time": hhmm(last[0]) if last and last[0] else None,
            "pauses_1h": pauses, "paused_now": bool(last and "paused" in last[1] and "resumed" not in last[1])}


def last_ts_line(lines):
    for ln in reversed(lines):
        t = line_ts(ln)
        if t:
            return ln, t
    return None, None


def log_last(lines):
    ln, t = last_ts_line(lines)
    if not ln:
        return None
    return {"text": short(ln[20:]), "time": hhmm(t), "age_s": int(NOW - t)}


# ---------------------------------------------------------------- public/
def scan_public(cache):
    recent_json, recent_npy = [], 0
    jsons, npys, errs, mp4 = set(), set(), 0, set()
    size = 0
    try:
        with os.scandir(PUB) as it:
            for e in it:
                n = e.name
                if n.endswith(".tmp.json") or n.endswith(".tmp.npy") or n.endswith(".json.tmp"):
                    continue
                try:
                    st = e.stat()
                except OSError:
                    continue
                size += st.st_size
                if n.endswith(".json"):
                    jsons.add(n[:-5])
                    if NOW - st.st_mtime <= WINDOW:
                        recent_json.append(n[:-5])
                elif n.endswith(".npy"):
                    npys.add(n[:-4])
                    if NOW - st.st_mtime <= WINDOW:
                        recent_npy += 1
                elif n.endswith(".mp4"):
                    mp4.add(n[:-4])
                elif n.endswith(".npy.err"):
                    errs += 1
    except OSError:
        pass
    tmp_size = 0
    try:
        for r, _, fs in os.walk(TMPD):
            for f in fs:
                try:
                    tmp_size += os.lstat(os.path.join(r, f)).st_size
                except OSError:
                    pass
    except OSError:
        pass
    frames_by = cache.setdefault("frames", {})
    fresh = {}
    for s in jsons:
        v = frames_by.get(s)
        if v is None:
            try:
                with open(os.path.join(PUB, s + ".json")) as f:
                    d = json.load(f)
                v = d.get("frames")
                if v is None:
                    v = (d.get("end", 0) - d.get("start", 0)) * FPS
            except Exception:
                v = 0
        fresh[s] = v
    cache["frames"] = fresh
    hours = sum(fresh.values()) / FPS / 3600
    rec_h = sum(fresh.get(s, 0) for s in recent_json) / FPS / 3600
    return {"clips": len(jsons), "hours": hours, "clips_per_min": len(recent_json) / (WINDOW / 60.0),
            "hours_per_hour": rec_h * 3600 / WINDOW, "npy": len(npys & jsons) if jsons else len(npys),
            "npy_per_min": recent_npy / (WINDOW / 60.0), "npy_errs": errs,
            "no_features": len(jsons - npys), "uncropped_fraction": None,
            "data_bytes": size + tmp_size, "last_clip": max(recent_json) if recent_json else None}


# ---------------------------------------------------------------- ошибки fetch
def fail_type(reason, detail):
    r, d = reason or "", (detail or "").lower()
    if r == "bot-check":
        return "bot"
    if r.startswith("throttle"):
        return "throttle"
    if r == "video_unavailable":
        return "unavailable"
    if "ffmpeg" in d:
        return "ffmpeg"
    if r == "crop_failed" and "лиц" in d:
        return "noface"
    return "other"


def failures_info(cache):
    path = FETCH + "/failures.jsonl"
    c = cache.setdefault("fails", {"off": 0, "tot": {}})
    tot = c["tot"]
    try:
        size = os.path.getsize(path)
    except OSError:
        return None
    if size < c["off"]:
        c["off"], c["tot"] = 0, {}
        tot = c["tot"]
    recent, last = {}, None
    try:
        with open(path, "rb") as f:
            f.seek(c["off"])
            data = f.read()
        end = data.rfind(b"\n")
        chunk = data[: end + 1]
        c["off"] += len(chunk)
        for ln in chunk.decode("utf-8", "replace").splitlines():
            try:
                d = json.loads(ln)
            except Exception:
                continue
            t = fail_type(d.get("reason"), d.get("detail"))
            tot[t] = tot.get(t, 0) + 1
    except Exception:
        pass
    for ln in read_lines(path, 262144)[-3000:]:
        try:
            d = json.loads(ln)
        except Exception:
            continue
        t = fail_type(d.get("reason"), d.get("detail"))
        ts = to_ts(d.get("ts", ""))
        last = (d, ts)
        if ts and NOW - ts <= WINDOW:
            recent[t] = recent.get(t, 0) + 1
    out = {"recent": recent, "total": dict(tot), "last": None}
    if last:
        d, ts = last
        out["last"] = {"time": hhmm(ts), "text": short(f"{d.get('reason')}: {d.get('detail') or d.get('video_id', '')}", 100)}
    return out


# ---------------------------------------------------------------- MultiVSR
def parse_progress(lines):
    info = {"workers": None, "crop_procs": None, "change": None, "target_h": None, "dl_mb_s": None, "dl_age": None,
            "queued": None, "backoff_until": None, "bots": 0, "last_block": None}
    cur = None
    for ln in lines:
        t = line_ts(ln)
        if "СТАРТ" in ln:
            m = re.search(r"потоков загрузки (\d+)", ln)
            cur = int(m.group(1)) if m else cur
            m = re.search(r"процессов кропа (\d+)", ln)
            info["crop_procs"] = int(m.group(1)) if m else info["crop_procs"]
            m = re.search(r"цель ([\d.]+) ч", ln)
            info["target_h"] = float(m.group(1)) if m else info["target_h"]
            info["change"] = None
            continue
        if "bot" in ln.lower() and t and NOW - WINDOW <= t <= NOW + 60:
            info["bots"] += 1
        m = re.search(r"потоков(?: загрузки| сейчас)? (\d+)", ln)
        if m:
            n = int(m.group(1))
            if "СТАТ" in ln:
                mm = re.search(r"загрузка ([\d.]+) МБ/с", ln)
                if mm:
                    info["dl_mb_s"], info["dl_age"] = float(mm.group(1)), (NOW - t) if t else None
                mq = re.search(r"в очереди кропа (\d+)", ln)
                if mq:
                    info["queued"] = int(mq.group(1))
            if cur is not None and n != cur and "СТАТ" not in ln:
                why = ("бот-проверки" if "botcheck" in ln else "блокировки 403/429" if "throttle" in ln
                       else "ошибок запросов" if "вдвое" in ln else "роста" if "рост" in ln else "лога")
                info["change"] = f"{cur} → {n} после {why} в {hhmm(t)}" if why != "роста" else f"{cur} → {n} (рост) в {hhmm(t)}"
            cur = n if n else cur
        if re.search(r"(botcheck|throttle): пауза", ln) and t:
            info["last_block"] = t
    info["workers"] = cur
    return info


def multivsr(procs, pub, cache):
    main = find_main(procs, "fetch/run.py")
    st = state_of(main)
    lines = read_lines(FETCH + "/progress.log")
    pi = parse_progress(lines)
    target = None
    if main:
        m = re.search(r"--target-hours[ =]([\d.]+)", main["cmd"])
        target = float(m.group(1)) if m else None
    target = target or pi["target_h"]
    g = group_stats(procs, main)
    fails = failures_info(cache)
    stage = []
    if st == "paused":
        stage.append("пауза: ждёт память")
    elif st == "running" and g:
        if pi["last_block"] and NOW - pi["last_block"] < 600:
            stage.append(f"пауза после блокировки YouTube до {hhmm(pi['last_block'] + 600)}")
        else:
            stage.append(f"качает {g['ytdlp']} роликов")
        if g["ffmpeg"]:
            stage.append(f"режет лица: ffmpeg {g['ffmpeg']}")
    ll = log_last(lines)
    dl = pi["dl_mb_s"] if pi["dl_age"] is not None and pi["dl_age"] < 120 and st == "running" else None
    bots = pi["bots"]
    if st == "stopped":
        text, dot = "остановлен", "gray"
    elif st == "paused":
        text, dot = "пауза: память", "yellow"
    elif bots > 0:
        text, dot = "YouTube: бот-проверка", "red"
    else:
        text, dot = "работает", "green"
    done_h = pub["hours"]
    rate = pub["hours_per_hour"]
    eta = None
    if target and rate > 0 and done_h < target:
        eta = int((target - done_h) / rate * 60)
    out = {"state": st, "state_text": text, "dot": dot, "uptime_s": main["up"] if main else None, "stage": " · ".join(stage) or None,
           "clips": pub["clips"], "hours": round(done_h, 2), "target_hours": target,
           "percent": round(100 * done_h / target) if target else None, "eta_min": eta,
           "clips_per_min": round(pub["clips_per_min"], 1), "hours_per_hour": round(rate, 2),
           "download_mb_s": dl, "queue_crop": pi["queued"] if st != "stopped" else None, "queue_features": pub["no_features"],
           "workers": pi["workers"] if st != "stopped" else None, "crop_procs": pi["crop_procs"], "worker_change": pi["change"],
           "bot_10min": bots, "errors": fails, "group": g, "last_log": ll,
           "stuck": bool(st == "running" and ll and ll["age_s"] > 300)}
    out["mem_guard"] = memguard_info(FETCH + "/run.out")
    return out


# ---------------------------------------------------------------- Features
def features(procs, pub, sysfree):
    main = find_main(procs, "fetch/feature_worker.py")
    st = state_of(main)
    lines = read_lines(FETCH + "/features.out", 1 << 20)
    g = group_stats(procs, main)
    other = [p["cmd"].split("/")[-1].split()[0] for p in procs
             if re.search(r"/(train|evaluate|dataset|nbest|nbest_oracle|lora|baseline)\.py", p["cmd"])
             and not any(w in p["cmd"] for w in WRAPPERS)]
    queue = pub["no_features"]
    rate_line = None
    for ln in reversed(lines):
        m = re.search(r"признаков (\d+), ([\d.]+) клип/с", ln)
        if m:
            rate_line = float(m.group(2))
            break
    speed_min = pub["npy_per_min"]
    stage = None
    if st == "paused":
        stage = "пауза: ждёт память"
    elif st == "running":
        if other:
            stage = f"ждёт GPU: идёт {other[0]}"
        elif sysfree is not None and sysfree < 12 and queue:
            stage = f"ждёт память (свободно {sysfree}% < 12%)"
        elif queue and speed_min > 0:
            stage = "считает признаки VTP"
        elif queue:
            stage = "считает признаки VTP (медленно или ждёт)"
        else:
            stage = "очередь пуста, ждёт новые клипы"
    ooms = sum(1 for ln in lines if "MPS OOM" in ln and (line_ts(ln) or 0) >= NOW - WINDOW)
    ll = log_last(lines)
    text, dot = {"stopped": ("остановлен", "gray"), "paused": ("пауза: память", "yellow")}.get(st, ("работает", "green"))
    eta = int(queue / (speed_min) ) if speed_min > 0 and queue else None
    return {"state": st, "state_text": text, "dot": dot, "uptime_s": main["up"] if main else None, "stage": stage,
            "npy": pub["npy"], "clips": pub["clips"], "percent": round(100 * pub["npy"] / pub["clips"]) if pub["clips"] else None,
            "eta_min": eta, "queue_features": queue, "clips_per_min": round(speed_min, 1), "clips_per_s_session": rate_line,
            "errors": {"npy_err_files": pub["npy_errs"], "oom_10min": ooms}, "group": g, "last_log": ll,
            "stuck": bool(st == "running" and queue and not other and ll and ll["age_s"] > 300 and speed_min == 0),
            "mem_guard": memguard_info(FETCH + "/features.out")}


# ---------------------------------------------------------------- Новые видео
FUNNEL = [("candidates", r"кандидат\w*|candidates?"), ("genre", r"жанр\w*|genre"), ("face", r"лиц\w*|крупн\w*|face"),
          ("sync", r"синхрон\w*|sync"), ("asr", r"gigaam|разметк\w*|asr"), ("accepted", r"принят\w*|accepted")]
HELPERS = {"asr_worker.py", "textnorm.py", "vision.py", "ytdl.py", "analysis.py"}


def newdata(procs):
    """Сборщик новых видео в newdata/ ещё не имеет точки входа (есть только ytdl/vision/asr_worker/textnorm).
    Состояние - по процессам python из newdata/ (кроме work/), воронка - из первого найденного файла прогресса,
    если в нём есть ключевые слова воронки. Если формата нет, строки просто не показываются."""
    cmdpats = ("lipread/newdata/", "lipread-ru/newdata/")  # the folder was lipread-ru before the monorepo layout
    mine = [p for p in procs if any(c in p["cmd"] for c in cmdpats) and "/newdata/work/" not in p["cmd"] and "python" in p["cmd"].lower()
            and not any(w in p["cmd"] for w in WRAPPERS)]
    main = min(mine, key=lambda p: p["pid"]) if mine else None
    st = state_of(main)
    entry = [os.path.basename(p) for p in glob.glob(NEWDATA + "/*.py") if os.path.basename(p) not in HELPERS]
    logs = [p for pat in ("status.json", "progress.json", "*.log", "*.out", "work/*.log", "work/*.out") for p in glob.glob(NEWDATA + "/" + pat)]
    logs = [p for p in logs if os.path.isfile(p)]
    logs.sort(key=lambda p: -os.path.getmtime(p))
    funnel, hours, ll = {}, None, None
    if logs:
        p = logs[0]
        if p.endswith(".json"):
            try:
                d = json.load(open(p))
                d = d.get("funnel", d)
                for k, _ in FUNNEL:
                    if isinstance(d.get(k), (int, float)):
                        funnel[k] = int(d[k])
                hours = d.get("hours", hours)
            except Exception:
                pass
        else:
            lines = read_lines(p, 1 << 20)
            ll = log_last(lines)
            for ln in reversed(lines[-400:]):
                for k, pat in FUNNEL:
                    if k in funnel:
                        continue
                    m = re.search(rf"(?:{pat})\D{{0,25}}?(\d+)", ln, re.I)
                    if m:
                        funnel[k] = int(m.group(1))
                        if k == "accepted":
                            mh = re.search(r"([\d.,]+)\s*ч\b", ln)
                            if mh:
                                hours = float(mh.group(1).replace(",", "."))
    text, dot = {"stopped": ("остановлен", "gray"), "paused": ("пауза: память", "yellow")}.get(st, ("работает", "green"))
    stage = None
    g = group_stats(procs, main)
    if st == "running" and g:
        parts = []
        if g["ytdlp"]:
            parts.append(f"качает {g['ytdlp']}")
        if g["ffmpeg"]:
            parts.append(f"ffmpeg {g['ffmpeg']}")
        stage = " · ".join(parts) or "работает"
    return {"state": st, "state_text": text, "dot": dot, "uptime_s": main["up"] if main else None, "stage": stage,
            "funnel": funnel or None, "hours": hours, "group": g, "last_log": ll, "entry_found": bool(entry),
            "stuck": bool(st == "running" and ll and ll["age_s"] > 300)}


# ---------------------------------------------------------------- «Великий & Могучий»
def dictation_app(procs):
    # builds from before the rename run as Govorun.app
    p = (find_main(procs, "VelikiyMoguchiy.app/Contents/MacOS/VelikiyMoguchiy")
         or find_main(procs, "Govorun.app/Contents/MacOS/Govorun"))
    last = None
    try:
        c = sqlite3.connect("file:" + HISTORY_DB + "?mode=ro", uri=True, timeout=0.5)
        r = c.execute("select max(timestamp) from sessions").fetchone()
        c.close()
        if r and r[0]:
            last = int(r[0])
    except Exception:
        pass
    return {"state": "running" if p else "stopped", "state_text": "работает" if p else "остановлен",
            "dot": "green" if p else "gray", "uptime_s": p["up"] if p else None,
            "last_dictation_age_s": int(NOW - last) if last else None, "last_dictation_time": hhmm(last) if last else None,
            "group": {"cpu": p["cpu"], "rss_mb": round(p["rss"] / 1024)} if p else None}


def runpod_jobs(procs):
    return sum(1 for p in procs if re.search(r"runpod/rp\.py (run|chat)\b", p["cmd"]) and not any(w in p["cmd"] for w in WRAPPERS))


def natural(s):
    return [int(x) if x.isdigit() else x for x in re.split(r"(\d+)", s)]


def pod_info(name, st):
    """Один сервер: state/<name>.json + хвост harvest-<name>.log. На сами серверы не ходим (никакого ssh)."""
    lines = read_lines(f"{HARV}/harvest-{name}.log", 1 << 20)
    hb = bk = None
    for ln in reversed(lines):
        if hb is None and "pod: {" in ln:
            try:
                hb = json.loads(ln[ln.index("pod: {") + 5:])
            except Exception:
                pass
        if bk is None and "backup:" in ln:
            m = re.search(r"mirror (\d+) clips, merged (\d+) new", ln)
            t = line_ts(ln)
            if m and t:
                bk = {"mirror": int(m.group(1)), "merged": int(m.group(2)), "age_s": int(NOW - t), "time": hhmm(t)}
        if hb is not None and bk is not None:
            break
    created, rate = st.get("created"), st.get("rate") or 0
    deadline = st.get("deadline")
    hours = max(0.0, (NOW - created) / 3600) if created else None
    out = {"name": name, "gpu": (st.get("gpu") or "").replace("NVIDIA GeForce ", "").replace("NVIDIA ", ""),
           "rate": rate, "hours": round(hours, 2) if hours is not None else None,
           "cost": round(hours * rate, 2) if hours is not None else None,
           "left_min": int((deadline - NOW) / 60) if deadline else None, "backup": bk,
           "alive": False, "hb_age_s": None, "clips": None, "features": None, "clips_per_min": 0.0, "hours_per_hour": 0.0,
           "threads": None, "gpu_util": None, "gpu_mib": None, "disk_free_gb": None, "fetch": None, "features_worker": None}
    if hb:
        age = NOW - (hb.get("ts") or 0)
        out.update({"hb_age_s": int(age), "alive": 0 <= age <= 600 or -60 < age < 0,
                    "clips": hb.get("clips"), "features": hb.get("features"), "disk_free_gb": hb.get("disk_free_gb"),
                    "fetch": hb.get("fetch"), "features_worker": hb.get("features_worker")})
        m = re.match(r"\s*(\d+)\s*,\s*(\d+)", str(hb.get("gpu", "")))
        if m:
            out["gpu_util"], out["gpu_mib"] = int(m.group(1)), int(m.group(2))
        last = hb.get("last") or ""
        m = re.search(r"([\d.]+) клип/мин", last)
        out["clips_per_min"] = float(m.group(1)) if m else 0.0
        m = re.search(r"([\d.]+) ч/ч", last)
        out["hours_per_hour"] = float(m.group(1)) if m else 0.0
        m = re.search(r"потоков (\d+)", last)
        out["threads"] = int(m.group(1)) if m else None
    return out


def runpod(procs):
    """Секция RunPod: серверы из harvester/state/*.json, сводка по ним и число задач rp.py."""
    pods = []
    for path in sorted(glob.glob(HARV + "/state/*.json"), key=natural):
        try:
            with open(path) as f:
                st = json.load(f)
            if isinstance(st, dict):
                pods.append(pod_info(os.path.basename(path)[:-5], st))
        except Exception:
            pass
    jobs = runpod_jobs(procs)
    if not pods and not jobs:
        return {"state": "stopped", "state_text": "серверов нет", "dot": "gray", "jobs": 0, "pods": [], "total": None, "mirror": None}
    mirror = None
    if pods:
        try:
            mirror = sum(1 for e in os.scandir(DATA + "/public_pod") if e.name.endswith(".json"))
        except OSError:
            pass
    alive = sum(1 for p in pods if p["alive"])
    for p in pods:
        p["dot"] = ("red" if not p["alive"] else "yellow" if p["fetch"] != "running" or p["features_worker"] != "running"
                    or (p["left_min"] is not None and p["left_min"] < 30) else "green")
    total = {"rate": round(sum(p["rate"] for p in pods), 2), "cost": round(sum(p["cost"] or 0 for p in pods), 2),
             "clips_per_min": round(sum(p["clips_per_min"] for p in pods if p["alive"]), 1),
             "hours_per_hour": round(sum(p["hours_per_hour"] for p in pods if p["alive"]), 2)} if pods else None
    if not pods:
        text, dot = "работает", "green"
    elif alive == len(pods):
        text, dot = "работает", "yellow" if any(p["dot"] == "yellow" for p in pods) else "green"
    else:
        text, dot = f"нет данных у {len(pods) - alive} из {len(pods)}", "red" if alive == 0 else "yellow"
    return {"state": "running", "state_text": text, "dot": dot, "jobs": jobs, "pods": pods, "total": total, "mirror": mirror}


# ---------------------------------------------------------------- система
class HostCpu(ctypes.Structure):
    _fields_ = [("ticks", ctypes.c_uint32 * 4)]


def cpu_ticks():
    try:
        lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
        lib.mach_host_self.restype = ctypes.c_uint32
        info, cnt = HostCpu(), ctypes.c_uint32(4)
        if lib.host_statistics(lib.mach_host_self(), 3, ctypes.byref(info), ctypes.byref(cnt)) == 0:
            return list(info.ticks)
    except Exception:
        pass
    return None


def vm_sample():
    swo = comp = None
    for ln in run(["vm_stat"]).splitlines():
        if ln.startswith("Swapouts"):
            swo = int(re.sub(r"\D", "", ln.split(":")[1]))
        elif ln.startswith("Pages occupied by compressor"):
            comp = int(re.sub(r"\D", "", ln.split(":")[1]))
    return swo, comp


def en0_bytes():
    for ln in run(["netstat", "-ib", "-I", "en0"]).splitlines():
        p = ln.split()
        if p and p[0] == "en0" and "<Link" in ln:
            try:
                return int(p[-5]), int(p[-2])  # Ibytes, Obytes
            except Exception:
                return None
    return None


def sample():
    swo, comp = vm_sample()
    return {"t": time.time(), "cpu": cpu_ticks(), "swo": swo, "comp": comp, "net": en0_bytes()}


def gpu_busy():
    m = re.search(r'"Device Utilization %"\s*=\s*(\d+)', run(["ioreg", "-r", "-d", "1", "-w0", "-c", "IOAccelerator"], 2))
    return int(m.group(1)) if m else None


def system_block(s1, s2, cache):
    el = max(s2["t"] - s1["t"], 1e-3)
    mp = run(["memory_pressure"])
    m = re.search(r"free percentage:\s*(\d+)%", mp)
    free_pct = int(m.group(1)) if m else None
    m = re.search(r"used = ([\d.]+)M", run(["sysctl", "-n", "vm.swapusage"]))
    swap_gb = round(float(m.group(1)) / 1024, 2) if m else None
    swo = (s2["swo"] - s1["swo"]) * 16384 / 1e6 / el if s1["swo"] is not None and s2["swo"] is not None else None
    cpu = None
    if s1["cpu"] and s2["cpu"]:
        d = [b - a for a, b in zip(s1["cpu"], s2["cpu"])]
        if sum(d) > 0:
            cpu = 100.0 * (sum(d) - d[2]) / sum(d)
    if cpu is None:
        try:
            cpu = min(100.0, sum(float(x) for x in run(["ps", "-A", "-o", "%cpu="]).split()) / (os.cpu_count() or 1))
        except Exception:
            pass
    down = up = None
    if s1["net"] and s2["net"]:
        down = max(0.0, (s2["net"][0] - s1["net"][0]) / 1e6 / el)
        up = max(0.0, (s2["net"][1] - s1["net"][1]) / 1e6 / el)
    comp_gb = round(s2["comp"] * 16384 / 1e9, 2) if s2["comp"] is not None else None
    return {"mem_free_pct": free_pct, "compressed_gb": comp_gb, "swap_used_gb": swap_gb,
            "swapout_mb_s": round(swo, 1) if swo is not None else None, "cpu_pct": round(cpu) if cpu is not None else None,
            "gpu_pct": gpu_busy(), "net_down_mb_s": round(down, 1) if down is not None else None,
            "net_up_mb_s": round(up, 1) if up is not None else None,
            "disk_free_gb": round(shutil.disk_usage("/").free / 1e9, 1)}


def growth(cache, size):
    """Рост data/public + data/tmp в ГБ/час по истории замеров (раз в минуту, хранится 2 часа)."""
    h = [x for x in cache.get("growth", []) if NOW - x[0] < 7200]
    if not h or NOW - h[-1][0] >= 60:
        h.append([int(NOW), size])
    cache["growth"] = h
    base = next((x for x in h if NOW - x[0] <= 3600), None)
    if base and NOW - base[0] >= 300:
        return round((size - base[1]) / 1e9 / ((NOW - base[0]) / 3600), 2)
    return None


def main():
    s1 = sample()
    old = load_cache()
    cache = json.loads(json.dumps(old))
    procs = process_table()
    pub = scan_public(cache)
    mv = multivsr(procs, pub, cache)
    sysfree_hint = None
    nd = newdata(procs)
    gv = dictation_app(procs)
    rest = time.time() - s1["t"]
    if rest < 0.5:
        time.sleep(0.5 - rest)
    s2 = sample()
    sysb = system_block(s1, s2, cache)
    sysb["data_growth_gb_h"] = growth(cache, pub["data_bytes"])
    ft = features(procs, pub, sysb["mem_free_pct"])
    res = {"ts": int(NOW), "multivsr": mv, "features": ft, "newdata": nd, "app": gv}
    res["runpod"] = runpod(procs)
    res["system"] = sysb
    save_cache(cache, old)
    res["elapsed_s"] = round(time.time() - NOW, 2)
    sys.stdout.buffer.write((json.dumps(res, ensure_ascii=False) + "\n").encode("utf-8"))


if __name__ == "__main__":
    main()
