"""Local lip-reading service for the "lips" dictation mode of Velikiy Moguchiy («Великий & Могучий»): the model stays loaded between clips.

  .venv/bin/python lips_service.py [--port 8766] [--idle-sec 600] [--parent-pid PID]

HTTP on 127.0.0.1 only, JSON in and out:
  GET  /health      {"loaded", "loading", "rss_gb", "idle_sec", ...}
  POST /warm        starts loading the model in the background, returns at once
  POST /transcribe  {"path": "/abs/clip.mp4", "rescore": false, "context": ""} ->
                    {"text", "raw", "hyps": [...], "rescored", "timings": {...}}

The process exits after --idle-sec without requests (and when --parent-pid is gone), which is how the model
is unloaded: freeing it inside a live process leaves most of the memory with the allocator. Before loading,
the service refuses to start the model unless --min-avail-gb of RAM is available, so loading never pushes
the Mac into swap. The caller starts the process again on the next clip.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
import traceback
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

# Before memguard (which only fills in unset values) and torch: a hard MPS cap for a process that stays loaded
# next to the user's apps. 0.15 of the recommended working set is 4.2 GB on a 36 GB Mac, enough for an 8 s phrase.
os.environ.setdefault("PYTORCH_MPS_HIGH_WATERMARK_RATIO", "0.15")
os.environ.setdefault("PYTORCH_MPS_LOW_WATERMARK_RATIO", "0.08")
import memguard  # noqa: E402

ROOT = Path(__file__).resolve().parent
DEFAULT_RUN = ROOT / "results" / "pod_runs" / "t1" / "checkpoints" / "me1"


def installed_run() -> Path:
    """The model «Обучить на мне» installed in the app's data directory (personal.py), else DEFAULT_RUN."""
    import personal
    return personal.service_run_dir() or DEFAULT_RUN
PAGE = 16384
SWAP_GROWTH_LIMIT_MB = 256  # as tools/mem_guard.py: the Mac must not swap because of this process


def log(msg: str):
    print(f"{time.strftime('%H:%M:%S')} {msg}", file=sys.stderr, flush=True)


def available_gb() -> float:
    """Free + inactive + speculative + purgeable pages, as tools/mem_guard.py counts them."""
    out = subprocess.run(["vm_stat"], capture_output=True, text=True).stdout
    pages = {m.group(1): int(m.group(2)) for m in re.finditer(r"(.+?):\s+(\d+)\.", out)}
    names = ("Pages free", "Pages inactive", "Pages speculative", "Pages purgeable")
    return sum(pages.get(n, 0) for n in names) * PAGE / 2**30


def swap_used_mb() -> float:
    out = subprocess.run(["sysctl", "-n", "vm.swapusage"], capture_output=True, text=True).stdout
    m = re.search(r"used = ([\d.]+)M", out)
    return float(m.group(1)) if m else 0.0


def rss_gb() -> float:
    out = subprocess.run(["ps", "-o", "rss=", "-p", str(os.getpid())], capture_output=True, text=True).stdout
    return int(out.strip() or 0) / 2**20


