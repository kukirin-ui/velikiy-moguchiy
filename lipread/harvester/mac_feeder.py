#!/usr/bin/env python3
"""Downloads videos from the manual queue on the Mac (a residential address YouTube trusts more) and hands them
to the pods' collectors, which do all the processing.

  mac_feeder.py [--cookies fetch/cookies.txt,fetch/cookies_acc2.txt,...] [--parallel 3] [--forward]

Walks newdata/manual_order_mac.txt, downloads 360p H.264 + Russian audio as mp4 with its info json over every
account at once (each with its own AIMD gate), ships both to the pod with the shortest inbox and deletes the local
copy. Channels listed in harvester/channel_skip.txt (written by channel_quality.py) are not downloaded; the list is
re-read with the queue. For the first LABEL_SAMPLE videos of each channel the YouTube auto-subs are saved to
harvester/autosubs/, the reference channel_quality.py checks the collector's GigaAM texts against.
A queue line may end with "@<start>-<end>" (seconds): then only that section is fetched (yt-dlp --download-sections),
named yt_<video>__s<start ms>.mp4 and shipped to the pods' inbox_seg/, where extdata/pod_segments.py cuts the
dataset segments it holds (data/ext/youtube_queue.txt has such lines). The channel of a section line is the speaker id.
--scout: a whole-video line is first fetched as a 144p video-only stream and harvester/scout.py finds its close-up
single-face stretches (OpenCV Haar, no ML model). No stretch: the video is marked done. Stretches covering most of the
video, or many of them: the whole video at 720p as usual. Otherwise each stretch becomes a section job at 720p that
goes to the collector's usual inbox as its own video yt_<video>__s<start ms>, with that id in video_channels.tsv.
--scout-dry ID[,ID]: scout only, print the plan and the bytes it saves, ship nothing.
Stop: touch harvester/MAC_FEEDER_STOP.
"""
import argparse
import json
import os
import re
import shutil
import shlex
import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
QUEUE = ROOT / "newdata" / "manual_order_mac.txt"
DONE = HERE / "mac_feeder_done.txt"
STOP = HERE / "MAC_FEEDER_STOP"
WORK = ROOT / "data" / "mac_dl"
LOG = HERE / "mac_feeder.log"
CHANNELS = HERE / "video_channels.tsv"
SEG_INBOX = "/root/newdata/inbox_seg"
SCOUT = HERE / "scout.py"
SCOUT_CACHE = HERE / "scout_cache.json"  # video -> scout result, so a restart does not fetch the 144p copy again
SCOUT_FMT = "bv*[height<=144]/wv*"
SCOUT_MERGE_GAP = 10.0
SCOUT_WHOLE_FRAC = 0.85
SCOUT_MAX_SECTIONS = 8
FMT = "bv*[height<=720][vcodec^=avc1]+ba[language^=ru]/bv*[height<=720][vcodec^=avc1]+ba/bv*[height<=720]+ba/b[height<=720]"
MAX_LOCAL_GB = 20
BLOCK_MARKS = ("not a bot", "needs to be reloaded", "429", "rate-limit", "try again later")
# "Please sign in ... for the authentication" also comes from one login-gated video: one account is blocked only after
# AUTH_STRIKES different videos fail that way on it, and a video that failed so on two accounts is the video's gate
AUTH_MARKS = ("for the authentication", "Please sign in")
AUTH_STRIKES = 2
# a throttled session answers "Video unavailable" for live videos before it admits the rate limit
UNAVAILABLE_STREAK = 3
BLOCK_PAUSE = 3600
MAX_TRIES = 2
BACKLOG_TTL = 20
# the video itself is gated: retrying it on other accounts only gets them paused for nothing
VIDEO_GATES = ("confirm your age", "Private video", "members-only", "This live event")
# inbox + in-work videos a pod may hold: more than it can cut before its deadline would be marked done and lost
MAX_BACKLOG = 60
SEG_WAIT = 600
LEDGER = HERE / "channel_seconds.json"  # seconds of video shipped per channel (R1)
FEEDER_CHANNELS = HERE / "feeder_channels.tsv"  # video id -> the queue's channel label it was shipped under
AUTOSUBS = HERE / "autosubs"
LABEL_SAMPLE = 2
QUEUE_REFRESH = 300  # seconds between re-reads of the queue files and channel_skip.txt (--follow)
SHIP_CUTOFF = 25 * 60

