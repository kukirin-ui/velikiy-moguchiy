"""End-to-end check of lips_service.py with the real model: start, read test clips warm, exit when idle.

  .venv/bin/python tests/test_lips_service.py [--clips 001,005,013] [--rescore]

Needs the weights and about 12 GB of free RAM. Prints cold and warm latency per clip.
"""
import argparse
import json
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def call(port, path, body=None, timeout=180):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--clips", default="001,005,013")
    ap.add_argument("--rescore", action="store_true")
    ap.add_argument("--idle-sec", type=float, default=20)
    a = ap.parse_args()
    port = free_port()
    proc = subprocess.Popen([sys.executable, str(ROOT / "lips_service.py"), "--port", str(port),
                             "--idle-sec", str(a.idle_sec)], cwd=ROOT)
    try:
        for _ in range(100):
            try:
                health = call(port, "/health", timeout=1)
                break
            except OSError:
                time.sleep(0.1)
        else:
            sys.exit("service did not start")
        assert not health["loaded"]
        ids = a.clips.split(",")
        for rnd, batch in (("cold", ids[:1]), ("warm", ids)):
            for i in batch:
                t0 = time.perf_counter()
                res = call(port, "/transcribe", {"path": str(ROOT / "clips" / f"{i}.mp4"), "rescore": a.rescore})
                wall = time.perf_counter() - t0
                ref = (ROOT / "clips" / f"{i}.txt").read_text().strip()
                print(f"{rnd} {i} {wall:5.2f}s {res['timings']}\n   ref:  {ref}\n   text: {res['text']}"
                      + (f"\n   raw:  {res['raw']}" if res["rescored"] else ""), flush=True)
                assert isinstance(res["text"], str) and res["hyps"], res
        health = call(port, "/health")
        print(f"health: {health}", flush=True)
        assert health["loaded"]
        try:
            call(port, "/transcribe", {"path": "/nonexistent.mp4"}, timeout=5)
            raise AssertionError("a missing file must be refused")
        except urllib.error.HTTPError as e:
            assert e.code == 400
        t0 = time.monotonic()
        proc.wait(timeout=a.idle_sec + 30)
        print(f"exited by itself {time.monotonic() - t0:.0f}s after the last request (limit {a.idle_sec:g}s)")
    finally:
        if proc.poll() is None:
            proc.terminate()


if __name__ == "__main__":
    main()