class Reader:
    def __init__(self, run: Path, det_every: int, min_avail_gb: float, qwen_model: str):
        self.run, self.det_every, self.min_avail_gb, self.qwen_model = run, det_every, min_avail_gb, qwen_model
        self.model = None
        self.swap0 = swap_used_mb()
        self.load_error: str | None = None
        self.load_sec: float | None = None
        self.loading = threading.Event()
        self.loaded = threading.Event()
        self.state_lock = threading.Lock()
        self.work_lock = threading.Lock()  # one clip at a time on the GPU

    def start_loading(self):
        with self.state_lock:
            if self.loaded.is_set() or self.loading.is_set():
                return
            self.load_error = None
            self.loading.set()
        threading.Thread(target=self._load, daemon=True).start()

    def _load(self):
        try:
            avail = available_gb()
            if avail < self.min_avail_gb:
                raise MemoryError(f"only {avail:.1f} GB of RAM available, the model needs {self.min_avail_gb:g} GB "
                                  f"free to load without swapping")
            t0 = time.perf_counter()
            import mvsr
            self.mvsr = mvsr
            self.model = mvsr.MultiVSR(device="auto", lora=str(self.run / "best.pt"),
                                       venc_ckpt=str(self.run / "best_venc.pth"),
                                       venc_max_frames=25, last_logits_only=True)
            memguard.mps_cleanup()
            self.load_sec = time.perf_counter() - t0
            log(f"model loaded in {self.load_sec:.1f}s on {self.model.device}, rss {rss_gb():.2f} GB, "
                f"available {available_gb():.1f} GB, swap {swap_used_mb() - self.swap0:+.0f} MB")
            self.loaded.set()
        except BaseException as e:  # noqa: BLE001  (SystemExit from mvsr on missing weights included)
            self.load_error = f"{type(e).__name__}: {e}"
            log(f"model load failed: {self.load_error}")
        finally:
            self.loading.clear()

    def wait_loaded(self):
        while not self.loaded.is_set():
            if not self.loading.is_set() and not self.loaded.is_set():
                raise RuntimeError(self.load_error or "model is not loaded")
            time.sleep(0.05)

    def transcribe(self, path: str, rescore: bool, context: str) -> dict:
        self.start_loading()
        from preprocess import preprocess_video
        timings = {}
        with self.work_lock, tempfile.TemporaryDirectory(prefix="lips_svc_") as tmp:
            t0 = time.perf_counter()
            crop = Path(tmp) / "face.avi"
            # the face crop runs on the CPU while a cold model is still loading
            info = preprocess_video(path, str(crop), det_every=self.det_every)
            t1 = time.perf_counter()
            self.wait_loaded()
            t_model = time.perf_counter()
            faces = self.model.load_faces(crop)
            if faces.size(2) <= self.model.chunk_size * 25:
                hyps = self.model.nbest_faces(faces)
                raw = hyps[0]["text"] if hyps else ""
            else:  # n-best covers only the first chunk; long clips are read chunk by chunk
                hyps = []
                raw, _ = self.model.transcribe_faces(faces)
            self.mvsr.sync(self.model.device)
            t2 = time.perf_counter()
            memguard.mps_cleanup()
        timings.update(preprocess=round(t1 - t0, 3), decode=round(t2 - t_model, 3))
        if t_model - t1 > 0.05:
            timings["wait_model"] = round(t_model - t1, 3)
        text, rescored = raw, False
        if rescore and len(hyps) > 1:
            t3 = time.perf_counter()
            try:
                picked = rescore_with_qwen(hyps, context, self.qwen_model)
                if picked:
                    text, rescored = picked, True
            except Exception as e:  # noqa: BLE001  (network or key problems fall back to the model's own pick)
                log(f"rescore failed, keeping the top hypothesis: {type(e).__name__}: {e}")
            timings["rescore"] = round(time.perf_counter() - t3, 3)
        return dict(text=text, raw=raw, rescored=rescored, hyps=hyps[:5], frames=info.get("frames"),
                    timings=timings)


_terms: list[str] | None = None