sys.path.insert(0, str(HERE))
import channel_quality  # noqa: E402
import harvest  # noqa: E402
import preflight  # noqa: E402  (ssh options and pod state)

lock = threading.Lock()


def log(msg):
    line = time.strftime("%F %T ") + msg
    with lock, open(LOG, "a") as f:
        f.write(line + "\n")


def pods():
    out = []
    # p* pods collect; other pods (t* = training) have no collector and must not receive videos
    for f in sorted((HERE / "state").glob("p*.json")):
        st = json.loads(f.read_text())
        # a video shipped later than this is marked done here but never cut before the pod self-destructs
        if "host" in st and time.time() < st["deadline"] - SHIP_CUTOFF:
            out.append(st)
    return out


def local_gb():
    # other threads delete their folders mid-walk; rglob raises on that and would kill the worker thread
    total = 0
    for d, _, names in os.walk(WORK):
        for n in names:
            try:
                total += os.stat(os.path.join(d, n)).st_size
            except OSError:
                pass
    return total / 1e9


SECTION = re.compile(r"@\s*(\d+(?:\.\d+)?)\s*-\s*(\d+(?:\.\d+)?)\s*$")


def parse_line(line):
    """'<url>  # <channel>  [@<start>-<end>]' -> (job, video, channel, (start, end) | None), or None.
    A job is the video id, or video@start-end for a section."""
    url, _, rest = line.partition("#")
    url = url.strip()
    if "watch?v=" not in url:
        return None
    vid = url.rsplit("=", 1)[-1]
    m = SECTION.search(rest)  # not a bare "@": channel labels are YouTube handles like "@handle"
    ch = (rest[:m.start()] if m else rest).strip() or "?"
    if not m:
        return vid, vid, ch, None
    a, b = float(m.group(1)), float(m.group(2))
    return f"{vid}@{a:.2f}-{b:.2f}", vid, ch, (a, b)


def split_job(job):
    vid, _, sec = job.partition("@")
    return vid, (tuple(float(x) for x in sec.split("-")) if sec else None)


def job_stem(job):
    """File name of a job. A section starts with yt_ so the collector keeps it as a video id of its own and
    train_e2e.py finds its clips (yt_*.json) and its channel (the id without yt_ in video_channels.tsv)."""
    vid, sec = split_job(job)
    return vid if sec is None else f"yt_{vid}__s{int(round(sec[0] * 1000)):08d}"


