"""Offline tests for harvest.py: python3 -m unittest harvester/test_harvest.py (from lipread).
Nothing here touches RunPod, the real pool or real cookies: a fake zgnspaces HTTP server and a fake cookie exporter."""
import argparse
import contextlib
import importlib.util
import io
import json
import os
import stat
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("harvest", HERE / "harvest.py")
h = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(h)

TOKEN = "test-token-" + os.urandom(6).hex()
SECRET = "SECRET-COOKIE-VALUE-" + os.urandom(6).hex()
FAKE_EXPORT = """\
import os, sys
port, out = sys.argv[1:3]
assert port == "9333", port
open(out, "w").write("# Netscape HTTP Cookie File\\n.youtube.com\\tTRUE\\t/\\tTRUE\\t0\\tSAPISID\\t%s\\n" % os.environ["SECRET"])
print("1 cookies written, logged in: " + os.environ["FAKE_LOGGED_IN"])
"""


class Zgn(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, token, profiles):
        self.calls, self.token, self.profiles = [], token, profiles
        super().__init__(("127.0.0.1", 0), ZgnHandler)


class ZgnHandler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, obj):
        raw = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _handle(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(n)) if n else None
        if self.headers.get("Authorization") != "Bearer " + self.server.token:
            return self._send(401, {"error": "unauthorized"})
        self.server.calls.append((self.command, self.path, body))
        if self.path == "/v1/profiles":
            return self._send(200, self.server.profiles)
        if self.path.endswith("/run"):
            return self._send(200, {"remote_debugging_port": 9333})
        if self.path.endswith("/kill"):
            return self._send(200, {"ok": True})
        self._send(404, {})

    do_GET = do_POST = _handle


class Decoy(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), type("D", (BaseHTTPRequestHandler,), {
            "log_message": lambda *a: None,
            "do_GET": lambda s: (s.send_response(404), s.send_header("Content-Length", "0"), s.end_headers())}))


def serve(srv):
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        (self.tmp / "fetch").mkdir()
        self.saved = {k: getattr(h, k) for k in ("ROOT", "HERE", "POOL", "LOG", "PUB", "DIST", "EXPORT_CMD", "NAME")}
        h.ROOT, h.HERE, h.POOL, h.LOG = self.tmp, self.tmp, self.tmp / "accounts.json", self.tmp / "harvest.log"
        h.PUB, h.DIST = self.tmp / "pub", self.tmp / "dist"
        h.NAME = "a"
        h.LOG.write_text("")
        h._zgn.clear()
        fake = self.tmp / "fake_export.py"
        fake.write_text(FAKE_EXPORT)
        h.EXPORT_CMD = [sys.executable, str(fake)]
        os.environ.update(ZGN_TOKEN=TOKEN, SECRET=SECRET, FAKE_LOGGED_IN="true")
        os.environ.pop("ZGN_PORT", None)

    def tearDown(self):
        for k, v in self.saved.items():
            setattr(h, k, v)

    def enter(self, cm):
        cm.start()
        self.addCleanup(cm.stop)

    def pool(self, d):
        h.POOL.write_text(json.dumps(d))

    def read_pool(self):
        return json.loads(h.POOL.read_text())


