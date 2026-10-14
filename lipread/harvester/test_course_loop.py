"""Offline tests of the course-correction loop: python3 -m unittest harvester/test_course_loop.py (from lipread).
No pod, no YouTube, no model: stub collector output, a stub feeder environment and a fake training pod."""
import argparse
import contextlib
import io
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(ROOT))
import channel_quality as cq  # noqa: E402
import checkpoint_loop as cl  # noqa: E402
import exams  # noqa: E402
import split  # noqa: E402

VTT_TAGGED = """WEBVTT
Kind: captions
Language: ru

00:00:10.000 --> 00:00:12.000 align:start position:0%

привет<00:00:10.500><c> как</c><00:00:11.000><c> дела</c>

00:00:12.000 --> 00:00:12.010 align:start position:0%
привет как дела


00:00:12.010 --> 00:00:14.000 align:start position:0%
привет как дела
у<00:00:12.500><c> меня</c><00:00:13.000><c> 15</c><00:00:13.500><c> котов</c>
"""


def channels_by_split(n_train, n_dev):
    tr, dv, i = [], [], 0
    while len(tr) < n_train or len(dv) < n_dev:
        ch = f"@chan{i}"
        (dv if split.split_for(f"ch:{ch}", 3) == "dev" else tr).append(ch)
        i += 1
    return tr[:n_train], dv[:n_dev]


