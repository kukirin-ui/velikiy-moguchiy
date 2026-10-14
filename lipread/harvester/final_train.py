#!/usr/bin/env python3
"""The long training after the pilot: one run from e2e_full on every collected clip, the release candidate.

  final_train.py plan                      (Mac) pick the clips, write harvester/final/, print the plan; no pod
  caffeinate -i final_train.py run         one trainer pod: smoke run, up to PASSES passes over the clips in what the
                                           budget buys, last.pt + best.pt pulled as they are saved (every ~45 min), the
                                           exams of both and of the app's current model, results/final.md, then the
                                           better of the two by MuAViC WER installed for the app (`install`)
  final_train.py report                    (Mac) results/final.md again from the pulled exam results
  final_train.py install [last|best]       (Mac) the app's model folder gets the final model, the old one kept beside

The clips are the pilot's (harvester/pilot_train.py candidates(): after harvester/pilot_start.txt, 720p, 10-200
frames, no exam clips, no owner test phrases) with no NARROW to match: every train clip, at most 24% per channel (R1),
dev = the same held-out channels as the pilot's. No model runs on the Mac (R11): it selects, ships, pulls, copies.
"""
from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import math
import shutil
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(ROOT))
import checkpoint_loop as cl  # noqa: E402
import exams  # noqa: E402
import pilot_train as pt  # noqa: E402
import preflight  # noqa: E402

TRAINER = "tf"
LISTS = HERE / "final"
OUT = cl.RUNS / "final"
REPORT = ROOT / "results" / "final.md"
INIT = pt.INIT
APP_RUN = ROOT / "results" / "pod_runs" / "t1" / "checkpoints" / "me1"  # lips_service.py DEFAULT_RUN
PILOT_EXAMS = pt.OUT / "results" / "exams"
CODE = cl.CODE + ["harvester/pod/final_train.sh", "harvester/final_train.py", "harvester/pilot_train.py",
                  "harvester/checkpoint_loop.py", "harvester/preflight.py"]
# (GPU types, $/h ceiling) tried in order: the cheapest community 3090 first
TIERS = (({"NVIDIA GeForce RTX 3090": (24, 12.75)}, 0.30),
         ({"NVIDIA GeForce RTX 4090": (24, 10.0), "NVIDIA RTX A5000": (24, 15.0)}, 0.60))
USD_CAP = 5.0  # the pod with the backstop grace
BACKSTOP_H = pt.BACKSTOP_H
PASSES = 3
SAVE_MIN = 45  # last.pt (and best.pt when the dev loss improves) at least this often
EXAM_RUNS = 3  # last.pt, best.pt, the app's model
SETUP_MIN, SMOKE_MIN, EXAM_MIN = 25, 10, 6
DEADLINE_TAIL_S = pt.DEADLINE_TAIL_S
PULL_S = 600
GIVE_UP_S = 600
LOST_POLLS = 30  # a Mac offline this long stops polling; the pod still ends on its own timer
CKPT_FILES = ("last.pt", "last_venc.pth", "best.pt", "best_venc.pth")
EXAMS = pt.EXAMS
MIN_STEPS = 200
WAIT_H = 4  # for a GPU offer before giving up
log = pt.log


# ---------------------------------------------------------------- plan
def plan():
    since = pt.pilot_start()
    rows, low = pt.candidates(since, pt.DEV_PCT)
    train = [c for c in rows if c.split == "train" and c.ch]
    stems = {c.stem: c for c in train}
    clips = [stems[s] for s in cl.balance([(c.stem, c.ch, c.mtime) for c in train], len(train), pt.SHARE)]
    d = pt.describe(clips)
    if d["channels"] < pt.MIN_CHANNELS or d["max_share"] > cl.MAX_SHARE:
        raise SystemExit(f"[R1] {d['clips']} clips from {d['channels']} channels, largest {d['max_share']:.0%}")
    dev, dev_ch = pt.dev_clips(rows, pt.DEV_PCT)
    LISTS.mkdir(parents=True, exist_ok=True)
    (LISTS / "final.txt").write_text(pt.lines([c.stem for c in clips] + dev))
    (LISTS / "pool.txt").write_text(pt.lines(sorted({c.stem for c in clips} | set(dev))))
    steps = PASSES * len(clips) // cl.CLIPS_PER_STEP
    p = dict(created=time.strftime("%F %T"), since=since, since_str=time.strftime("%F %T", time.localtime(since)),
             set={k: v for k, v in d.items() if k != "max_share"}, clips=len(clips), dev=len(dev),
             dev_channels=len(dev_ch), low_source=low, init=pt.rel(INIT), steps_3passes=steps)
    (LISTS / "plan.json").write_text(json.dumps(p, ensure_ascii=False, indent=1))
    top = ", ".join(f"{c} {s:.0%}" for c, s in d["top"])
    print(f"final: {d['clips']} clips {d['hours']} h {d['channels']} channels (since {p['since_str']}, {low} dropped "
          f"below 720p), mean {d['mean_s']} s; top: {top}\n  dev {len(dev)} clips of {len(dev_ch)} held-out "
          f"channels; {PASSES} passes = {steps} steps")
    for gpus, cap in TIERS:
        for g, (_, sps) in gpus.items():
            h = hours_needed(steps, sps)
            print(f"  {g.split()[-1]} <= ${cap}/h: ~{h:.1f} h, ~${h * cap:.2f} at most for {steps} steps "
                  f"(budget ${USD_CAP:g}: {USD_CAP / cap - BACKSTOP_H:.1f} h)")
    return p