def download(job, cookies):
    vid, sec = split_job(job)
    out = WORK / job_stem(job)
    out.mkdir(parents=True, exist_ok=True)
    own = out / ".cookies.txt"  # yt-dlp rewrites its cookie file; never share one between parallel runs
    fd = os.open(own, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as f, open(cookies, "rb") as src:
        shutil.copyfileobj(src, f)
    # a section cut by stream copy still starts on its exact time: ffmpeg trims the pre-roll with an edit list
    cut = [] if sec is None else ["--download-sections", f"*{sec[0]:.2f}-{sec[1]:.2f}"]
    r = subprocess.run(["yt-dlp", "--no-warnings", "--no-playlist", "--cookies", str(own), "-f", FMT,
                        "--merge-output-format", "mp4", "--write-info-json", "--retries", "3",
                        "--sleep-requests", "1", *cut, "-o", str(out / f"{job_stem(job)}.%(ext)s"),
                        f"https://www.youtube.com/watch?v={vid}"], capture_output=True, text=True, timeout=3600)
    own.unlink(missing_ok=True)
    files = [p for p in out.iterdir() if p.suffix in (".mp4", ".json")]
    if r.returncode or not any(p.suffix == ".mp4" for p in files):
        return None, (r.stderr or "").strip().splitlines()[-1:] or ["no file"]
    return files, None


def own_cookies(cookies, path):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as f, open(cookies, "rb") as src:
        shutil.copyfileobj(src, f)


def est_720_bytes(info):
    """Size of what download() would fetch, from the format list: best <= 720p H.264 video plus the best audio."""
    dur = float(info.get("duration") or 0)

    def size(f):
        return f.get("filesize") or f.get("filesize_approx") or (f.get("tbr") or 0) * dur * 125

    fm = info.get("formats") or []
    vids = [f for f in fm if f.get("vcodec") not in (None, "none") and (f.get("height") or 0) <= 720]
    avc = [f for f in vids if str(f.get("vcodec")).startswith("avc1")] or vids
    auds = [f for f in fm if f.get("vcodec") == "none" and f.get("acodec") not in (None, "none")]
    if not avc:
        return None
    v = max(avc, key=lambda f: (f.get("height") or 0, f.get("tbr") or 0))
    a = max(auds, key=lambda f: f.get("abr") or f.get("tbr") or 0) if auds else None
    return int(size(v) + (size(a) if a else 0))


def scout(vid, cookies):
    """144p video-only copy -> scout.py. Returns ({stretches, duration, bytes144, bytes720}, None) or (None, [error])."""
    out = WORK / f"{vid}.scout"
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)
    own = out / ".cookies.txt"
    own_cookies(cookies, own)
    try:
        r = subprocess.run(["yt-dlp", "--no-warnings", "--no-playlist", "--cookies", str(own), "-f", SCOUT_FMT,
                            "--write-info-json", "--retries", "3", "--sleep-requests", "1",
                            "-o", str(out / f"{vid}.%(ext)s"), f"https://www.youtube.com/watch?v={vid}"],
                           capture_output=True, text=True, timeout=1800)
        own.unlink(missing_ok=True)
        media = [p for p in out.iterdir() if p.suffix in (".mp4", ".webm", ".mkv")]
        if r.returncode or not media:
            return None, (r.stderr or "").strip().splitlines()[-1:] or ["no file"]
        info = json.loads((out / f"{vid}.info.json").read_text())
        py = ROOT / ".venv" / "bin" / "python"
        sc = subprocess.run(["nice", "-n", "10", str(py if py.exists() else sys.executable), str(SCOUT), str(media[0])],
                            capture_output=True, text=True, timeout=1800)
        if sc.returncode:
            return None, [f"scout.py failed: {(sc.stderr or '').strip()[-150:]}"]
        return dict(stretches=json.loads(sc.stdout), duration=float(info.get("duration") or 0),
                    bytes144=media[0].stat().st_size, bytes720=est_720_bytes(info)), None
    except subprocess.TimeoutExpired:
        return None, ["scout timeout"]
    finally:
        shutil.rmtree(out, ignore_errors=True)


def plan_sections(stretches, duration):
    """("skip" | "whole" | "sections", [(start, end)]) for the scouted close-up stretches of a video."""
    if not stretches:
        return "skip", []
    merged = []
    for a, b in sorted(stretches):
        if merged and a - merged[-1][1] <= SCOUT_MERGE_GAP:
            merged[-1][1] = max(merged[-1][1], b)
        else:
            merged.append([a, b])
    covered = sum(b - a for a, b in merged)
    if len(merged) > SCOUT_MAX_SECTIONS or (duration and covered >= SCOUT_WHOLE_FRAC * duration):
        return "whole", []
    return "sections", [(a, b) for a, b in merged]


def scout_saving(plan, kind, secs):
    """720p bytes not downloaded thanks to scouting, minus the 144p copy; None if the format list had no sizes."""
    dur, b720 = plan["duration"], plan["bytes720"]
    if not dur or not b720:
        return None
    kept = 0.0 if kind == "skip" else dur if kind == "whole" else sum(b - a for a, b in secs)
    return int(b720 * (1 - min(1.0, kept / dur))) - plan["bytes144"]


def ship(files, st, inbox="/root/newdata/inbox"):
    host, port = st["host"], st["port"]
    e = "ssh " + " ".join(rp_quote(x) for x in harvest.rp.ssh_opts(port))
    try:
        harvest.remote(st, f"mkdir -p {inbox}/.part")
    except Exception as e:  # noqa: BLE001
        log(f"ship: {host} unreachable: {type(e).__name__}: {str(e)[:120]}")
        return False
    # land in .part first and move in one step, so the collector never sees half a file
    r = subprocess.run(["rsync", "-a", "--timeout=300", "-e", e] + [str(p) for p in files] +
                       [f"root@{host}:{inbox}/.part/"], capture_output=True, text=True)
    if r.returncode:
        return False
    names = " ".join(shlex.quote(p.name) for p in files)  # ids may start with "-"
    try:
        harvest.remote(st, f"cd {inbox}/.part && mv -- {names} ..")
    except Exception as e:  # noqa: BLE001  a failed move must not kill the download thread
        log(f"ship: move on {host} failed: {type(e).__name__}: {str(e)[:120]}")
        return False
    return True


