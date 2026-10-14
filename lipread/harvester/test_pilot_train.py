"""Offline tests of the pilot's training step: python3 -m unittest harvester/test_pilot_train.py (from lipread).
No pod, no model: stub collector clips in temp folders and a fake trainer pod."""
import argparse
import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from collections import Counter
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(ROOT))
import checkpoint_loop as cl  # noqa: E402
import exams  # noqa: E402
import pilot_train as pt  # noqa: E402
import preflight  # noqa: E402
import split  # noqa: E402

SINCE = time.time() - 3600
SIZES = [400, 300, 250, 200, 180, 60, 60, 60, 60, 60]  # pilot train channels; the first five are NARROW's


def channels(n, want, prefix):
    out, i = [], 0
    while len(out) < n:
        ch = f"@{prefix}{i}"
        if split.split_for(f"ch:{ch}", pt.DEV_PCT) == want:
            out.append(ch)
        i += 1
    return out


class Data(unittest.TestCase):
    """Pilot clips: 10 train channels of SIZES clips, 3 dev channels (one in the frozen held-out exam); two older
    channels from before the start; plus clips every arm must drop."""

    def setUp(self):
        self.tmp = t = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, t, ignore_errors=True)
        ps = contextlib.ExitStack()
        self.addCleanup(ps.close)
        for obj, name, val in [(cl, "PUBLIC", t / "pub"), (cl, "EXAMS_DIR", t / "exams"),
                               (exams, "CHANNELS", t / "vc.tsv"),
                               (pt, "LISTS", t / "pilot"), (pt, "START_FILE", t / "pilot_start.txt"),
                               (pt, "CLIPS", t / "clips"), (pt, "MUAVIC_SELECTION", t / "selection.jsonl"),
                               (pt, "OUT", t / "runs" / "tp"), (pt, "REPORT", t / "pilot.md"),
                               (pt, "INIT", t / "init.pt"), (pt, "MIN_HOURS", 0.5), (preflight, "HERE", t),
                               (preflight, "LOCK", t / "OPERATOR.lock")]:
            ps.enter_context(mock.patch.object(obj, name, val))
        ps.enter_context(mock.patch.dict(os.environ, LIPREAD_OPERATOR="test"))
        for d in ("pub", "exams", "clips"):
            (t / d).mkdir()
        (t / "init.pt").write_bytes(b"ck")
        (t / "clips" / "001.txt").write_text("секретная фраза владельца\n")
        self.map = []
        self.train_ch = channels(len(SIZES), "train", "p")
        self.dev_ch = channels(3, "dev", "d")
        self.old_ch = channels(2, "train", "old")
        for ch, n in zip(self.train_ch, SIZES):
            # the large channels talk in longer clips: NARROW must pick its lengths, not take them as they come
            self.add(ch, n, lo=60 if n > 100 else 20)
        for ch in self.dev_ch:
            self.add(ch, 30)
        for ch in self.old_ch:
            self.add(ch, 500, new=False)
        ch = self.train_ch[5]
        self.bad = [self.clip("sec", ch, "s00012500_000001", video="muv1"),  # MuAViC test video, section clip name
                    self.clip("long", ch, 0, frames=250),  # > 8 s
                    self.clip("nomp4", ch, 0, mp4=False),
                    self.clip("owner", ch, 0, text="Секретная фраза, владельца"),  # R10
                    self.clip("muv1__s00051500", ch, 0),  # a scouted section of it: its video id has __s<ms>
                    self.clip(f"{ch[1:]}v0", ch, 99)]  # frozen in the MuAViC exam below
        self.low = self.clip("lowres", ch, 0, height=360)  # R3
        (t / "selection.jsonl").write_text(json.dumps(dict(video_id="muv1", split="test")) + "\n"
                                           + json.dumps(dict(video_id=f"{ch[1:]}v1", split="train")) + "\n")
        exams.CHANNELS.write_text("".join(f"{v}\t{c}\n" for v, c in sorted(set(self.map))))
        self.exam_ids = [f"yt_{self.dev_ch[0][1:]}v0__{k:06d}" for k in range(10)]
        self.manifest("heldout", [(i, self.dev_ch[0]) for i in self.exam_ids])
        self.manifest("muavic", [(self.bad[-1], "muavic:x")])

    def clip(self, vid, ch, k, new=True, frames=120, mp4=True, text=None, video=None, height=720):
        stem = f"yt_{vid}__{k:06d}" if isinstance(k, int) else f"yt_{vid}__{k}"
        p = cl.PUBLIC / stem
        p.with_suffix(".txt").write_text((text or f"фраза {stem}") + "\n")
        if mp4:
            p.with_suffix(".mp4").write_bytes(b"v")
        js = p.with_suffix(".json")
        js.write_text(json.dumps(dict(video_id="yt_" + (video or vid), frames=frames, src_height=height)))
        mt = SINCE + 60 if new else SINCE - 86400
        os.utime(js, (mt, mt))
        self.map.append((video or vid, ch))
        return stem

    def add(self, ch, n, new=True, lo=20):
        for k in range(n):
            self.clip(f"{ch[1:]}v{k // 20}", ch, k, new, frames=lo + (k * 37) % (200 - lo))

    def manifest(self, name, items):
        d = cl.EXAMS_DIR / name
        d.mkdir()
        (d / "manifest.json").write_text(json.dumps(dict(items=[dict(id=i, speaker=s) for i, s in items])))

    def plan(self, since=SINCE, **kw):
        with contextlib.redirect_stdout(io.StringIO()) as out:
            p = pt.plan(since, **kw)
        return p, out.getvalue()

    def read(self, name):
        return [x.rsplit(".", 1)[0] for x in (pt.LISTS / f"{name}.txt").read_text().split()[::3]]

    def frames(self, stem):
        return json.loads((cl.PUBLIC / f"{stem}.json").read_text())["frames"]