class ProfileAccounts(Base):
    def setUp(self):
        super().setUp()
        self.decoy = serve(Decoy())
        self.zgn = serve(Zgn(TOKEN, [{"id": "p7", "name": "yt-seven"}, {"id": "p8", "name": "yt-eight"}]))
        self.addCleanup(self.decoy.shutdown)
        self.addCleanup(self.zgn.shutdown)
        os.environ["ZGN_PORT"] = str(self.zgn.server_address[1])  # speeds up the probe; one test drops it

    def test_port_found_by_probing(self):
        del os.environ["ZGN_PORT"]  # the real path: lsof + GET /v1/profiles on every loopback listener
        self.assertEqual(h.zgn_port(), self.zgn.server_address[1])

    def test_export_runs_exports_kills_and_chmods(self):
        out = h.export_profile_cookies("acc7", "yt-seven")
        self.assertEqual(out, self.tmp / "fetch" / "cookies_acc7.txt")
        self.assertEqual(stat.S_IMODE(out.stat().st_mode), 0o600)
        calls = [(m, p) for m, p, _ in self.zgn.calls]
        self.assertEqual(calls[-2:], [("POST", "/v1/profiles/p7/run"), ("POST", "/v1/profiles/p7/kill")])
        self.assertEqual(self.zgn.calls[-2][2], {"headless": False})
        self.assertFalse((self.tmp / "fetch" / "cookies_acc7.txt.new").exists())

    def test_logged_out_burns_and_next_account_is_tried(self):
        self.pool({"a1": {"profile": "yt-seven", "pod": None, "burned": False},
                   "a2": {"profile": "yt-eight", "pod": None, "burned": False},
                   "a3": {"file": "fetch/cookies_a3.txt", "pod": None, "burned": False}})
        (self.tmp / "fetch" / "cookies_a3.txt").write_text("x")
        os.environ["FAKE_LOGGED_IN"] = "false"
        got = h.claim_account({"account": None}, "test")
        self.assertEqual(got, ("a3", self.tmp / "fetch" / "cookies_a3.txt"))
        pool = self.read_pool()
        for k in ("a1", "a2"):
            self.assertTrue(pool[k]["burned"])
            self.assertIn("logged out", pool[k]["reason"])
            self.assertFalse((self.tmp / "fetch" / f"cookies_{k}.txt").exists())  # nothing left on disk
        self.assertEqual(pool["a3"]["pod"], "a")
        self.assertEqual(sum(1 for m, p, _ in self.zgn.calls if p.endswith("/kill")), 2)  # killed every time

    def test_rotate_burns_current_with_reason_and_takes_profile_account(self):
        self.pool({"cur": {"file": "x", "pod": "a", "burned": False},
                   "nxt": {"profile": "yt-eight", "pod": None, "burned": False}})
        got = h.claim_account({"account": "cur"}, "cookies rejected")
        self.assertEqual(got[0], "nxt")
        pool = self.read_pool()
        self.assertEqual((pool["cur"]["burned"], pool["cur"]["reason"], pool["cur"]["pod"]),
                         (True, "cookies rejected", None))
        self.assertEqual(pool["nxt"]["pod"], "a")

    def test_no_token_does_not_burn(self):
        self.pool({"a1": {"profile": "yt-seven", "pod": None, "burned": False}})
        del os.environ["ZGN_TOKEN"]
        self.assertIsNone(h.claim_account({}, "t"))
        self.assertEqual(self.read_pool()["a1"], {"profile": "yt-seven", "pod": None, "burned": False})

    def test_token_and_cookies_never_printed_or_logged(self):
        self.pool({"a1": {"profile": "yt-seven", "pod": None, "burned": False, "reason": None}})
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            h.claim_account({}, "t")
            h.cmd_accounts(None)
        text = buf.getvalue() + h.LOG.read_text()
        self.assertNotIn(TOKEN, text)
        self.assertNotIn(SECRET, text)
        self.assertIn("yt-seven", text)

    def test_accounts_listing(self):
        self.pool({"a1": {"profile": "yt-seven", "pod": "p1", "burned": False},
                   "a2": {"file": "fetch/c.txt", "pod": None, "burned": True, "reason": "cookies rejected"}})
        (self.tmp / "fetch" / "c.txt").write_text(SECRET)
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            h.cmd_accounts(None)
        out = buf.getvalue()
        self.assertIn("yt-seven", out)
        self.assertIn("yes (cookies rejected)", out)
        self.assertNotIn(SECRET, out)