def fetch_autosubs(vid, cookies):
    """Best effort: a missing or blocked subtitle track only leaves the channel without a label check."""
    AUTOSUBS.mkdir(exist_ok=True)
    own = AUTOSUBS / f".{vid}.cookies.txt"
    fd = os.open(own, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as f, open(cookies, "rb") as src:
        shutil.copyfileobj(src, f)
    try:
        r = subprocess.run(["yt-dlp", "--no-warnings", "--skip-download", "--write-auto-subs", "--sub-langs", "ru",
                            "--sub-format", "vtt", "--cookies", str(own), "-o", str(AUTOSUBS / f"{vid}.%(ext)s"),
                            f"https://www.youtube.com/watch?v={vid}"], capture_output=True, text=True, timeout=300)
    except subprocess.TimeoutExpired:
        return "timeout"
    finally:
        own.unlink(missing_ok=True)
    if (AUTOSUBS / f"{vid}.ru.vtt").exists():
        return None
    return ((r.stderr or "").strip().splitlines()[-1:] or ["no Russian auto-subs"])[0]


def rp_quote(x):
    import shlex
    return shlex.quote(x)


class Account:
    def __init__(self, cookies, start):
        self.cookies = cookies
        self.name = Path(cookies).stem.replace("cookies_", "").replace("cookies", "acc1")
        self.limit = start
        self.active = 0
        self.quiet_since = time.time()
        self.paused_until = 0.0
        self.unavailable = []
        self.auth_fails = set()


def default_cookies():
    files = [ROOT / "fetch" / "cookies.txt"] + sorted((ROOT / "fetch").glob("cookies_acc*.txt"))
    return [str(f) for f in files if f.exists()]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cookies", default=None, help="comma-separated cookie files, one per account (default: all)")
    ap.add_argument("--parallel", type=int, default=3, help="starting downloads per account; +1 per 5 quiet minutes")
    ap.add_argument("--max-parallel", type=int, default=6, help="per account")
    ap.add_argument("--max-total", type=int, default=24)
    ap.add_argument("--forward", action="store_true", help="walk the queue from the start (pods can't reach YouTube)")
    ap.add_argument("--first", default=None, help="queue file fed before the others, in file order (exam sections)")
    ap.add_argument("--queue", default=None, help="comma-separated queue files (default newdata/manual_order_mac.txt)")
    ap.add_argument("--follow", action="store_true", help="keep running and re-read the queue files every 5 min")
    ap.add_argument("--scout", action="store_true", help="scout whole-video lines at 144p, fetch only close-ups at 720p")
    ap.add_argument("--scout-dry", default=None, metavar="ID[,ID]", help="scout these videos, print the plan, ship nothing")
    ap.add_argument("--channel-cap-hours", type=float, default=6.0,
                    help="R1: at most this many hours of video per channel (~2 h of clips at the usual yield)")
    a = ap.parse_args()
    if a.scout_dry:
        cookies = default_cookies()[0]
        for v in a.scout_dry.split(","):
            res, err = scout(v, cookies)
            if err:
                print(json.dumps(dict(video=v, error=err[0])))
                continue
            kind, secs = plan_sections(res["stretches"], res["duration"])
            print(json.dumps(dict(video=v, plan=kind, sections=[[round(x, 2), round(y, 2)] for x, y in secs],
                                  stretches=len(res["stretches"]), saved_bytes=scout_saving(res, kind, secs),
                                  close_up_share=round(sum(y - x for x, y in res["stretches"]) / max(1, res["duration"]), 2),
                                  **{k: res[k] for k in ("duration", "bytes144", "bytes720")})))
        return
    cap = a.channel_cap_hours * 3600
    ledger = json.loads(LEDGER.read_text()) if LEDGER.exists() else {}
    WORK.mkdir(parents=True, exist_ok=True)
    for d in WORK.iterdir():  # leftovers of a killed run; their videos are not in DONE and get fetched again
        shutil.rmtree(d, ignore_errors=True)
    accounts = [Account(c, a.parallel) for c in (a.cookies.split(",") if a.cookies else default_cookies())]
    done = set(DONE.read_text().split()) if DONE.exists() else set()
    chan_of = {}
    skip = channel_quality.read_skip()
    subs_of = {}  # channel -> videos with saved auto-subs, for the LABEL_SAMPLE sample
    if FEEDER_CHANNELS.exists():
        for line in FEEDER_CHANNELS.read_text().splitlines():
            v, _, c = line.partition("\t")
            if (AUTOSUBS / f"{v}.ru.vtt").exists():
                subs_of[c] = subs_of.get(c, 0) + 1
    speakers_written = set()
    scouted, whole = set(), set()  # section jobs made by the scout; videos it sent whole
    scout_cache = json.loads(SCOUT_CACHE.read_text()) if SCOUT_CACHE.exists() else {}
    queues = [Path(q) for q in a.queue.split(",")] if a.queue else [QUEUE]

    def read_new():
        """Videos from the queue files not seen yet. Lines: "<url>  # <channel>"; channels are interleaved so no
        single speaker fills the corpus (R1)."""
        groups, first = {}, []
        for line in Path(a.first).read_text().splitlines() if a.first and Path(a.first).exists() else []:
            parsed = parse_line(line)
            if parsed and parsed[0] not in done and parsed[0] not in chan_of:
                chan_of[parsed[0]] = parsed[2]
                first.append(parsed[0])
        for qf in queues:
            lines = qf.read_text().splitlines() if qf.exists() else []
            for line in (lines if a.forward else reversed(lines)):
                parsed = parse_line(line)
                if parsed is None:
                    continue
                v, _, ch, _ = parsed
                if v in done or v in chan_of:
                    continue
                chan_of[v] = ch
                groups.setdefault(ch, []).append(v)
        out = first
        while any(groups.values()):
            for ch in list(groups):
                if groups[ch]:
                    out.append(groups[ch].pop(0))
        return out

    todo = read_new()
    log(f"start: {len(todo)} videos to feed, {len(done)} already done, accounts {[x.name for x in accounts]}, "
        f"{len(skip)} channels pruned")
    pos = [0]

    def take():
        """Caller holds lock."""
        if pos[0] >= len(todo):
            return None
        pos[0] += 1
        return todo[pos[0] - 1]

    def refresh():
        # the selection keeps appending to the queue files; pick up new lines without a restart
        while not STOP.exists():
            time.sleep(QUEUE_REFRESH)
            with lock:
                new = read_new()
                todo.extend(new)
                now = channel_quality.read_skip()
                added = {c: w for c, w in now.items() if c not in skip}
                skip.clear()
                skip.update(now)
            if new:
                log(f"queue: +{len(new)} videos")
            for c, w in added.items():
                log(f"channel {c} pruned, no more downloads: {w}")
    if a.follow:
        threading.Thread(target=refresh, daemon=True).start()
    retry = []
    tries = {}
    auth_gate = {}  # video -> accounts it failed on with a sign-in error
    stats = {"ok": 0, "fail": 0, "bytes": 0, "saved": 0}
    backlog = {}
    log_later = []

    def flush_log():
        while log_later:
            log(log_later.pop(0))

    def acquire():
        while not STOP.exists():
            with lock:
                now = time.time()
                for x in accounts:
                    if now >= x.paused_until and now - x.quiet_since > 300 and x.limit < a.max_parallel:
                        x.limit += 1
                        x.quiet_since = now
                        log_later.append(f"{x.name}: downloads {x.limit - 1} -> {x.limit} after 5 quiet minutes")
                free = [x for x in accounts if now >= x.paused_until and x.active < x.limit]
                if free and sum(x.active for x in accounts) < a.max_total:
                    x = min(free, key=lambda x: x.active / x.limit)
                    x.active += 1
                    return x
            flush_log()
            time.sleep(2)
        return None

    def block(x, why):
        """Caller holds lock. Pauses the account and puts back the videos its throttled session reported missing."""
        old = x.limit
        x.limit = max(1, old // 2)
        x.quiet_since = x.paused_until = time.time() + BLOCK_PAUSE
        retry.extend(x.unavailable)
        log_later.append(f"{x.name}: blocked ({why}), downloads {old} -> {x.limit}, paused {BLOCK_PAUSE // 60} min, "
                         f"{len(x.unavailable)} 'unavailable' videos requeued")
        x.unavailable = []

    def pick_pod(inbox):
        """Pods ordered by the backlog of this inbox. Each inbox has its own backlog, so a stuck dataset cutter can't
        starve the collector; a pod whose cutter isn't running gets no sections at all."""
        targets = pods()
        now = time.time()
        seg = inbox == SEG_INBOX
        for st in targets:
            b = backlog.get((st["pod_id"], inbox))
            if b is None or now - b[1] > BACKLOG_TTL:
                alive = "pgrep -fc '[p]od_segments.py' >/dev/null || echo dead; " if seg else ""
                r = harvest.remote(st, f"{alive}ls {inbox} {inbox}/.work 2>/dev/null | grep -c mp4$", check=False)
                out = r.stdout.split()
                n = int(out[-1]) if out and out[-1].isdigit() and "dead" not in out else 10 ** 6
                with lock:
                    backlog[(st["pod_id"], inbox)] = [n, now]
        with lock:
            targets.sort(key=lambda st: backlog[(st["pod_id"], inbox)][0])
            if targets:
                backlog[(targets[0]["pod_id"], inbox)][0] += 1
        return targets

    def worker():
        while not STOP.exists():
            while local_gb() > MAX_LOCAL_GB and not STOP.exists():
                time.sleep(30)
            x = acquire()
            if x is None:
                return
            with lock:
                vid = retry.pop(0) if retry else take()
                # a capped or pruned channel is not marked done: a later run with a higher cap, or after the
                # channel is taken off channel_skip.txt, can still fetch its videos
                while vid is not None and (chan_of.get(vid, "?") in skip or
                                           ledger.get(chan_of.get(vid, "?"), 0) >= cap and chan_of.get(vid, "?") != "?"):
                    vid = take()
            if vid is None:
                with lock:
                    x.active -= 1
                if not a.follow and not any(t.active for t in accounts):
                    return
                time.sleep(30)
                continue
            plan = None
            if a.scout and "@" not in vid and vid not in whole:
                files = None
                with lock:
                    plan = scout_cache.get(vid)
                err = None
                if plan is None:
                    plan, err = scout(vid, x.cookies)
                    if plan is not None:
                        with lock:
                            scout_cache[vid] = plan
                            SCOUT_CACHE.write_text(json.dumps(scout_cache))
            else:
                files, err = download(vid, x.cookies)
            msg = err[0] if err else ""
            with lock:
                x.active -= 1
                if not err:
                    x.unavailable = []
                    x.auth_fails = set()
                elif any(k in msg for k in VIDEO_GATES):
                    pass
                elif any(k in msg for k in AUTH_MARKS):
                    auth_gate.setdefault(vid, set()).add(x.name)
                    if len(auth_gate[vid]) < 2:
                        retry.append(vid)
                        x.auth_fails.add(vid)
                        if len(x.auth_fails) >= AUTH_STRIKES:
                            block(x, f"sign-in errors on {len(x.auth_fails)} different videos")
                elif any(k in msg for k in BLOCK_MARKS):
                    retry.append(vid)
                    block(x, msg[:60])
                elif "Video unavailable" in msg:
                    tries[vid] = tries.get(vid, 0) + 1
                    if tries[vid] < MAX_TRIES:
                        x.unavailable.append(vid)
                        if len(x.unavailable) >= UNAVAILABLE_STREAK:
                            block(x, f"{UNAVAILABLE_STREAK} 'unavailable' in a row")
            flush_log()
            if err:
                log(f"{vid}: {x.name}: download failed: {msg[:200]}")
                stats["fail"] += 1
                shutil.rmtree(WORK / job_stem(vid), ignore_errors=True)
                continue
            if plan is not None:
                kind, secs = plan_sections(plan["stretches"], plan["duration"])
                saved = scout_saving(plan, kind, secs)
                with lock:
                    if kind == "skip":
                        with open(DONE, "a") as f:
                            f.write(vid + "\n")
                    elif kind == "whole":
                        whole.add(vid)
                        retry.insert(0, vid)
                    else:
                        for s_, e_ in secs:
                            job = f"{vid}@{s_:.2f}-{e_:.2f}"
                            if job not in done:
                                chan_of[job] = chan_of.get(vid, "?")
                                scouted.add(job)
                                retry.append(job)
                    stats["saved"] += saved or 0
                what = {"skip": "no close-up face", "whole": "whole video"}.get(kind, f"{len(secs)} sections, "
                                                                                    f"{sum(e - s for s, e in secs) / 60:.1f} min")
                log(f"{vid}: scout: {what} of {plan['duration'] / 60:.1f} min, 144p {plan['bytes144'] / 1e6:.1f} MB, "
                    f"720p saved {'?' if saved is None else f'{saved / 1e6:.0f} MB'}")
                continue
            size = sum(p.stat().st_size for p in files)
            info = next((p for p in files if p.name.endswith(".info.json")), None)
            video, sec = split_job(vid)
            ch = chan_of.get(vid, "?")
            if sec is not None and vid not in scouted and ch != "?":
                got = None  # a dataset speaker id: the uploader (TEDx, a TV channel) is not the speaker
                with lock:
                    if video not in speakers_written:
                        speakers_written.add(video)
                        with open(CHANNELS, "a") as f:
                            f.write(f"{video}\t{ch}\n")
            else:
                got = preflight.remember_channel(video, info) if info else None
                if vid in scouted and info:  # the pod files the section under its own id: train_e2e looks that up
                    preflight.remember_channel(job_stem(vid)[3:], info)
            if ch == "?" and got:
                ch = got[0]
            with lock:
                pruned = ch in skip or bool(got and got[0] in skip)
                over = ch != "?" and ledger.get(ch, 0) >= cap
                if not over and not pruned:
                    ledger[ch] = ledger.get(ch, 0) + (sec[1] - sec[0] if sec else got[1] if got else 0)
                    LEDGER.write_text(json.dumps(ledger, indent=1))
            if over or pruned:
                log(f"{vid}: channel {ch} " + ("is pruned" if pruned else f"is at its cap of {a.channel_cap_hours:g} h")
                    + ", not shipped")
                shutil.rmtree(WORK / job_stem(vid), ignore_errors=True)
                continue
            inbox = SEG_INBOX if sec and vid not in scouted else "/root/newdata/inbox"
            waited = time.time()
            while not STOP.exists():
                targets = [st for st in pick_pod(inbox) if backlog[(st["pod_id"], inbox)][0] <= MAX_BACKLOG]
                if targets:
                    break
                if inbox == SEG_INBOX and time.time() - waited > SEG_WAIT:
                    # no pod cuts dataset sections: give the thread back to whole videos instead of stalling the run
                    log(f"{vid}: no pod with a running dataset cutter for {SEG_WAIT // 60} min, not shipped")
                    break
                time.sleep(20)
            else:
                targets = []
            for st in targets:
                if ship(files, st, inbox):
                    video = vid.split("@")[0]
                    with lock:
                        with open(DONE, "a") as f:
                            f.write(vid + "\n")
                        with open(FEEDER_CHANNELS, "a") as f:
                            f.write(f"{video}\t{ch}\n")
                        # a dataset section has its own transcript; auto-subs check the collector's GigaAM texts
                        want_subs = "@" not in vid and ch != "?" and subs_of.get(ch, 0) < LABEL_SAMPLE
                        if want_subs:
                            subs_of[ch] = subs_of.get(ch, 0) + 1
                    stats["ok"] += 1
                    stats["bytes"] += size
                    log(f"{vid}: {x.name}: {size / 1e6:.0f} MB -> {st['pod_id']} | fed {stats['ok']}, "
                        f"failed {stats['fail']}, {stats['bytes'] / 1e9:.1f} GB")
                    if want_subs:
                        err = fetch_autosubs(video, x.cookies)
                        if err:
                            log(f"{vid}: no auto-subs for the label check: {err[:120]}")
                            with lock:
                                subs_of[ch] -= 1
                    break
            shutil.rmtree(WORK / job_stem(vid), ignore_errors=True)

    threads = [threading.Thread(target=worker) for _ in range(a.max_total)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    log(f"done: fed {stats['ok']}, failed {stats['fail']}, scouting saved {stats['saved'] / 1e9:.1f} GB of 720p")


if __name__ == "__main__":
    main()