def channel_of(stem, mapping):
    return mapping[json.loads((cl.PUBLIC / f"{stem}.json").read_text())["video_id"][3:]]


class Selection(Data):
    def test_arms(self):
        p, out = self.plan()
        chans = dict(self.map)
        new, narrow = self.read("new"), self.read("narrow")
        dev = [s for s in new if channel_of(s, chans) in self.dev_ch]
        self.assertEqual(len(dev), 80)  # 2 x 30 outside the exam + the exam channel's 20 non-exam clips
        self.assertEqual(dev, [s for s in narrow if s in dev])  # the same dev for every run
        tr_new, tr_nar = [s for s in new if s not in dev], [s for s in narrow if s not in dev]
        self.assertFalse(set(dev) & (set(tr_new) | set(tr_nar)))
        cnt_new = Counter(channel_of(s, chans) for s in tr_new)
        cnt_nar = Counter(channel_of(s, chans) for s in tr_nar)
        self.assertEqual(len(cnt_new), 10)
        self.assertLessEqual(max(cnt_new.values()) / len(tr_new), 0.24)
        self.assertEqual(set(cnt_nar), set(self.train_ch[:5]))  # the five channels with the most clips
        self.assertTrue(all(0.17 < k / len(tr_nar) < 0.23 for k in cnt_nar.values()), cnt_nar)
        self.assertLessEqual(len(tr_new), int(5 * 180 * 0.9))  # NARROW's 5th channel bounds both arms
        f_new, f_nar = [self.frames(s) for s in tr_new], [self.frames(s) for s in tr_nar]
        self.assertAlmostEqual(sum(f_nar) / sum(f_new), 1.0, delta=0.01)  # the same hours
        self.assertAlmostEqual(sorted(f_nar)[len(f_nar) // 4] / sorted(f_new)[len(f_new) // 4], 1.0, delta=0.15)
        self.assertGreater(len(set(tr_new) & set(tr_nar)), 0)  # overlap is allowed
        full = self.read("full")
        tr_full = [s for s in full if s not in dev]
        self.assertEqual(dev, [s for s in full if s in dev])
        cnt_full = Counter(channel_of(s, chans) for s in tr_full)
        self.assertEqual(set(cnt_full), set(self.train_ch))  # every pilot channel, R1-capped
        self.assertLessEqual(max(cnt_full.values()) / len(tr_full), 0.24)
        self.assertGreater(len(tr_full), len(tr_new))
        self.assertEqual(p["full_clips"], len(tr_full))
        everything = set(new) | set(narrow) | set(full)
        self.assertFalse(everything & (set(self.exam_ids) | set(self.bad) | {self.low}))
        self.assertFalse(any(channel_of(s, chans) in self.old_ch for s in everything))  # pilot clips only
        pool = self.read("pool")
        self.assertEqual(sorted(pool), sorted(everything))
        self.assertEqual(p["low_source"], 1)
        self.assertEqual(p["new_clips"], len(tr_new))
        self.assertIn("worst case 5.06 h = $4.55 (self-destruct), $5.00 if that fails too", out)
        self.assertNotIn("WARNING", out)

    def test_dev_split_never_trains(self):
        self.plan()
        chans = dict(self.map)
        for name in ("new", "narrow"):
            for s in self.read(name):
                ch = channel_of(s, chans)
                self.assertEqual(split.split_for(f"ch:{ch}", pt.DEV_PCT), "dev" if ch in self.dev_ch else "train")

    def test_max_clips(self):
        p, _ = self.plan(max_clips=500)
        self.assertTrue(480 < p["sets"]["new"]["clips"] <= 500)
        self.assertAlmostEqual(p["sets"]["narrow"]["hours"] / p["sets"]["new"]["hours"], 1.0, delta=0.05)

    def test_start_file(self):
        pt.START_FILE.write_text(f"{SINCE}  # pilot start\n")
        self.assertEqual(pt.pilot_start(), SINCE)
        pt.START_FILE.write_text("2026-10-14 10:00\n")
        self.assertEqual(pt.pilot_start(), time.mktime(time.strptime("2026-10-14 10:00", "%Y-%m-%d %H:%M")))
        pt.START_FILE.unlink()
        with self.assertRaisesRegex(SystemExit, "no pilot start"):
            pt.pilot_start()

    def test_refusals(self):
        with self.assertRaisesRegex(SystemExit, r"0 channels of train clips"):
            self.plan(since=time.time() + 60)
        with mock.patch.object(pt, "MIN_HOURS", 1.5), \
                self.assertRaisesRegex(SystemExit, r"NARROW's 5th channel @p\d+ has 180 clips, so both arms are cut"):
            self.plan()
        with mock.patch.object(pt, "HOURS_TOL", 0.0001), self.assertRaisesRegex(SystemExit, r"NARROW from .* lack"):
            self.plan()
        for ch in self.train_ch[4:]:  # 4 pilot channels left
            for js in cl.PUBLIC.glob(f"yt_{ch[1:]}v*.json"):
                os.utime(js, (SINCE - 10, SINCE - 10))
        with self.assertRaisesRegex(SystemExit, r"\[pilot\] 4 channels.*NEW needs >= 5"):
            self.plan()

    def test_warns_without_muavic_exam(self):
        shutil.rmtree(cl.EXAMS_DIR / "muavic")
        _, out = self.plan()
        self.assertIn("WARNING: the MuAViC exam is not frozen", out)


class Budget(unittest.TestCase):
    def test_budget(self):
        # 4 h left, 10 s/step, a run's overhead 4 min, an exam run 20 min: (14400 - 3600 - 600) / 3 = 3400 s per run
        # minus 240 + 3 x 120 s -> 280 steps by time; 3 passes over 4000 clips would be 375
        self.assertEqual(pt.budget(10, 240, 1200, 14400, 4000), (280, 70, 28, 72))
        self.assertEqual(pt.budget(10, 240, 1200, 14400, 2000), (187, 47, 18, 53))  # 3 passes over 2000 clips
        with self.assertRaisesRegex(SystemExit, "at least 100 needed"):
            pt.budget(10, 240, 1200, 5000, 4000)

    def test_plan_guess_on_a_3090(self):
        # a 3090 at 14 s/step, NEW large enough that time binds: steps fall as the exam runs grow
        with mock.patch.object(pt, "EXAM_MIN", 15):
            s15 = pt.estimate(20000, 20000, 14.0)
        with mock.patch.object(pt, "EXAM_MIN", 25):
            s25 = pt.estimate(20000, 20000, 14.0)
        self.assertGreater(s15[0], s25[0])
        self.assertLessEqual(max(s15[2], s25[2]), pt.pod_hours(pt.cl.MAX_PRICE))
        self.assertLessEqual(max(s15[3], s25[3]) + 0.5 * 0.9, 5.0)

    def test_pod_script_arithmetic(self):
        """The lines of pilot_train.sh that turn the smoke run into the runs' steps, on a fake smoke log."""
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        lg = tmp / "pilot_smoke.log"
        # 10 steps in 30 s (loader start-up), steps 11-30 at 10.05 s each: 231 s for 30 steps
        lg.write_text("step 0 dev loss 2.0\nstep 10/30 loss 1.9 3.00 s/step\nstep 20/30 loss 1.8 6.53 s/step\n"
                      "step 30/30 loss 1.7 7.70 s/step\nstep 30 dev loss 1.9\n")
        sh = HERE / "pod" / "pilot_train.sh"
        cmd = [x for x in sh.read_text().split("\n\n") if "pilot_train.py steps" in x][0]
        script = (f"set -euo pipefail\ncd {ROOT}\nARMS_S=16000 T0=$(date +%s) SMOKE_S=470 EXAM_S=1200 N_NEW=4000\n"
                  + cmd.replace("logs/pilot_smoke.log", str(lg)) + '\necho "$STEPS $EVAL $WARMUP $GUARD"\n')
        r = subprocess.run(["bash", "-c", script], capture_output=True, text=True, check=True)
        # smoke 470 s - 231 s of steps = 239 s overhead; 16000 s left -> 331 steps by time, 375 by 3 passes
        self.assertEqual(r.stdout.split(), ["331", "83", "33", "83"])
        self.assertIn("10.05 s/step, run overhead 239 s", r.stderr)
        # FULL: what is left of the life, at most FULL_MIN; skipped (0 0 0 0) when fewer than MIN_FULL_STEPS fit
        block = [x for x in sh.read_text().split("\n\n") if "steps --full" in x][0]
        block = block[:block.index("read -r FSTEPS")] + 'read -r FSTEPS FEVAL FWARMUP FGUARD <<< "$F"\n'
        for life, want in ((16000, ["298", "75", "29", "76"]), (2500, ["0", "0", "0", "0"])):
            script = (f"set -euo pipefail\ncd {ROOT}\nLIFE_S={life} T0=$(date +%s) SMOKE_S=470 EXAM_S=1200 "
                      "N_FULL=4000\n"
                      + block.replace("logs/pilot_smoke.log", str(lg)) + '\necho "$FSTEPS $FEVAL $FWARMUP $FGUARD"\n')
            r = subprocess.run(["bash", "-c", script], capture_output=True, text=True, check=True)
            # 60 min cap: (3600 - 239 - 3 x 119.5) / 10.05 = 298 steps
            self.assertEqual(r.stdout.split(), want)
        self.assertIn("FULL skipped: 10 steps per run fit", r.stderr)


def result(name, err, speakers=16, clips=20, other=None):
    """err(speaker index, clip index) -> errors of 10 words on MuAViC; other: errors per clip on owner_silent."""
    items = [[f"m{s}_{c}", f"muavic:s{s}", err(s, c), 10, "h"] for s in range(speakers) for c in range(clips)]
    ex = {"muavic": dict(wer=round(100 * sum(i[2] for i in items) / (10 * len(items)), 2), complete=True, items=items)}
    if other is not None:
        it = [[f"o{c}", "owner", other, 10, "h"] for c in range(50)]
        ex["owner_silent"] = dict(wer=10.0 * other, complete=True, items=it)
    return dict(name=name, ckpt=name, time="2026-10-14 12:00:00", beam=5, exams=ex)


def train_log(steps, done=None, limited=False, best=None):
    done = steps if done is None else done
    t = "step 0 dev loss 2.0\n" + "".join(f"step {s}/{steps} loss 1.0 9.9 s/step\n" for s in range(10, done + 1, 10))
    t += "".join(f"step {s} dev loss 1.5{' best' if s == best else ''}\n" for s in range(100, done + 1, 100))
    if done % 100:
        t += f"step {done} dev loss 1.5\n"
    return t + ("time limit\n" if limited else "") + "done\n"


LOGS = {a: pt.run_log(train_log(400, best=200)) for a in pt.ARMS}


class Verdict(unittest.TestCase):
    def test_speaker_bootstrap(self):
        base = exams.per_clip_speaker(result("a", lambda s, c: 5), "muavic")
        b = exams.speaker_bootstrap(base, base)
        self.assertEqual((b["gain"], b["significant"], b["speakers"], b["clips"]), (0.0, False, 16, 320))
        b = exams.speaker_bootstrap(base, exams.per_clip_speaker(result("b", lambda s, c: 4), "muavic"))
        self.assertEqual((b["gain"], b["lo"], b["hi"], b["significant"]), (10.0, 10.0, 10.0, True))
        self.assertEqual((b["prev_wer"], b["cur_wer"]), (50.0, 40.0))
        # one speaker of 16 improves a lot: the per-clip bootstrap calls it real, the speaker-level one does not
        one = exams.per_clip_speaker(result("c", lambda s, c: 0 if s == 0 else 5), "muavic")
        self.assertTrue(exams.bootstrap({k: v[1:] for k, v in base.items()},
                                        {k: v[1:] for k, v in one.items()})["significant"])
        b = exams.speaker_bootstrap(base, one)
        self.assertEqual((b["gain"], b["lo"], b["significant"]), (3.12, 0.0, False))
        self.assertIsNone(exams.speaker_bootstrap(base, {"x": ("s", 1, 10)}))

    def v(self, logs=LOGS, **errs):
        e = dict(init=lambda s, c: 7, new=lambda s, c: 4, narrow0=lambda s, c: 6, narrow1=lambda s, c: 6)
        e.update(errs)
        r = {k: result(k, f) for k, f in e.items()}
        return pt.verdict({(a, b): pt.compare(r[b], r[a]) for a, b in pt.PAIRS}, logs)

    def test_seed_gap_rule(self):
        d = self.v()
        self.assertEqual((d["verdict"], d["gap"], d["seed_gap"]), ("diversity helps", 20.0, 0.0))
        d = self.v(narrow0=lambda s, c: 5, narrow1=lambda s, c: 6 + c % 2)  # new beats both, seeds differ by 15
        self.assertEqual((d["verdict"], d["gap"], d["seed_gap"]), ("no evidence", 10.0, 15.0))
        self.assertIn("no more than the seeds differ", d["why"])
        d = self.v(narrow1=lambda s, c: 4 + (s == 0))  # vs narrow1 only one speaker better: not significant
        self.assertEqual(d["verdict"], "no evidence")
        self.assertIn("95% interval", d["why"])
        d = self.v(new=lambda s, c: 6)
        self.assertEqual(d["verdict"], "no evidence")

    def test_runs_must_match(self):
        limited = dict(LOGS, narrow1=pt.run_log(train_log(400, done=370, limited=True)))
        d = self.v(limited)
        self.assertEqual(d["verdict"], "no verdict")
        self.assertIn("narrow1 stopped on its time guard at step 370", d["why"])
        other = dict(LOGS, new=pt.run_log(train_log(420)))
        self.assertIn("differ in steps: new 420, narrow0 400", self.v(other)["why"])
        self.assertIn("no training log of narrow0", self.v(dict(LOGS, narrow0=None))["why"])
        self.assertEqual(pt.run_log(train_log(400, best=200)), (400, 400, False, 200))
        self.assertEqual(pt.run_log(train_log(400, done=370, limited=True)), (400, 370, True, None))


class FakePod:
    """A trainer pod that answers from a local folder; harvester/pod/pilot_train.sh is simulated."""
    instances = []

    def __init__(self, name, remote, results, gpu="NVIDIA GeForce RTX 4090", fail=None, pod_fails=False, mute=False,
                 rate=0.69, full="done"):
        self.name, self.remote, self.results, self.gpu = name, remote, results, gpu
        self.fail, self.pod_fails, self.mute, self.full = fail, pod_fails, mute, full
        self.calls, self.deleted, self.st, self.shortened = [], False, dict(rate=rate), None
        FakePod.instances.append(self)

    def rate(self):
        return self.st["rate"]

    def shorten(self, end):
        self.shortened = end

    def attach(self, hours):
        self.calls.append(("attach", hours))
        if self.fail:
            raise RuntimeError(self.fail)
        return self.gpu

    def cost(self):
        return 3.1

    def ssh(self, cmd, check=True):
        self.calls.append(("ssh", cmd))
        r = self.remote
        if "rm -f /root/lr/PILOT_DONE" in cmd:
            for m in ("PILOT_DONE", "PILOT_FAILED", "ARMS_DONE", "FULL_SKIPPED"):
                (r / m).unlink(missing_ok=True)
        if "pilot_train.sh" in cmd:
            for d in ("results/exams", "checkpoints/pilot_new", "logs"):
                (r / d).mkdir(parents=True, exist_ok=True)
            (r / "pilot.log").write_text("started\n")
            (r / "results" / "exams" / "pilot_init.json").write_text(json.dumps(self.results["init"]))
            if self.pod_fails or self.mute:
                if self.pod_fails:
                    (r / "PILOT_FAILED").touch()
                return argparse.Namespace(stdout="", returncode=0)
            (r / "checkpoints" / "pilot_new" / "last.pt").write_bytes(b"ck")
            for arm in pt.ARMS:
                (r / "logs" / f"pilot_{arm}.log").write_text(train_log(450, best=None if arm == "narrow1" else 300))
                (r / "results" / "exams" / f"pilot_{arm}.json").write_text(json.dumps(self.results[arm]))
            (r / "ARMS_DONE").touch()
            if self.full == "done":
                (r / "checkpoints" / "pilot_full").mkdir(parents=True, exist_ok=True)
                for f in pt.FULL_FILES:
                    (r / "checkpoints" / "pilot_full" / f).write_bytes(b"release")
                (r / "logs" / "pilot_full.log").write_text(train_log(200))
                (r / "results" / "exams" / "pilot_full.json").write_text(json.dumps(self.results["full"]))
            elif self.full == "skip":
                (r / "FULL_SKIPPED").touch()
            (r / ("PILOT_FAILED" if self.full == "fail" else "PILOT_DONE")).touch()
        if "ls PILOT_DONE" in cmd and self.mute:
            return argparse.Namespace(stdout="", returncode=255)
        out = "".join(f"{m}\n" for m in ("PILOT_DONE", "PILOT_FAILED", "ARMS_DONE", "FULL_SKIPPED")
                      if "ls PILOT_DONE" in cmd and (r / m).exists())
        return argparse.Namespace(stdout=out, returncode=0)

    def push(self, src, dst, files_from=None, only=None):
        self.calls.append(("push", str(src), dst, str(files_from) if files_from else None))

    def pull(self, src, dst):
        self.calls.append(("pull", src))
        s = self.remote / src.replace("/root/lr/", "")
        Path(dst).mkdir(parents=True, exist_ok=True)
        if s.is_dir():
            shutil.copytree(s, dst, dirs_exist_ok=True)
        elif s.exists():
            shutil.copy(s, dst)

    def delete(self):
        self.calls.append(("delete",))
        self.deleted = True


class Run(Data):
    def results(self):
        return dict(init=result("init", lambda s, c: 7, other=5), new=result("new", lambda s, c: 4, other=5),
                    narrow0=result("narrow0", lambda s, c: 6, other=5),
                    narrow1=result("narrow1", lambda s, c: 6, other=4), full=result("full", lambda s, c: 3, other=5))

    def go(self, poll=0, **kw):
        remote = self.tmp / "remote"
        remote.mkdir(exist_ok=True)
        with contextlib.redirect_stdout(io.StringIO()) as out:
            v = pt.run(SINCE, pod_factory=lambda name: FakePod(name, remote, self.results(), **kw), poll=poll)
        return v, out.getvalue()

    def test_run_with_fake_pod(self):
        FakePod.instances.clear()
        v, out = self.go()
        pod = FakePod.instances[-1]
        self.assertTrue(pod.deleted)
        self.assertEqual(pod.name, "tp")
        self.assertEqual(pod.calls[0], ("attach", 5.75))  # the arms' 4.5 h + FULL's 60 min + one exam run
        self.assertIsNone(pod.shortened)  # $0.69/h: 5.75 h + the backstop's 0.5 h = $4.31 <= $5
        sh = [c[1] for c in pod.calls if c[0] == "ssh" and "pilot_train.sh" in c[1]][0]
        p = json.loads((pt.LISTS / "plan.json").read_text())
        self.assertRegex(sh, rf"pilot_train\.sh \d+ \d+ checkpoints/init/pilot\.pt 2 {p['new_clips']} "
                             rf"{p['full_clips']} 10 muavic,owner_silent ")  # chunk 2: 24 GB
        life, arms = map(int, sh.split("pilot_train.sh ")[1].split()[:2])
        self.assertTrue(5.75 * 3600 - 730 < life <= 5.75 * 3600 - 720)  # deadline.sh's tail ends by hour 5.75
        self.assertTrue(4.5 * 3600 - 730 < arms <= 4.5 * 3600 - 720)  # the arms keep what they had without FULL
        pushes = [c for c in pod.calls if c[0] == "push"]
        self.assertIn(("push", str(pt.INIT), "/root/lr/checkpoints/init/pilot.pt", None), pushes)
        self.assertIn(("push", str(cl.PUBLIC) + "/", "/root/lr/data/pool/", str(pt.LISTS / "pool.txt")), pushes)
        for f in ("harvester/pod/pilot_train.sh", "harvester/pilot_train.py", "harvester/checkpoint_loop.py"):
            dst = "/root/lr/harvester/" + ("pod/" if "pod/" in f else "")
            self.assertIn(("push", str(ROOT / f), dst, None), pushes)
        self.assertEqual(v["verdict"], "diversity helps")
        self.assertIn("verdict: diversity helps", out)
        md = pt.REPORT.read_text()
        self.assertIn("**diversity helps**", md)
        self.assertIn("$3.10", md)
        self.assertIn("| muavic | 70.0 | 40.0 | 60.0 | 60.0 | 30.0 |", md)
        self.assertIn("| muavic | +20.0 [+20.0, +20.0] sig | +20.0 [+20.0, +20.0] sig | +30.0 [+30.0, +30.0] sig | "
                      "+10.0 [+10.0, +10.0] sig | +10.0 [+10.0, +10.0] sig | +40.0 [+40.0, +40.0] sig |", md)
        self.assertIn("| full | 200 | 200 |", md)
        for f in pt.FULL_FILES:  # the release model is on the Mac and its paths are printed
            self.assertEqual((pt.OUT / "checkpoints" / "full" / f).read_bytes(), b"release")
            self.assertIn(f"  {pt.OUT / 'checkpoints' / 'full' / f}", out)
        self.assertEqual(json.loads((pt.OUT / "pilot_run.json").read_text())["full"], "done")
        self.assertIn("| owner_silent | +0.0 [+0.0, +0.0] | -10.0 [-10.0, -10.0] |", md)
        self.assertIn("| narrow1 | 450 | 450 |", md)
        self.assertIn("нет (dev-loss не лучше шага 0)", md)
        self.assertIn("| new | 450 | 450 |", md)
        self.assertEqual(json.loads((pt.OUT / "pilot_run.json").read_text())["cost"], 3.1)
        self.go()  # a second pilot keeps the first one's results aside, never reads them as its own (R13)
        self.assertEqual(len(list(pt.OUT.parent.glob("tp.*"))), 1)
        self.assertIn("4090 75 steps per arm, FULL ", self.plan()[1])  # 3 passes over 805 clips

    def test_full_skipped_or_failed_keeps_the_verdict(self):
        v, out = self.go(full="skip")
        self.assertEqual(v["verdict"], "diversity helps")
        self.assertIn("FULL: skipped: no time left", out)
        self.assertIn("| full | — | — | — | — | — (skipped: no time left", pt.REPORT.read_text())
        self.assertTrue((pt.OUT / "checkpoints" / "pilot_new" / "last.pt").exists())  # no FULL: new's last step
        v, out = self.go(full="fail")  # PILOT_FAILED after ARMS_DONE: FULL broke, the pilot's results stand
        self.assertEqual(v["verdict"], "diversity helps")
        self.assertIn("FULL: failed", out)

    def test_dear_card_gets_fewer_hours(self):
        FakePod.instances.clear()
        self.go(rate=0.9)
        pod = FakePod.instances[-1]
        self.assertEqual(pod.calls[0], ("attach", 5.75))
        h = 5.0 / 0.9 - 0.5  # 5.06 h: with the backstop's 0.5 h it is $5.00
        self.assertAlmostEqual(json.loads((pt.OUT / "pilot_run.json").read_text())["hours"], h, places=2)
        self.assertIsNotNone(pod.shortened)
        sh = [c[1] for c in pod.calls if c[0] == "ssh" and "pilot_train.sh" in c[1]][0]
        life, arms = map(int, sh.split("pilot_train.sh ")[1].split()[:2])
        self.assertTrue(h * 3600 - 735 < life <= h * 3600 - 715)
        self.assertTrue(4.5 * 3600 - 730 < arms <= 4.5 * 3600 - 720)  # the arms are not shortened for FULL

    def test_hold_and_lock_refuse_before_any_pod(self):
        FakePod.instances.clear()
        (self.tmp / "STAGE_HOLD").write_text("stage 1: budget spent\n")
        with self.assertRaisesRegex(SystemExit, r"\[R18\]"):
            self.go()
        (self.tmp / "STAGE_HOLD").unlink()
        (self.tmp / "OPERATOR.lock").write_text("other\n")
        with self.assertRaisesRegex(SystemExit, r"\[R7\]"):
            self.go()
        self.assertEqual(FakePod.instances, [])

    def test_no_muavic_exam_refuses(self):
        FakePod.instances.clear()
        shutil.rmtree(cl.EXAMS_DIR / "muavic")
        with self.assertRaisesRegex(SystemExit, "MuAViC exam is not frozen"):
            self.go()
        self.assertEqual(FakePod.instances, [])

    def test_failures_fetch_then_delete(self):
        with self.assertRaisesRegex(SystemExit, "PILOT_FAILED.*\\$3.1 spent"):
            self.go(pod_fails=True)
        self.assertTrue((pt.OUT / "pilot.log").exists())  # the pod's log comes back for the post-mortem
        calls = [c[0] for c in FakePod.instances[-1].calls]
        self.assertLess(calls.index("pull"), calls.index("delete"))
        with self.assertRaisesRegex(SystemExit, "stopped answering"):
            self.go(mute=True)
        calls = [c[0] for c in FakePod.instances[-1].calls]
        self.assertEqual(calls[-1], "delete")
        self.assertIn("pull", calls)  # whatever exists is fetched before the pod goes
        self.assertTrue((pt.OUT / "results" / "exams" / "pilot_init.json").exists())
        # the Mac gives up GIVE_UP_S before the pod's hour POD_HOURS, so its last pull finds the pod alive
        with mock.patch.object(pt, "POD_HOURS", 2 / 3600), mock.patch.object(pt, "GIVE_UP_S", 1.5), \
                self.assertRaisesRegex(SystemExit, "no result within"):
            self.go_never_done()
        pod = FakePod.instances[-1]
        self.assertLess(pod.gave_up - pod.attached, 2 - 1.5 + 0.3)
        with self.assertRaisesRegex(SystemExit, "no GPU offer"):
            self.go(fail="no GPU offer")
        self.assertTrue(FakePod.instances[-1].deleted)
        self.assertNotIn("pull", [c[0] for c in FakePod.instances[-1].calls])

    def go_never_done(self):
        """A pod that answers but never finishes: the Mac stops at the pod's hour POD_HOURS, fetches, deletes."""
        class Slow(FakePod):
            def attach(self, hours):
                self.attached = time.time()
                return super().attach(hours)

            def delete(self):
                self.gave_up = time.time()
                super().delete()

            def ssh(self, cmd, check=True):
                if "pilot_train.sh" in cmd:
                    self.calls.append(("ssh", cmd))
                    return argparse.Namespace(stdout="", returncode=0)
                return super().ssh(cmd, check)
        remote = self.tmp / "remote_slow"
        remote.mkdir(exist_ok=True)
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                pt.run(SINCE, pod_factory=lambda name: Slow(name, remote, self.results()), poll=0.05)
        finally:
            calls = [c[0] for c in FakePod.instances[-1].calls]
            self.assertEqual(calls[-2:], ["pull", "delete"])

    def test_results_are_pulled_as_they_appear(self):
        """Exam results arrive one per poll; then the pod stops answering and no pull works any more: what was
        pulled on the way is what the pilot keeps."""
        class Dying(FakePod):
            polls = 0

            def ssh(self, cmd, check=True):
                r = self.remote
                if "pilot_train.sh" in cmd:
                    self.calls.append(("ssh", cmd))
                    (r / "results" / "exams").mkdir(parents=True, exist_ok=True)
                    (r / "pilot.log").write_text("started\n")
                    return argparse.Namespace(stdout="", returncode=0)
                if "@exams" not in cmd:
                    return super().ssh(cmd, check)
                Dying.polls += 1
                if Dying.polls > 4:
                    return argparse.Namespace(stdout="", returncode=255)
                name = ("init",) + pt.ARMS[:2]
                if Dying.polls <= 3:
                    n = name[Dying.polls - 1]
                    (r / "results" / "exams" / f"pilot_{n}.json").write_text(json.dumps(self.results[n]))
                ls = " ".join(sorted(x.name for x in (r / "results" / "exams").iterdir()))
                return argparse.Namespace(stdout=f"@exams {ls}\nstep 10/450 loss 1.0\n", returncode=0)

            def pull(self, src, dst):
                if Dying.polls > 4:
                    self.calls.append(("pull", src))
                    return 255
                super().pull(src, dst)
                return 0
        remote = self.tmp / "remote_dying"
        remote.mkdir()
        with contextlib.redirect_stdout(io.StringIO()) as out, self.assertRaisesRegex(SystemExit, "stopped answering"):
            pt.run(SINCE, pod_factory=lambda name: Dying(name, remote, self.results()), poll=0)
        got = sorted(x.name for x in (pt.OUT / "results" / "exams").iterdir())
        self.assertEqual(got, ["pilot_init.json", "pilot_narrow0.json", "pilot_new.json"])
        pulls = [c[1] for c in FakePod.instances[-1].calls if c[0] == "pull"]
        self.assertEqual(pulls.count("/root/lr/results/exams/"), 3 + 3)  # one per new result, 3 tries at the end
        self.assertIn("pull 3/3: rsync failed", out.getvalue())

    def test_dev_pct_reaches_the_pod(self):
        FakePod.instances.clear()
        self.go()
        sh = [c[1] for c in FakePod.instances[-1].calls if c[0] == "ssh" and "pilot_train.sh" in c[1]][0]
        self.assertIn(f" {pt.DEV_PCT} muavic,owner_silent > ", sh)
        script = (HERE / "pod" / "pilot_train.sh").read_text()
        self.assertIn('DEV_PCT=$7 ONLY=$8', script)
        self.assertIn('--dev-pct "$DEV_PCT"', script.split("train() {")[1].split("}")[0])  # every train_e2e.py call
        runs = [x for x in script.splitlines() if "exams.py run" in x]
        self.assertEqual(len(runs), 2)
        nxt = script.splitlines()
        for i, x in enumerate(nxt):
            if "exams.py run" in x:  # the init exam (timed for the budget) and every arm's: the same exams
                self.assertIn('--only "$ONLY"', x + nxt[i + 1])


class Fetch(Data):
    def test_retries_until_the_results_are_here(self):
        remote = self.tmp / "remote"
        (remote / "results" / "exams").mkdir(parents=True)
        for n in ("init",) + pt.ARMS:
            (remote / "results" / "exams" / f"pilot_{n}.json").write_text("{}")

        class Flaky(FakePod):
            fails = 2

            def pull(self, src, dst):
                if src.endswith("results/exams/") and Flaky.fails:
                    Flaky.fails -= 1
                    self.calls.append(("pull", src))
                    return 23
                super().pull(src, dst)
                return 0
        pod = Flaky("tp", remote, {})
        want = {f"pilot_{n}.json" for n in ("init",) + pt.ARMS}
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(pt.fetch(pod, want), [])
        self.assertEqual([c[1] for c in pod.calls].count("/root/lr/results/exams/"), 3)
        Flaky.fails = 5
        shutil.rmtree(pt.OUT)
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(len(pt.fetch(pod, want)), 4)  # gives up after 3 tries, says what is missing

    def test_full_checkpoint_retried_until_here(self):
        remote = self.tmp / "remote"
        (remote / "checkpoints" / "pilot_full").mkdir(parents=True)
        for f in pt.FULL_FILES:
            (remote / "checkpoints" / "pilot_full" / f).write_bytes(b"release")

        class Flaky(FakePod):
            fails = 2

            def pull(self, src, dst):
                if src.endswith("last_venc.pth") and Flaky.fails:
                    Flaky.fails -= 1
                    self.calls.append(("pull", src))
                    return 12
                super().pull(src, dst)
                return 0
        pod = Flaky("tp", remote, {})
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(pt.fetch(pod, (), final=True, full=True), [])
        pulls = [c[1] for c in pod.calls]
        self.assertEqual(pulls.count("/root/lr/checkpoints/pilot_full/last_venc.pth"), 3)
        self.assertEqual(pulls.count("/root/lr/checkpoints/pilot_full/last.pt"), 1)  # not pulled again once here

    def test_muavic_section_clips_excluded(self):
        self.plan()
        listed = set(self.read("pool"))
        self.assertFalse({s for s in listed if "muv1" in s})


class ExamRun(unittest.TestCase):
    def test_failed_crop_scores_as_empty(self):
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        (tmp / "owner_voiced" / ".crops").mkdir(parents=True)
        items = [dict(id=f"v{i}", file=f"v{i}.mp4", text="раз два три", speaker="owner", raw=True) for i in range(3)]
        ex = {"owner_voiced": dict(items=items), "muavic": dict(items=[dict(items[0], id="m0", raw=False)])}

        def face_file(d, r):
            if r["id"] == "v1":
                (d / ".crops" / "v1.avi").write_bytes(b"half")
                raise RuntimeError("no face found")
            return d / r["file"]
        with mock.patch.object(exams, "face_file", face_file), contextlib.redirect_stdout(io.StringIO()) as out:
            failed = exams.crop_all(tmp, ex)
        self.assertEqual(failed, {"owner_voiced": {"v1"}})
        self.assertFalse((tmp / "owner_voiced" / ".crops" / "v1.avi").exists())  # no half crop for the next run
        self.assertIn("v1: no crop (RuntimeError: no face found)", out.getvalue())
        self.assertEqual(exams.score(items[1], ""), ["v1", "owner", 3, 3, ""])  # every word missed
        self.assertEqual(exams.score(items[0], "раз два три")[2], 0)


class PodDelete(unittest.TestCase):
    def pod(self, answers):
        """A checkpoint_loop.Pod over a fake RunPod API: answers are returned or raised in turn."""
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        state = tmp / "tp.json"
        state.write_text("{}")
        calls = []

        def req(method, path, body=None):
            calls.append(method)
            a = answers.pop(0)
            if isinstance(a, BaseException):
                raise a
            return a
        pod = object.__new__(cl.Pod)
        pod.name, pod.st = "tp", dict(pod_id="abc")
        pod.h = argparse.Namespace(rp=argparse.Namespace(req=req), state_file=lambda: state)
        return pod, state, calls

    def delete(self, answers):
        pod, state, calls = self.pod(answers)
        with contextlib.redirect_stdout(io.StringIO()):
            pod.delete(wait=0)
        return state.exists(), calls

    def test_delete_retries_and_keeps_the_state_until_gone(self):
        err = SystemExit("RunPod API DELETE /pods/abc -> 500: busy")
        self.assertEqual(self.delete([err, {"desiredStatus": "RUNNING"}, {}]),
                         (False, ["DELETE", "GET", "DELETE"]))
        self.assertEqual(self.delete([err, {"desiredStatus": "RUNNING"}] * 3),
                         (True, ["DELETE", "GET"] * 3))  # never confirmed: harvester/reaper.py finds the state file
        self.assertEqual(self.delete([err, SystemExit("RunPod API GET /pods/abc -> 404: not found")]),
                         (False, ["DELETE", "GET"]))
        self.assertEqual(self.delete([OSError("timeout"), {"desiredStatus": "TERMINATED"}]), (False, ["DELETE", "GET"]))


class Shell(unittest.TestCase):
    def test_syntax(self):
        for f in ("pilot_train.sh", "train_stage.sh"):
            subprocess.run(["bash", "-n", str(HERE / "pod" / f)], check=True)


if __name__ == "__main__":
    unittest.main()