class Tmp(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.patches = contextlib.ExitStack()
        self.addCleanup(self.patches.close)

    def patch(self, obj, name, value):
        self.patches.enter_context(mock.patch.object(obj, name, value))


def rv_row(vid, status, dur, clip_sec, n_seg=100, rej=None, drops=None, reason=None):
    probe = json.dumps({"video": {"n_seg": n_seg, "seg_face_rej": rej or {}, "s8_drops": drops or {}, "dur": dur}})
    return dict(video_id="yt_" + vid, status=status, stage="s8_clips", reason=reason, dur=dur, clips=0,
                clip_sec=clip_sec, probe=probe, updated=time.time())


class ChannelQuality(Tmp):
    def setUp(self):
        super().setUp()
        t = self.tmp
        self.mirror = t / "public_pod"
        self.mirror.mkdir()
        for name, val in dict(MIRROR=self.mirror, OUT=t / "cq.json", CACHE=t / "cache.json", SKIP=t / "skip.txt",
                              PRUNE_LOG=t / "prune.log", FEEDER_CHANNELS=t / "feeder.tsv",
                              VIDEO_CHANNELS=t / "vc.tsv", LEDGER=t / "ledger.json", AUTOSUBS=t / "subs",
                              QUEUES=[t / "queue.txt"]).items():
            self.patch(cq, name, val)
        (t / "subs").mkdir()
        (t / "feeder.tsv").write_text("".join(f"{v}\t{c}\n" for v, c in [
            ("bad1", "@bad"), ("bad2", "@bad"), ("bad3", "@bad"), ("good1", "@good"), ("good2", "@good"),
            ("good3", "@good"), ("new1", "@new"), ("new2", "@new"), ("man1", "manual"), ("man2", "manual"),
            ("man3", "manual")]))
        rows = [rv_row("bad1", "done", 1800, 60, rej={"small": 70}, drops={"sync": 20}),
                rv_row("bad2", "done", 1200, 0, rej={"small": 90}), rv_row("bad3", "done", 600, 30),
                rv_row("good1", "done", 1000, 400), rv_row("good2", "done", 1000, 300),
                rv_row("good3", "failed", 0, 0), rv_row("good3x", "rej", 0, 0, reason="download_gone"),
                rv_row("new1", "done", 1000, 0), rv_row("new2", "done", 1000, 0),
                rv_row("man1", "done", 1000, 0), rv_row("man2", "done", 1000, 0), rv_row("man3", "done", 1000, 0)]
        (self.mirror / "_pod_p1_rv_videos.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows[:6]))
        (self.mirror / "_pod_p2_rv_videos.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows[6:]))
        clips = [("good1", 10.0, 12.0, "привет как дела", 720, 6.0), ("good1", 12.0, 14.0, "у меня пятнадцать котов", 720, 2.0),
                 ("good2", 1.0, 3.0, "раз два", 360, 7.0)]
        for i, (v, a, b, text, h, sync) in enumerate(clips):
            stem = f"yt_{v}__00000_{i:06d}"
            (self.mirror / f"{stem}.json").write_text(json.dumps(dict(
                video_id="yt_" + v, start=a, end=b, frames=int((b - a) * 25), src_height=h, scores={"sync_conf": sync})))
            (self.mirror / f"{stem}.txt").write_text(text + "\n")
        (t / "subs" / "good1.ru.vtt").write_text(VTT_TAGGED)

    def test_vtt_words(self):
        w = cq.vtt_words(VTT_TAGGED)
        self.assertEqual([x for _, x in w], ["привет", "как", "дела", "у", "меня", "15", "котов"])
        self.assertEqual(w[0][0], 10.0)
        self.assertEqual(w[5][0], 13.0)
        plain = "WEBVTT\n\n00:00:01.000 --> 00:00:03.000\nодин два\n"
        self.assertEqual(cq.vtt_words(plain), [(1.0, "один"), (2.0, "два")])

    def test_report_and_prune(self):
        lines = cq.update()
        r = json.loads(cq.OUT.read_text())
        bad, good = r["channels"]["@bad"], r["channels"]["@good"]
        self.assertEqual(bad["videos_done"], 3)
        self.assertAlmostEqual(bad["yield"], 90 / 3600, places=3)
        self.assertEqual(bad["top_rejections"][0][:2], ["face:small", 160])
        self.assertEqual((good["videos_done"], good["videos_failed"]), (2, 1))
        self.assertEqual(good["yield"], 0.35)
        self.assertEqual(good["src_height"], {"360": 0.333, "720": 0.667})
        self.assertEqual(good["sync_below_3"], 0.333)
        self.assertEqual(good["label_wer"], 0.0)  # "15" in the auto-subs == "пятнадцать" after normalize_loose
        self.assertEqual(good["label_words"], 7)
        self.assertEqual(r["channels"]["?"]["videos_rejected"], 1)
        # only @bad: @new has 2 videos, manual is a bucket of speakers
        self.assertEqual(len(lines), 1)
        self.assertIn("pruned @bad: yield 2.5% over 3 videos", lines[0])
        self.assertEqual(list(cq.read_skip()), ["@bad"])
        self.assertIn("@bad", cq.PRUNE_LOG.read_text())
        self.assertTrue(bad["pruned"])
        self.assertNotIn("pruned", good)
        self.assertEqual(cq.update(), [])  # idempotent
        self.assertEqual(cq.SKIP.read_text().count("@bad"), 1)

    def test_cache_rereads_only_changed_videos(self):
        cq.update(False)
        with mock.patch.object(cq, "label_check", side_effect=AssertionError("re-read")):
            cq.update(False)
        stem = "yt_good2__00000_000099"
        (self.mirror / f"{stem}.json").write_text(json.dumps(dict(video_id="yt_good2", frames=50, src_height=720)))
        cq.update(False)
        self.assertEqual(json.loads(cq.OUT.read_text())["channels"]["@good"]["clips"], 4)

    def test_pull_dump_reads_rv_state_db(self):
        sys.argv = ["x"]
        import harvest
        db = self.tmp / "rv_state.db"
        c = sqlite3.connect(db)
        c.executescript("""CREATE TABLE videos(video_id TEXT PRIMARY KEY, title TEXT, channel TEXT, channel_id TEXT,
            dur REAL, source TEXT, status TEXT, stage TEXT, reason TEXT, info TEXT, probe TEXT, clips INTEGER DEFAULT 0,
            clip_sec REAL DEFAULT 0, added REAL, updated REAL);""")
        c.execute("INSERT INTO videos(video_id, dur, status, stage, probe, clips, clip_sec, updated) VALUES "
                  "('yt_bad1', 1800, 'done', 's8_clips', ?, 3, 60, 1)", (json.dumps({"video": {"n_seg": 5}}),))
        c.execute("INSERT INTO videos(video_id, status) VALUES ('yt_q', 's1_ok')")
        c.commit()
        c.execute("PRAGMA journal_mode=WAL")
        c.close()
        out = self.tmp / "dumped"
        out.mkdir()
        script = harvest.DUMP_RV.replace("/root/newdata/rv_state.db", str(db)).replace(
            "/root/newdata/rv_videos.jsonl", str(out / "_pod_p9_rv_videos.jsonl"))
        subprocess.run(["bash", "-c", script], check=True)
        recs = cq.collector_records(out)
        self.assertEqual(list(recs), ["bad1"])
        self.assertEqual(json.loads(recs["bad1"]["probe"])["video"]["n_seg"], 5)


_time = time


class FakeTime:
    sleep = staticmethod(lambda s: _time.sleep(min(s, 0.02)))
    time = staticmethod(_time.time)
    strftime = staticmethod(_time.strftime)


class Feeder(Tmp):
    def setUp(self):
        super().setUp()
        sys.argv = ["x"]
        import mac_feeder as mf
        import preflight
        self.mf, t = mf, self.tmp
        for name, val in dict(DONE=t / "done.txt", STOP=t / "STOP", WORK=t / "work", LOG=t / "feeder.log",
                              LEDGER=t / "ledger.json", FEEDER_CHANNELS=t / "feeder.tsv", AUTOSUBS=t / "subs",
                              time=FakeTime).items():
            self.patch(mf, name, val)
        if hasattr(mf, "CHANNELS"):
            self.patch(mf, "CHANNELS", t / "vc.tsv")
        self.patch(preflight, "CHANNELS", t / "vc.tsv")
        self.patch(cq, "SKIP", t / "skip.txt")
        self.downloads, self.subs = [], []
        self.patch(mf, "default_cookies", lambda: [str(t / "cookies.txt")])
        self.patch(mf, "pods", lambda: [dict(pod_id="pod1", host="h", port=1)])
        self.patch(mf.harvest, "remote", lambda *a, **k: argparse.Namespace(stdout="0", returncode=0))
        self.patch(mf, "ship", lambda *a, **k: True)
        self.patch(mf, "fetch_autosubs", self.fake_subs)
        self.patch(mf, "download", self.fake_download)
        self.on_download = None

    def fake_download(self, job, cookies):
        self.downloads.append(job)
        if self.on_download:
            self.on_download(job)
        d = self.mf.WORK / job
        d.mkdir(parents=True, exist_ok=True)
        (d / f"{job}.mp4").write_bytes(b"x" * 10)
        (d / f"{job}.info.json").write_text(json.dumps({"channel_id": "UC" + job[:3], "duration": 600}))
        return [d / f"{job}.mp4", d / f"{job}.info.json"], None

    def fake_subs(self, vid, cookies):
        self.subs.append(vid)
        (self.mf.AUTOSUBS).mkdir(exist_ok=True)
        (self.mf.AUTOSUBS / f"{vid}.ru.vtt").write_text(VTT_TAGGED)

    def queue(self, rows):
        q = self.tmp / "queue.txt"
        q.write_text("".join(f"https://www.youtube.com/watch?v={v}  # {c}\n" for v, c in rows))
        return q

    def run_feeder(self, q, *extra):
        argv = ["mac_feeder.py", "--queue", str(q), "--forward", "--parallel", "1", "--max-parallel", "1",
                "--max-total", "1", *extra]
        with mock.patch.object(sys, "argv", argv):
            self.mf.main()

    def test_queue_labels_are_handles_not_sections(self):
        pl = self.mf.parse_line
        self.assertEqual(pl("https://www.youtube.com/watch?v=AbCdEfGhIjK  # @handle"),
                         ("AbCdEfGhIjK", "AbCdEfGhIjK", "@handle", None))
        self.assertEqual(pl("https://www.youtube.com/watch?v=abc  # muavic:abc  @12.5-20"),
                         ("abc@12.50-20.00", "abc", "muavic:abc", (12.5, 20.0)))
        self.assertEqual(pl("https://www.youtube.com/watch?v=abc  # @handle @1-2")[2:], ("@handle", (1.0, 2.0)))

    def test_skip_list_and_label_sample(self):
        (self.tmp / "skip.txt").write_text("@bad  # 2026-10-13 yield 2.5% over 3 videos\n")
        q = self.queue([("g1", "@good"), ("b1", "@bad"), ("g2", "@good"), ("b2", "@bad"), ("g3", "@good")])
        self.run_feeder(q)
        self.assertEqual(self.downloads, ["g1", "g2", "g3"])
        self.assertEqual(self.mf.DONE.read_text().split(), ["g1", "g2", "g3"])
        self.assertEqual(self.mf.FEEDER_CHANNELS.read_text(), "g1\t@good\ng2\t@good\ng3\t@good\n")
        self.assertEqual(self.subs, ["g1", "g2"])
        self.assertIn("1 channels pruned", self.mf.LOG.read_text())

    def test_follow_rereads_skip_list(self):
        rows = [(f"{c[1]}{i}", c) for i in range(1, 7) for c in ("@good", "@bad")]
        q = self.queue(rows)
        pruned_at = []

        def on_download(job):
            if job == "b1":
                (self.tmp / "skip.txt").write_text("@bad  # test prune\n")
                pruned_at.append(len(self.downloads))
            elif pruned_at:
                time.sleep(0.1)  # the refresh thread runs every 0.02 s here
            if job == "g6":
                self.mf.STOP.touch()
        self.on_download = on_download
        self.run_feeder(q, "--follow")
        self.assertEqual([d for d in self.downloads if d.startswith("b")], ["b1"])
        self.assertIn("channel @bad pruned, no more downloads: test prune", self.mf.LOG.read_text())
        self.assertTrue(all(d in self.downloads for d in ("g1", "g2", "g3", "g4", "g5")))


def exam_result(name, a, owner=None, beam=5):
    """a, owner: errors per clip of 10 words (WER = mean errors * 10)."""
    def ex(errs):
        items = [[f"c{i}", "spk", e, 10, "hyp"] for i, e in enumerate(errs)]
        n = 10 * len(errs)
        return dict(wer=round(100 * sum(errs) / n, 2), errors=sum(errs), words=n, clips=len(errs), frozen="t",
                    complete=True, speaker_wer={}, items=items)
    out = dict(name=name, ckpt=f"checkpoints/{name}/best.pt", time="2026-10-13 12:00:00", beam=beam, exams={})
    if a is not None:
        out["exams"]["muavic"] = ex(a)
    out["exams"]["owner_silent"] = ex(owner or [5] * 50)
    return out


class Exams(Tmp):
    def setUp(self):
        super().setUp()
        self.patch(exams, "LEDGER_MD", self.tmp / "checkpoints.md")
        self.patch(exams, "LEDGER_JSONL", self.tmp / "checkpoints.jsonl")

    def record(self, res, **kw):
        p = self.tmp / f"{res['name']}.json"
        p.write_text(json.dumps(res))
        with contextlib.redirect_stdout(io.StringIO()):
            return exams.cmd_record(argparse.Namespace(result=str(p), label=None, stage=kw.get("stage"),
                                                       clip_hours=kw.get("hours"), ckpt_cost=kw.get("cost"),
                                                       stage_cost=kw.get("stage_cost")))

    def test_bootstrap(self):
        a = {f"c{i}": (8, 10) for i in range(100)}
        self.assertEqual(exams.bootstrap(a, a)["significant"], False)
        b = exams.bootstrap(a, {f"c{i}": (7, 10) for i in range(100)})
        self.assertEqual((b["gain"], b["significant"]), (10.0, True))
        one = exams.bootstrap(a, dict(a, c0=(6, 10)))
        self.assertEqual((one["gain"], one["significant"]), (0.2, False))
        self.assertIsNone(exams.bootstrap(a, {"x": (1, 10)}))

    def test_window_rule_continue_then_stop(self):
        self.assertEqual(self.record(exam_result("start", [8] * 200))["verdict"], "baseline")
        d = self.record(exam_result("s1", [7] * 200, owner=[4] * 50), stage=1, cost=0.31, stage_cost=2.5)
        self.assertEqual((d["verdict"], d["sig_a"], d["flags"]), ("continue", True, []))
        flat = exam_result("s2", [7] * 199 + [6], owner=[4] * 50)  # +0.05 points: noise
        d = self.record(flat)
        self.assertEqual((d["verdict"], d["sig_a"]), ("continue", False))  # the window from start is still 10 points
        d = self.record(exam_result("s3", [7] * 200, owner=[4] * 50))
        self.assertEqual(d["verdict"], "continue")  # window start -> s3, 10 points
        d = self.record(exam_result("s4", [7] * 200, owner=[4] * 50))
        self.assertEqual((d["verdict"], d["window_a"]), ("stop collecting", 0.0))  # s2, s3, s4 without a sig gain
        md = exams.LEDGER_MD.read_text()
        self.assertEqual(md.count("\n| 2026-10-13"), 5)
        self.assertIn("| s1 | 1 | — | 70.0 | 40.0 | — | — | +10.0 [+10.0, +10.0] sig | 10.0 | +10.0 [+10.0, +10.0] sig | "
                      "$0.31 | $2.50 | continue |", md)

    def test_personal_flag(self):
        self.record(exam_result("start", [8] * 200))
        d = self.record(exam_result("s1", [7] * 200))  # owner unchanged
        self.assertEqual(d["flags"], ["personal fine-tune needed: (a) improves, the owner's exam (b) does not"])

    def test_one_noisy_step_is_not_a_stop(self):
        self.record(exam_result("start", [8] * 200))
        self.assertEqual(self.record(exam_result("s1", [8] * 199 + [7]))["verdict"], "continue (no clear gain yet)")
        self.assertEqual(self.record(exam_result("s2", [8] * 199 + [7]))["verdict"], "continue (no clear gain yet)")
        self.assertEqual(self.record(exam_result("s3", [8] * 200))["verdict"], "stop collecting")

    def test_beam_must_match(self):
        self.record(exam_result("start", [8] * 20))
        with self.assertRaises(SystemExit):
            self.record(exam_result("s1", [7] * 20, beam=20))

    def test_owner_wer_pools_silent_and_voiced(self):
        ex = {"owner_silent": dict(errors=50, words=100), "owner_voiced": dict(errors=80, words=400)}
        self.assertEqual(exams.owner_wer(ex), 26.0)

    def test_frozen_exam_is_immutable(self):
        src = self.tmp / "src"
        src.mkdir()
        items = []
        for i in range(3):
            (src / f"c{i}.mp4").write_bytes(bytes([i]) * 100)
            items.append(dict(id=f"c{i}", src=src / f"c{i}.mp4", text="раз", speaker="s"))
        root = self.tmp / "exams"
        with contextlib.redirect_stdout(io.StringIO()):
            exams.write_exam("muavic", items, "test", root)
            exams.cmd_freeze(argparse.Namespace(exams=str(root), only="muavic"))  # never rebuilt
        self.assertEqual(exams.load_exam(root / "muavic")["n"], 3)
        (root / "muavic" / "c1.mp4").write_bytes(b"changed")
        with self.assertRaises(SystemExit):
            exams.load_exam(root / "muavic")

    def test_heldout_exam_follows_train_e2e_split(self):
        tr, dv = channels_by_split(3, 3)
        pub = self.tmp / "pub"
        pub.mkdir()
        lines = []
        for ch in tr + dv:
            for v in range(2):
                vid = f"{ch[1:]}v{v}"
                lines.append(f"{vid}\t{ch}")
                for k in range(8):
                    stem = f"yt_{vid}__00000_{k:06d}"
                    (pub / f"{stem}.json").write_text(json.dumps(dict(video_id="yt_" + vid, frames=100)))
                    (pub / f"{stem}.txt").write_text(f"фраза {ch} {v} {k}\n")
                    (pub / f"{stem}.mp4").write_bytes(b"v")
        self.patch(exams, "CHANNELS", self.tmp / "vc.tsv")
        exams.CHANNELS.write_text("\n".join(lines) + "\n")
        a = argparse.Namespace(public=str(pub), dev_pct=3, min_channels=3, min_clips=10, per_channel=5)
        items, why = exams.heldout_items(a)
        self.assertEqual({i["speaker"] for i in items}, set(dv))
        self.assertEqual(len(items), 15)
        a.min_channels = 4
        self.assertIsNone(exams.heldout_items(a)[0])


class FakePod:
    """A trainer pod that answers from a local folder; the pod-side script is simulated."""
    instances = []

    def __init__(self, name, remote, results, gpu="NVIDIA GeForce RTX 4090", fail=None):
        self.name, self.remote, self.results, self.gpu, self.fail = name, remote, results, gpu, fail
        self.calls, self.deleted, self.kept = [], False, None
        FakePod.instances.append(self)

    def attach(self, hours):
        if self.fail:
            raise RuntimeError(self.fail)
        self.calls.append(("attach", hours))
        return self.gpu

    def cost(self):
        return 0.25

    def keep(self, minutes):
        self.kept = minutes

    def ssh(self, cmd, check=True):
        self.calls.append(("ssh", cmd))
        r = self.remote
        if "train_stage.sh" in cmd:
            args = cmd.split("train_stage.sh ")[1].split()
            run, baseline = args[1], args[5] == "1"
            for d in ("results/exams", f"checkpoints/{run}", "logs"):
                (r / d).mkdir(parents=True, exist_ok=True)
            (r / "checkpoints" / run / "best.pt").write_bytes(b"ck")
            (r / "logs" / f"{run}.log").write_text("step 10/50 loss 1.2 9.40 s/step\nstep 20/50 loss 1.1 9.10 s/step\n")
            (r / "stage.log").write_text("done\n")
            if baseline:
                (r / "results" / "exams" / f"{run}_start.json").write_text(json.dumps(self.results["start"]))
            (r / "results" / "exams" / f"{run}.json").write_text(json.dumps(self.results[run]))
            (r / "STAGE_DONE").touch()
        if "rm -f /root/lr/STAGE_DONE" in cmd:
            (r / "STAGE_DONE").unlink(missing_ok=True)
        out = "STAGE_DONE\n" if "ls STAGE_DONE" in cmd and (r / "STAGE_DONE").exists() else ""
        return argparse.Namespace(stdout=out, returncode=0)

    def push(self, src, dst, files_from=None, only=None):
        self.calls.append(("push", str(src), dst, str(files_from) if files_from else None))

    def pull(self, src, dst):
        s = self.remote / src.replace("/root/lr/", "")
        Path(dst).mkdir(parents=True, exist_ok=True)
        if s.is_dir():
            shutil.copytree(s, dst, dirs_exist_ok=True)
        elif s.exists():
            shutil.copy(s, dst)

    def delete(self):
        self.deleted = True


class Loop(Tmp):
    def setUp(self):
        super().setUp()
        t = self.tmp
        for name, val in dict(STATE=t / "stage.json", QUALITY=t / "cq.json", HOLD_FILE=t / "HOLD",
                              FEED_STOP=t / "FEED_STOP", STAGES=t / "stages", PUBLIC=t / "pub", EXAMS_DIR=t / "exams",
                              RUNS=t / "runs", STATE_DIR=t / "state").items():
            self.patch(cl, name, val)
        self.patch(exams, "LEDGER_MD", t / "checkpoints.md")
        self.patch(exams, "LEDGER_JSONL", t / "checkpoints.jsonl")
        self.patch(exams, "CHANNELS", t / "vc.tsv")
        for d in ("pub", "exams", "state"):
            (t / d).mkdir()
        self.hours(100.0)
        self.t0 = time.time() - 1000
        cl.save(dict(hours0=100.0, stage_hours=50, budget_usd=3.0, best=None, stages={}, hold=None,
                     created_ts=self.t0))
        self.trained, self.stops = [], []

    def hours(self, h):
        cl.QUALITY.write_text(json.dumps({"total_clip_hours": h}))

    def tick(self, rates=(0.0, 0.0), dt=0.0):
        st = cl.load()
        st["last_tick"] = time.time() - dt
        cl.save(st)
        return cl.tick(rates, self.trained.append, lambda: self.stops.append(1))

    def test_budget_hold_and_release(self):
        line, alerts, hold = self.tick((1.0, 0.0), dt=3600)
        self.assertFalse(hold)
        self.assertIn("$1.00 of $3", line)
        self.tick((1.0, 0.0), dt=3600)
        line, alerts, hold = self.tick((1.5, 0.0), dt=3600)  # $3.50 > $3
        self.assertTrue(hold)
        self.assertEqual(len(self.stops), 1)
        self.assertTrue(cl.HOLD_FILE.exists())
        self.tick()
        self.assertEqual(len(self.stops), 1)  # not stopped again while the same hold stands
        cl.FEED_STOP.touch()
        with contextlib.redirect_stdout(io.StringIO()):
            cl.cmd_budget(argparse.Namespace(stage=1, add_usd=2.0, note="yield ok, slower than planned"))
        self.assertFalse(cl.HOLD_FILE.exists() or cl.FEED_STOP.exists())
        self.assertFalse(self.tick()[2])

    def test_checkpoint_cost_goes_to_its_stage(self):
        self.hours(160)  # stage 2 collecting, stage 1 checkpoint starts
        self.tick()
        self.assertEqual(self.trained, [1])
        self.tick((2.0, 0.6), dt=1800)
        st = cl.load()
        self.assertEqual((st["stages"]["1"]["spent"], st["stages"]["2"]["spent"]), (0.3, 1.0))

    def test_stage_end_trains_once_retries_once_and_waits_for_decisions(self):
        self.hours(160)
        self.tick()
        self.tick()
        self.assertEqual(self.trained, [1])
        st = cl.load()
        st["stages"]["1"]["train"].update(ended="x", error="no GPU")
        cl.save(st)
        self.tick()
        self.assertEqual(self.trained, [1, 1])  # one retry
        st = cl.load()
        st["stages"]["1"]["train"].update(ended="x", error="no GPU again")
        cl.save(st)
        self.tick()
        self.assertEqual(self.trained, [1, 1])
        self.hours(205)  # stage 3 running, stage 2 complete, stage 1 undecided -> hold
        line, alerts, hold = self.tick()
        self.assertEqual(self.trained, [1, 1, 2])
        self.assertTrue(hold)
        self.assertIn("stage 1 has no decision", line)
        with contextlib.redirect_stdout(io.StringIO()):
            cl.cmd_decide(argparse.Namespace(stage=1, decision="continue", note="skip the failed checkpoint"))
        self.assertFalse(self.tick()[2])
        with contextlib.redirect_stdout(io.StringIO()):
            cl.cmd_decide(argparse.Namespace(stage=2, decision="stop", note="flat"))
        line, alerts, hold = self.tick()
        self.assertTrue(hold)
        self.assertIn("stop collecting", line)

    def test_stop_verdict_holds_until_decided(self):
        st = cl.load()
        cl.stage(st, 1)["verdict"] = {"verdict": "stop collecting"}
        cl.stage(st, 1)["train"] = {"ended": "x"}
        cl.save(st)
        self.hours(160)
        line, alerts, hold = self.tick()
        self.assertTrue(hold)
        self.assertIn("exams say stop collecting", line)
        with contextlib.redirect_stdout(io.StringIO()):
            cl.cmd_decide(argparse.Namespace(stage=1, decision="continue", note="owner wants more"))
        self.assertFalse(self.tick()[2])

    def test_balance_keeps_r1(self):
        clips = [(f"a{i}", "A", i) for i in range(1000)] + [(f"b{i}", "B", i) for i in range(50)] + \
                [(f"{c}{i}", c, i) for c in "CDEFG" for i in range(100)]
        got = cl.balance(clips, 600)
        per = {}
        for s in got:
            per[s[0].upper()] = per.get(s[0].upper(), 0) + 1
        self.assertLessEqual(len(got), 600)
        self.assertEqual(per["B"], 50)
        self.assertLessEqual(max(per.values()) / len(got), 0.25)
        self.assertIn("a999", got)  # newest first
        self.assertEqual(cl.balance([(f"a{i}", "A", i) for i in range(100)] + [("b0", "B", 0)], 50), [])
        four = cl.balance([(f"{c}{i}", c, i) for c in "ABCD" for i in range(100 if c == "A" else 10)], 1000)
        self.assertEqual(len(four), 40)

    def make_public(self):
        tr, dv = channels_by_split(6, 2)
        lines = []
        for ch in tr + dv:
            vid = ch[1:]
            lines.append(f"{vid}\t{ch}")
            for k in range(60):
                stem = f"yt_{vid}__00000_{k:06d}"
                f = cl.PUBLIC / f"{stem}.json"
                f.write_text(json.dumps(dict(video_id="yt_" + vid, frames=100)))
                if k < 40:  # collected before the loop started
                    os.utime(f, (self.t0 - 3600, self.t0 - 3600))
        exams.CHANNELS.write_text("\n".join(lines) + "\n")
        return tr, dv

    def run_train(self, k, results, **kw):
        remote = self.tmp / f"remote{k}"
        remote.mkdir()
        with contextlib.redirect_stdout(io.StringIO()) as out:
            d = cl.train(k, execute=True, pod_factory=lambda name: FakePod(name, remote, results, **kw), poll=0)
        return d, FakePod.instances[-1], out.getvalue()

    def test_incremental_checkpoints_with_fake_pod(self):
        tr, dv = self.make_public()
        self.patch(cl, "TRAIN_MINUTES", 4)  # the selection plans for the fastest card: 30 steps, 960 clips, more than the pool
        self.hours(160)
        res = {"start": exam_result("start", [8] * 200), "stage1": exam_result("stage1", [7] * 200, owner=[4] * 50),
               "stage2": exam_result("stage2", [7] * 200, owner=[4] * 50)}
        d, pod, out = self.run_train(1, res)
        self.assertEqual(d["verdict"], "continue")
        self.assertTrue(pod.deleted)  # the collection speed is unknown: the next checkpoint is not near
        self.assertIn("120 new, 240 replay", out)  # 6 train channels x 20 new clips, R1 caps nothing here
        lst = (cl.STAGES / "1" / "clips.txt").read_text().split()
        self.assertEqual({x.split("__")[0][3:] for x in lst}, {c[1:] for c in tr + dv})
        sh = [c[1] for c in pod.calls if c[0] == "ssh" and "train_stage.sh" in c[1]][0]
        self.assertIn(" stage1 base 24 4 1 ", sh)  # from the base model, 4 min at the 4090 guess, start examined
        self.assertIn(" 2 lists/stage1.txt", sh)  # chunk batch 2 on a 24 GB card
        st = cl.load()
        self.assertEqual(st["sec_per_step"], {"NVIDIA GeForce RTX 4090": 9.1})
        self.assertEqual(st["stages"]["1"]["decision"], "continue")  # recorded by the rule
        self.assertEqual(st["stages"]["1"]["train"]["cost"], 0.25)
        best1 = st["best"]
        self.assertTrue(best1.endswith("runs/tc/checkpoints/stage1/best.pt"))

        st["clip_hph"] = 100.0  # 40 h left of stage 2 at 100 h/h: due in 24 min -> keep the pod
        cl.save(st)
        self.hours(210)
        d, pod, out = self.run_train(2, res)
        self.assertFalse(pod.deleted)
        self.assertEqual(pod.kept, cl.KEEP_GAP_MIN + 20)
        self.assertIn(("push", str(cl.ROOT / best1) if not Path(best1).is_absolute() else best1,
                       "/root/lr/checkpoints/init/stage2.pt", None), pod.calls)
        sh = [c[1] for c in pod.calls if c[0] == "ssh" and "train_stage.sh" in c[1]][0]
        self.assertIn(" stage2 checkpoints/init/stage2.pt ", sh)
        self.assertIn(" 0 ", sh.split("stage2.pt")[1][:12])  # the start is examined only once
        self.assertEqual(d["verdict"], "continue")  # window start -> stage2 is 10 points
        self.assertFalse(d["sig_a"])
        self.assertIn("0 new", out)  # nothing arrived since stage 1's selection
        rows = [json.loads(x) for x in exams.LEDGER_JSONL.read_text().splitlines()]
        self.assertEqual([r["name"] for r in rows], ["start (base)", "stage1", "stage2"])
        self.assertEqual(rows[2]["boot"]["muavic"]["gain"], 0.0)

    def test_failed_pod_is_deleted_and_recorded(self):
        self.make_public()
        self.hours(160)
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit):
            self.run_train(1, {}, fail="no GPU offer")
        self.assertTrue(FakePod.instances[-1].deleted)
        self.assertIn("no GPU offer", cl.load()["stages"]["1"]["train"]["error"])


class Supervisor(Tmp):
    def setUp(self):
        super().setUp()
        import supervisor
        self.sv, self.started = supervisor, []
        self.patch(supervisor, "STATUS", self.tmp / "status.txt")
        self.patch(supervisor, "FEED_STOP", self.tmp / "MAC_FEEDER_STOP")
        self.patch(supervisor, "start_mac", lambda cmd, log: self.started.append(cmd))
        self.patch(supervisor, "mac_procs", lambda: "")
        self.patch(supervisor, "live_pods", lambda: {"p1": {"deadline": time.time() + 3600}})
        self.patch(supervisor, "log", lambda msg: None)

    def test_hold_restarts_nothing(self):
        self.patch(self.sv, "loop_step", lambda state, alerts: ("loop: stage 1, HOLD: budget", True))
        self.sv.tick({})
        self.assertEqual(self.started, [])
        self.assertIn("HOLD: budget", self.sv.STATUS.read_text())

    def test_stop_collection(self):
        self.sv.stop_collection()
        self.assertTrue(self.sv.FEED_STOP.exists())
        self.assertEqual(self.started, ["harvester/harvest.py --name p1 stop"])


if __name__ == "__main__":
    unittest.main()