def rescore_with_qwen(hyps: list[dict], context: str, model: str, timeout: float = 8.0) -> str:
    """Variant B of llm_rescore.py (n-best plus a dictation context), with a short timeout and no retry loop:
    a dictation waits for this call."""
    import llm_rescore
    global _terms
    if _terms is None:
        _terms = []
        if llm_rescore.DICT.exists():
            lines = llm_rescore.DICT.read_text().splitlines()
            _terms = [t.split("|")[0].strip() for t in lines if t.strip() and not t.startswith("#")][:150]
    user = llm_rescore.prompt({"hyps": hyps}, "B", _terms)
    if context:
        user = f"Где диктуют: {context}.\n" + user
    body = {"model": model, "stream": False, "enable_thinking": False, "temperature": 0.2,
            "messages": [{"role": "system", "content": llm_rescore.SYSTEM}, {"role": "user", "content": user}]}
    last = None
    for key in llm_rescore.api_key()[:2]:
        req = urllib.request.Request(llm_rescore.URL, data=json.dumps(body).encode(), headers={
            "Authorization": "Bearer " + key, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                out = json.loads(r.read())["choices"][0]["message"]["content"].strip()
            return out.splitlines()[0].strip(" «»\"") if out else ""
        except (urllib.error.URLError, TimeoutError, KeyError, ValueError) as e:
            last = e
    raise RuntimeError(f"DashScope: {last}")


class Handler(BaseHTTPRequestHandler):
    server_version = "lips-service/1"

    def log_message(self, fmt, *args):
        pass

    def _send(self, code: int, obj: dict):
        data = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _body(self) -> dict:
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}") if n else {}

    def do_GET(self):
        app = self.server.app
        if self.path != "/health":
            return self._send(404, {"error": "not found"})
        r = app.reader
        self._send(200, dict(loaded=r.loaded.is_set(), loading=r.loading.is_set(), load_error=r.load_error,
                             load_sec=r.load_sec, rss_gb=round(rss_gb(), 2), idle_sec=round(app.idle(), 1),
                             idle_limit_sec=app.idle_limit, pid=os.getpid(), det_every=r.det_every))

    def do_POST(self):
        app = self.server.app
        app.touch()
        app.begin()
        try:
            if self.path == "/warm":
                app.reader.start_loading()
                return self._send(200, {"loaded": app.reader.loaded.is_set()})
            if self.path != "/transcribe":
                return self._send(404, {"error": "not found"})
            req = self._body()
            path = str(req.get("path") or "")
            if not os.path.isabs(path) or not os.path.isfile(path):
                return self._send(400, {"error": f"no such file: {path}"})
            t0 = time.perf_counter()
            res = app.reader.transcribe(path, bool(req.get("rescore")), str(req.get("context") or ""))
            res["timings"]["total"] = round(time.perf_counter() - t0, 3)
            log(f"{Path(path).name}: {res['timings']} -> {res['text']!r}" +
                (f" (model: {res['raw']!r})" if res["rescored"] else ""))
            self._send(200, res)
        except Exception as e:  # noqa: BLE001
            msg = f"{type(e).__name__}: {e}"
            log(f"request failed: {msg}\n{traceback.format_exc()}")
            self._send(500, {"error": msg})
        finally:
            app.end()
            app.touch()


class App:
    def __init__(self, reader: Reader, idle_limit: float, parent_pid: int, follow_installed: bool = False):
        self.reader, self.idle_limit, self.parent_pid = reader, idle_limit, parent_pid
        self.follow_installed = follow_installed  # no --run: exit when «Обучить на мне» installs or rolls back
        self.last = time.monotonic()
        self.inflight = 0  # requests being answered, rescoring included (it runs outside the reader's work lock)
        self.inflight_lock = threading.Lock()

    def begin(self):
        with self.inflight_lock:
            self.inflight += 1

    def end(self):
        with self.inflight_lock:
            self.inflight -= 1

    def busy(self) -> bool:
        return self.inflight > 0 or self.reader.work_lock.locked()

    def touch(self):
        self.last = time.monotonic()

    def idle(self) -> float:
        return time.monotonic() - self.last

    def watchdog(self, server: ThreadingHTTPServer):
        while True:
            time.sleep(2)
            if self.parent_pid and not _alive(self.parent_pid):
                log(f"parent {self.parent_pid} is gone, exiting")
                break
            grown = swap_used_mb() - self.reader.swap0
            if grown > SWAP_GROWTH_LIMIT_MB and not self.reader.work_lock.locked():
                log(f"swap grew by {grown:.0f} MB since start, exiting to give the memory back")
                break
            if self.idle() > self.idle_limit and not self.reader.work_lock.locked():
                log(f"idle for {self.idle():.0f}s, exiting to free the model's memory")
                break
            if self.follow_installed and not self.busy() and installed_run() != self.reader.run:
                log(f"the installed model is now {installed_run()}, exiting; the app starts the service again")
                break
        server.shutdown()


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8766)
    ap.add_argument("--idle-sec", type=float, default=600)
    ap.add_argument("--parent-pid", type=int, default=0)
    ap.add_argument("--run", default=None, help="folder with best.pt and best_venc.pth (default: the model installed "
                    "by «Обучить на мне» in the app's data directory, else results/pod_runs/t1/checkpoints/me1)")
    ap.add_argument("--det-every", type=int, default=5, help="run the face detector on every N-th frame")
    ap.add_argument("--min-avail-gb", type=float, default=10,
                    help="refuse to load the model with less RAM available (it peaks at about 5.5 GB)")
    ap.add_argument("--qwen-model", default="qwen3.8-omni-flash")
    ap.add_argument("--warm", action="store_true", help="load the model right away")
    a = ap.parse_args()
    reader = Reader(Path(a.run) if a.run else installed_run(), a.det_every, a.min_avail_gb, a.qwen_model)
    app = App(reader, a.idle_sec, a.parent_pid, follow_installed=a.run is None)
    server = ThreadingHTTPServer(("127.0.0.1", a.port), Handler)
    server.daemon_threads = True
    server.app = app
    log(f"listening on 127.0.0.1:{a.port}, pid {os.getpid()}, idle limit {a.idle_sec:g}s, model {reader.run}")
    if a.warm:
        reader.start_loading()
    threading.Thread(target=app.watchdog, args=(server,), daemon=True).start()
    server.serve_forever()
    log("stopped")


if __name__ == "__main__":
    os.chdir(ROOT)
    sys.path.insert(0, str(ROOT))
    main()