def hours_needed(steps, sps):
    evals = steps * sps / (SAVE_MIN * 60) + 2
    s = ((SETUP_MIN + SMOKE_MIN + EXAM_RUNS * EXAM_MIN) * 60 + steps * sps + evals * 60 + PULL_S + DEADLINE_TAIL_S
         + 600)
    return s / 3600


# ---------------------------------------------------------------- the pod's step budget
def budget(sps, overhead_s, exam_s, left_s, clips):
    """(steps, eval every, warmup, time guard min): at most PASSES passes, evaluations (dev loss, best.pt, last.pt)
    every SAVE_MIN, the run, EXAM_RUNS exam runs and the Mac's pull within left_s."""
    dev_s = overhead_s / 2
    every = max(25, int(SAVE_MIN * 60 / sps))
    train_s = left_s - EXAM_RUNS * exam_s - PULL_S - overhead_s
    by_time = int(train_s / (sps + dev_s / every))
    if by_time < MIN_STEPS:
        raise SystemExit(f"{by_time} steps fit in {left_s:.0f} s ({sps:.2f} s/step, exam run {exam_s:.0f} s, "
                         f"overhead {overhead_s:.0f} s); at least {MIN_STEPS} needed")
    steps = min(PASSES * clips // cl.CLIPS_PER_STEP, by_time)
    every = min(every, steps)
    guard = min(math.ceil(1.15 * (steps * sps + (steps // every + 1) * dev_s) / 60) + 1, int(train_s / 60))
    return steps, every, max(5, steps // 20), guard


def cmd_steps(a):
    sps, train_s = pt.smoke_speed(Path(a.smoke_log).read_text())
    overhead = max(0.0, a.smoke_s - train_s)
    s = budget(sps, overhead, a.exam_s, a.left, a.clips)
    print(f"FINAL: {sps:.2f} s/step, run overhead {overhead:.0f} s, {a.left:.0f} s left: {s[0]} steps "
          f"({s[0] * cl.CLIPS_PER_STEP / a.clips:.2f} passes over {a.clips} clips), evaluation and checkpoints every "
          f"{s[1]} steps, guard {s[3]} min", file=sys.stderr)
    print(*s)


# ---------------------------------------------------------------- the pod
class FinalPod(pt.PilotPod):
    def attach(self, hours):
        """The first tier with an offer; a pod whose CUDA does not start is given back (community hosts had broken
        CUDA). Pod.attach reads checkpoint_loop's GPUS and MAX_PRICE."""
        why = []
        for gpus, cap in TIERS:
            for _ in range(3):
                cl.GPUS, cl.MAX_PRICE = gpus, cap
                try:
                    gpu = super().attach(min(hours, USD_CAP / cap - BACKSTOP_H))
                except SystemExit as e:
                    why.append(str(e))
                    break
                r = self.ssh("python3 -c 'import torch; torch.zeros(1).cuda()'", check=False)
                if r.returncode == 0:
                    return gpu
                log(f"{self.name}: CUDA does not start on {gpu}: {r.stderr.strip()[-200:]}; giving the pod back")
                self.delete()
                if self.st is not None:
                    raise SystemExit(f"{self.name}: a pod with broken CUDA is not deleted ({self.st['pod_id']})")
        raise SystemExit("no trainer pod: " + "; ".join(why))


POLL = ("cd /root/lr && ls FINAL_DONE FINAL_FAILED TRAIN_DONE 2>/dev/null; "
        "echo \"@exams $(ls results/exams 2>/dev/null | tr '\\n' ' ')\"; "
        "echo \"@ckpt $(cd checkpoints/final 2>/dev/null && stat -c '%n:%Y' *.pt *.pth 2>/dev/null | tr '\\n' ' ')\"; "
        "tail -1 final.log")


def field(out, tag):
    return next((x[len(tag) + 1:].split() for x in out.splitlines() if x.startswith(tag + " ")), None)


def run(poll=60):
    p = json.loads((LISTS / "plan.json").read_text())
    if not (cl.EXAMS_DIR / exams.MAIN / "manifest.json").exists():
        raise SystemExit("[R16] the MuAViC exam is not frozen")
    for f in (INIT, APP_RUN / "best.pt"):
        if not f.exists():
            raise SystemExit(f"missing {f}")
    preflight.require_no_hold()
    preflight.acquire_lock()
    if OUT.exists():  # R13
        OUT.rename(OUT.with_name(f"final.{time.strftime('%Y%m%d-%H%M%S', time.localtime(OUT.stat().st_mtime))}"))
    OUT.mkdir(parents=True)
    res = dict(started=time.strftime("%F %T"), ok=None, cost=None, gpu=None, hours=None, missing=None)
    try:
        res["ok"] = run_pod(p, res, poll)
    except BaseException as e:
        res["ok"] = f"{type(e).__name__}: {e}"
    res["ended"] = time.strftime("%F %T")
    (OUT / "final_run.json").write_text(json.dumps(res, indent=1))
    log(f"{TRAINER}: {'done' if res['ok'] is True else 'failed: ' + str(res['ok'])}; ${res['cost']} spent; "
        f"missing: {res['missing'] or 'nothing'}")
    choice = report()
    if choice:
        install(choice)
    if res["ok"] is not True:
        raise SystemExit(f"final failed: {res['ok']}")


def run_pod(p, res, poll):
    pod = FinalPod(TRAINER)
    up, seen, done = False, None, False
    try:
        hours = hours_needed(p["steps_3passes"], max(s for g, _ in TIERS for _, s in g.values()))
        res["gpu"] = gpu = attach_waiting(pod, hours)
        up, t_up = True, time.time()
        res["hours"] = hours = round(min(hours, USD_CAP / pod.rate() - BACKSTOP_H), 2)
        end = t_up + hours * 3600
        pod.shorten(end)
        log(f"{TRAINER}: {gpu} at ${pod.rate()}/h, {hours} h of pod (<= ${hours * pod.rate():.2f}, "
            f"${(hours + BACKSTOP_H) * pod.rate():.2f} with the backstop)")
        chunk = 2 if cl.GPUS.get(gpu, (24, 0))[0] < 32 else 4
        pod.ssh("mkdir -p /root/lr/data/pool /root/lr/data/exams /root/lr/results/exams /root/lr/checkpoints/init "
                "/root/lr/checkpoints/app /root/lr/harvester/pod /root/lr/lists && rm -f /root/lr/FINAL_DONE "
                "/root/lr/FINAL_FAILED /root/lr/TRAIN_DONE")
        for c in CODE:
            pod.push(ROOT / c, "/root/lr/" + str(Path(c).parent) + "/")
        pod.push(str(cl.PUBLIC) + "/", "/root/lr/data/pool/", files_from=LISTS / "pool.txt")
        pod.push(LISTS / "final.txt", "/root/lr/lists/final.txt")
        pod.push(str(cl.EXAMS_DIR) + "/", "/root/lr/data/exams/")
        pod.push(str(pt.CLIPS) + "/", "/root/lr/clips/", only="*.txt")
        pod.push(INIT, "/root/lr/checkpoints/init/final.pt")
        pod.push(APP_RUN / "best.pt", "/root/lr/checkpoints/app/best.pt")
        life = int(end - DEADLINE_TAIL_S - time.time())
        pod.ssh(f"cd /root/lr || exit 1; setsid nohup bash harvester/pod/final_train.sh {life} "
                f"checkpoints/init/final.pt {chunk} {p['clips']} {pt.DEV_PCT} {EXAMS} > /root/lr/final.log 2>&1 "
                f"< /dev/null &")
        log(f"{TRAINER}: training started; the pod ends by {time.strftime('%H:%M', time.localtime(end))}")
        lost, last, listed = 0, None, None
        while True:
            time.sleep(poll)
            r = pod.ssh(POLL, check=False)
            if r.returncode == 255:
                lost += 1
                if lost >= LOST_POLLS and not pod.h.pod_alive(pod.st):
                    return "the pod is gone"
                if time.time() > end - GIVE_UP_S:
                    return "the pod stopped answering before its end"
                continue
            lost = 0
            ck = field(r.stdout, "@ckpt")
            if ck and ck != seen:  # a new checkpoint: pulled now, the pod may not answer later
                seen = ck
                pull_ckpts(pod)
            got = field(r.stdout, "@exams")
            if got and got != listed:
                listed = got
                pod.pull("/root/lr/results/exams/", OUT / "results" / "exams")
            if "FINAL_FAILED" in r.stdout or "FINAL_DONE" in r.stdout:
                done = "FINAL_DONE" in r.stdout
                break
            if time.time() > end - GIVE_UP_S:
                return f"no result within {hours} h"
            tail = r.stdout.strip().splitlines()[-1:]
            if tail and tail != last and not tail[0].startswith("@"):
                log(f"{TRAINER}: {tail[0][-200:]}")
                last = tail
        return True if done else "the pod reported FINAL_FAILED (final.log)"
    finally:
        if up:
            with contextlib.suppress(Exception):
                res["missing"] = final_pull(pod)
            with contextlib.suppress(Exception):
                pod.ssh("touch /workspace/mac_pulled", check=False)
        with contextlib.suppress(Exception):
            res["cost"] = pod.cost()
        pod.delete()


def attach_waiting(pod, hours):
    """FinalPod.attach, retried every minute for WAIT_H while no tier has an offer (they come and go)."""
    give_up, told = time.time() + WAIT_H * 3600, 0
    while True:
        try:
            return pod.attach(hours)
        except SystemExit as e:
            if not str(e).startswith("no trainer pod") or time.time() > give_up:
                raise
            if time.time() - told > 1800:
                log(f"{TRAINER}: {e}; retrying every minute until "
                    f"{time.strftime('%H:%M', time.localtime(give_up))}")
                told = time.time()
            time.sleep(60)


def pull_ckpts(pod):
    return pod.pull("/root/lr/checkpoints/final/", OUT / "checkpoints")


def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def final_pull(pod, tries=3):
    """Pulls the exams, logs and checkpoints until every checkpoint file the pod has is here with the pod's md5.
    Returns what is still missing or differs."""
    bad = ["?"]
    for i in range(tries):
        pod.pull("/root/lr/results/exams/", OUT / "results" / "exams")
        pod.pull("/root/lr/logs/", OUT / "logs")
        pod.pull("/root/lr/final.log", OUT)
        pull_ckpts(pod)
        r = pod.ssh("cd /root/lr/checkpoints/final && md5sum " + " ".join(CKPT_FILES) + " 2>/dev/null", check=False)
        remote = {n: h for h, n in (x.split() for x in r.stdout.splitlines() if len(x.split()) == 2)}
        if r.returncode == 255:
            bad = ["the pod does not answer"]
            continue
        bad = [n for n, h in remote.items() if not (OUT / "checkpoints" / n).exists()
               or md5(OUT / "checkpoints" / n) != h]
        if not bad:
            break
        log(f"{TRAINER}: final pull {i + 1}/{tries}: {', '.join(bad)} missing or different")
    return bad


# ---------------------------------------------------------------- report and install
def load(f):
    return json.loads(f.read_text()) if f.exists() else None


def report():
    """results/final.md; returns 'last' or 'best', whichever final checkpoint has the lower MuAViC WER, or None."""
    ex = OUT / "results" / "exams"
    res = {"init": load(PILOT_EXAMS / "pilot_init.json"), "pilot new": load(PILOT_EXAMS / "pilot_new.json"),
           "pilot full": load(PILOT_EXAMS / "pilot_full.json"), "app (me1)": load(ex / "final_app.json"),
           "final last": load(ex / "final_last.json"), "final best": load(ex / "final_best.json")}
    res = {k: v for k, v in res.items() if v}
    p = load(LISTS / "plan.json") or {}
    run = load(OUT / "final_run.json") or {}
    wer = {k: res[k]["exams"][exams.MAIN]["wer"] for k in ("final last", "final best")
           if k in res and exams.MAIN in res[k]["exams"]}
    choice = min(wer, key=wer.get) if wer else None
    init_wer = (res.get("init") or {}).get("exams", {}).get(exams.MAIN, {}).get("wer")
    worse = choice and init_wer is not None and wer[choice] > init_wer
    w = ["# Финальное обучение\n",
         f"Записано {time.strftime('%F %T')}. От `{p.get('init')}` на всех клипах с {p.get('since_str')} "
         f"(720p, 10–200 кадров, ≤ 24% на канал): {p.get('clips')} клипов, {p.get('set', {}).get('hours')} ч, "
         f"{p.get('set', {}).get('channels')} каналов; dev {p.get('dev')} клипов отложенных каналов. "
         f"Под {run.get('gpu') or '?'}, {run.get('hours') or '?'} ч срока, потрачено {exams.money(run.get('cost'))}; "
         f"итог: {run.get('ok')}.\n",
         "## Экзамены, WER %\n", "| экзамен | " + " | ".join(res) + " |", "|---|" + "---|" * len(res)]
    for name in exams.ORDER:
        if any(name in r["exams"] for r in res.values()):
            w.append(f"| {name} | " + " | ".join(exams.fmt(r["exams"].get(name)) for r in res.values()) + " |")
    if choice:
        key = choice
        pairs = [(key, b) for b in ("init", "pilot full", "app (me1)") if b in res]
        w += ["", f"Δ = падение WER {key} относительно другой модели, пункты [95% интервал]; MuAViC по людям, "
              "остальные по клипам.\n", "| экзамен | " + " | ".join(f"vs {b}" for _, b in pairs) + " |",
              "|---|" + "---|" * len(pairs)]
        cmp = [pt.compare(res[b], res[a]) for a, b in pairs]
        for name in exams.ORDER:
            row = [c.get(name) for c in cmp]
            if any(x is not None for x in row):
                w.append(f"| {name} | " + " | ".join(exams.fmt_boot(x) for x in row) + " |")
        w.append(f"\nНе установлено: {key} хуже init на MuAViC." if worse else
                 f"\nДля приложения выбран **{key}** (меньший WER на MuAViC).")
    REPORT.write_text("\n".join(w) + "\n")
    log(f"report -> {pt.rel(REPORT)}")
    return choice.split()[-1] if choice and not worse else None


def install(which):
    """The app's model folder (lips_service.py DEFAULT_RUN) gets final <which>.pt as best.pt; the folder it had is
    kept beside it as <name>.prev-<time>. Undo: remove the folder and rename the .prev one back."""
    src = OUT / "checkpoints"
    files = {f"{which}.pt": "best.pt", f"{which}_venc.pth": "best_venc.pth"}
    for f in files:
        if not (src / f).exists():
            raise SystemExit(f"missing {src / f}")
    prev = APP_RUN.with_name(f"{APP_RUN.name}.prev-{time.strftime('%Y%m%d-%H%M%S')}")
    tmp = APP_RUN.with_name(APP_RUN.name + ".new")
    shutil.rmtree(tmp, ignore_errors=True)
    tmp.mkdir()
    for f, to in files.items():
        shutil.copy2(src / f, tmp / to)
    (tmp / "DONE").touch()
    (tmp / "SOURCE.txt").write_text(f"{pt.rel(src / f'{which}.pt')} installed {time.strftime('%F %T')}; the model "
                                    f"before it: {prev.name}\n")
    APP_RUN.rename(prev)
    tmp.rename(APP_RUN)
    log(f"installed final {which} as {pt.rel(APP_RUN)}; the previous model is {pt.rel(prev)}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("plan")
    sub.add_parser("run")
    sub.add_parser("report")
    s = sub.add_parser("install")
    s.add_argument("which", nargs="?", choices=("last", "best"), default=None)
    s = sub.add_parser("steps", help="(pod, final_train.sh) steps from the smoke run and the exam time")
    s.add_argument("--smoke-log", required=True)
    s.add_argument("--smoke-s", type=float, required=True)
    s.add_argument("--exam-s", type=float, required=True)
    s.add_argument("--left", type=float, required=True)
    s.add_argument("--clips", type=int, required=True)
    a = ap.parse_args()
    if a.cmd == "plan":
        plan()
    elif a.cmd == "run":
        run()
    elif a.cmd == "report":
        report()
    elif a.cmd == "install":
        install(a.which or report() or "last")
    else:
        cmd_steps(a)


if __name__ == "__main__":
    main()