class Pack(Base):
    def test_spread_matches_linspace(self):
        try:
            import numpy as np
        except ImportError:
            self.skipTest("no numpy")
        for n in (1, 2, 7, 30, 50):
            for total in (n, n + 1, 61, 200, 997):
                clips = list(range(total))
                want = sorted(set(np.linspace(0, total - 1, n).round().astype(int).tolist())) if n > 1 else [0]
                self.assertEqual(h.spread(clips, n) if total > n else clips,
                                 want if total > n else clips, (n, total))

    def test_pack_caps_clips_per_video(self):
        (self.tmp / "data" / "public_meta").mkdir(parents=True)
        (self.tmp / "fetch" / "selection_ru.jsonl").write_text(json.dumps({"video_id": "vX"}) + "\n")
        rows = []
        for v, n in (("v1", 100), ("v2", 10)):
            for i in range(n):
                rows.append({"video_id": v, "split": "train_major", "track": 0, "start": i * 1000, "length": 100,
                             "transcript": "a b c d", "t_start": i * 4.0, "track_frame0": 0, "track_n": 3000})
        (self.tmp / "data" / "public_meta" / "ru.jsonl").write_text("\n".join(map(json.dumps, rows)))
        (self.tmp / "fetch" / "x.py").write_text("x")
        h.BUNDLE_PATHS = ["fetch/x.py"]
        h.cmd_pack(argparse.Namespace(max_clips_per_video=30))
        sel = [json.loads(l) for l in open(self.tmp / "dist" / "selection_pod-a.jsonl")]
        by = {}
        for r in sel:
            by.setdefault(r["video_id"], []).append(r["start"] // 1000)
        self.assertEqual(len(by["v1"]), 30)
        self.assertEqual((by["v1"][0], by["v1"][-1]), (0, 99))  # spread over the whole video
        self.assertEqual(len(by["v2"]), 10)
        h.cmd_pack(argparse.Namespace(max_clips_per_video=0))
        self.assertEqual(sum(1 for _ in open(self.tmp / "dist" / "selection_pod-a.jsonl")), 110)


class Spot(Base):
    def launch_ns(self, **kw):
        d = dict(gpu="NVIDIA A100-SXM4-80GB", cpu=0, cpu_flavor="cpu5c", dc="EU-RO-1", volume_gb=200, max_hours=8,
                 workers="auto", crop="auto", community=False, with_npy=False, spot=True, max_clips_per_video=30,
                 every=0, dry_run=True, cookies="x", account=None, repack=False)
        d.update(kw)
        return argparse.Namespace(**d)

    def test_body_interruptible_only_with_spot(self):
        self.assertIs(h.pod_body(self.launch_ns())["interruptible"], True)
        self.assertNotIn("interruptible", h.pod_body(self.launch_ns(spot=False)))

    def test_dry_run_quotes_spot_price(self):
        buf = io.StringIO()
        with mock.patch.object(h, "gpu_offer", lambda gpu, secure=True: (1.79, 16, 0.62)), \
                contextlib.redirect_stdout(buf):
            h.cmd_launch(self.launch_ns())
        self.assertIn("minimumBidPrice $0.62/h", buf.getvalue())
        self.assertIn('"interruptible": true', buf.getvalue())

    def state(self, **kw):
        st = {"pod_id": "old", "created": time.time() - 600, "deadline": time.time() + 5 * 3600, "rate": 0.6,
              "spot": True, "launch": vars(self.launch_ns()), "cookies": str(self.tmp / "fetch" / "cookies.txt"),
              "host": "h", "port": 1}
        st.update(kw)
        return st

    def patch_world(self):
        self.created, self.pulls = [], []

        def create(a, cookies, deadline=None, account=None, prev=None):
            st = {k: prev[k] for k in ("relaunches", "spent_prev") if k in prev}
            st.update(pod_id=f"new{len(self.created)}", created=time.time(), deadline=deadline, rate=0.6, spot=True,
                      launch=prev["launch"], cookies="c")
            self.created.append(st)
            h.save_state(st)
            return st
        for name, val in dict(pull=lambda st: self.pulls.append(st["pod_id"]) or True, balance=lambda: (50.0, 1.0),
                              cmd_pack=lambda a=None: None, relaunch_cookies=lambda st: Path("c"),
                              pod_alive=lambda st: False, create_pod=create).items():
            self.enter(mock.patch.object(h, name, val))
        self.enter(mock.patch.object(h.rp, "req", lambda *a, **k: {}))
        self.enter(mock.patch.object(h.time, "sleep", lambda s: None))

    def run_watch(self, st):
        h.save_state(st)
        h.cmd_watch(argparse.Namespace(every=0))

    def test_three_relaunches_then_stop(self):
        self.patch_world()
        self.run_watch(self.state())
        self.assertEqual(len(self.created), 3)
        self.assertEqual(self.pulls[0], "old")  # final pull attempted for the lost pod
        self.assertTrue(all(c["deadline"] == self.created[0]["deadline"] for c in self.created))  # deadline kept
        self.assertIn("3 relaunches within an hour", h.LOG.read_text())

    def test_no_relaunch_after_stop_deadline_or_for_on_demand(self):
        self.patch_world()
        for st in (self.state(spot=False), self.state(deadline=time.time() - 5)):
            self.run_watch(st)
        h.save_state(self.state())
        with mock.patch.object(h, "pod_alive", lambda st: (h.state_file().unlink(), False)[1]):  # `stop` ran meanwhile
            h.cmd_watch(argparse.Namespace(every=0))
        self.assertEqual(self.created, [])

    def test_too_little_time_or_balance(self):
        self.patch_world()
        self.assertIsNone(h.relaunch(self.state(deadline=time.time() + 600)))
        with mock.patch.object(h, "balance", lambda: (0.1, 2.0)):
            self.assertIsNone(h.relaunch(self.state()))
        self.assertEqual(self.created, [])


if __name__ == "__main__":
    unittest.main()
