"""Fixed exams for every checkpoint of the collection: the same clips from the first checkpoint to the last.

  exams.py freeze [--only muavic,...]                      (Mac) copy each exam's clips into data/exams/<exam>/, once
  exams.py run --ckpt PATH|base --out results/exams/X.json (pod) WER of the checkpoint on every frozen exam
  exams.py record results/exams/X.json [--stage K] [--clip-hours H] [--ckpt-cost $] [--stage-cost $]
                                                           (Mac) paired bootstrap against the previous row, append
                                                           to results/checkpoints.md, print the decision

  a  muavic        MuAViC-ru valid + test: 16 speakers with human transcripts, data/ext/muavic_ru/{valid,test}. Main.
  b  owner_silent  the owner's 50 silent test clips: clips/*.txt, face crops work/faces/NNN.avi (evaluate.py's).
     owner_voiced  the owner's voiced dictations paired with ~/.koe/recordings (whisper_eval.py --set voiced): the raw
                   webcam video is frozen and cropped by preprocess.py where the exam runs (no face detector on the
                   Mac, R11); the reference is GigaAM on the clean dictation audio, verbatim, where it exists.
  c  heldout       clips of the channels train_e2e.py holds out (split by channel, R2), at most --per-channel each.
An exam is frozen the first time all of it is available and never rebuilt; `run` refuses an exam whose files no
longer match their frozen hashes. b_voiced and b_silent are the owner's: a checkpoint fine-tuned on them (me1) is
not comparable on b.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
EXAMS = ROOT / "data" / "exams"
MUAVIC = ROOT / "data" / "ext" / "muavic_ru"
PUBLIC = ROOT / "data" / "public_pod"
CHANNELS = ROOT / "harvester" / "video_channels.tsv"
LEDGER_MD = ROOT / "results" / "checkpoints.md"
LEDGER_JSONL = ROOT / "results" / "checkpoints.jsonl"
ORDER = ("muavic", "owner_silent", "owner_voiced", "heldout")
MAIN = "muavic"
OWNER = ("owner_silent", "owner_voiced")
BEAM = 5
# decision rule on the main exam, WER points: one +50 h step is noisy, so it looks at a window of checkpoints
WINDOW = 3
WINDOW_GAIN = 1.0
BOOT_REPS = 2000
SPEAKER_BOOT_REPS = 10000
NOT_A_CHANNEL = {"manual", "?"}

sys.path.insert(0, str(ROOT))


def sha1(p: Path) -> str:
    h = hashlib.sha1()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def write_exam(name: str, items: list, source: str, root: Path = EXAMS):
    """items: dicts with id, src (face crop, or raw video with raw=True), text, speaker."""
    d = root / name
    tmp = root / f".{name}.tmp"
    shutil.rmtree(tmp, ignore_errors=True)
    tmp.mkdir(parents=True)
    rows = []
    for it in items:
        f = f"{it['id']}{Path(it['src']).suffix}"
        shutil.copyfile(it["src"], tmp / f)
        rows.append(dict(id=it["id"], file=f, text=it["text"], speaker=it["speaker"], sha1=sha1(tmp / f),
                         raw=bool(it.get("raw"))))
    (tmp / "manifest.json").write_text(json.dumps(dict(
        exam=name, frozen=time.strftime("%F %T"), source=source, n=len(rows),
        speakers=len({r["speaker"] for r in rows}), items=rows), ensure_ascii=False, indent=1))
    tmp.rename(d)
    print(f"{name}: frozen {len(rows)} clips, {len({r['speaker'] for r in rows})} speakers -> {d}")


def muavic_items(a):
    sel = [json.loads(x) for x in (MUAVIC / "selection.jsonl").read_text().splitlines() if x.strip()]
    want = [s for s in sel if s["split"] in ("valid", "test")]
    speakers = {s["speaker"] for s in want}
    items = []
    for split in ("valid", "test"):
        for js in sorted((MUAVIC / split).glob("yt_*.json")):
            mp4, txt = js.with_suffix(".mp4"), js.with_suffix(".txt")
            if not (mp4.exists() and txt.exists()):
                continue
            m = json.loads(js.read_text())
            text = txt.read_text(encoding="utf8").strip()
            if text:
                items.append(dict(id=js.stem, src=mp4, text=text, speaker=m.get("speaker") or m.get("channel")))
    have = {i["speaker"] for i in items}
    share = len(items) / max(1, len(want))
    # some talks never pass the close-up filter (faces of 100-110 px): waiting for all 16 would wait forever. Freeze
    # once enough speakers are in and either most segments are cut or the exam sections have settled.
    enough = share >= a.muavic_min_share or muavic_shipped_and_quiet()
    if len(have & speakers) < a.muavic_min_speakers or not enough:
        return None, (f"waiting: {len(have & speakers)}/{len(speakers)} speakers (>= {a.muavic_min_speakers}), "
                      f"{len(items)}/{len(want)} segments cut ({share:.0%}; {a.muavic_min_share:.0%}, or {MUAVIC_SETTLE_MIN} "
                      f"min after the pilot start with no new clip for {MUAVIC_QUIET_MIN} min)")
    return items, (f"MuAViC-ru valid+test, {len(items)}/{len(want)} selected segments cut, "
                   f"{len(have & speakers)}/{len(speakers)} speakers")


MUAVIC_QUIET_MIN = 30
MUAVIC_SETTLE_MIN = 60


def muavic_shipped_and_quiet() -> bool:
    """The exam sections are fed first (mac_feeder --first): an hour after the pilot start and with no new exam clip
    for MUAVIC_QUIET_MIN, whatever is missing was dropped by a download or by the pod's filters and won't come."""
    f = ROOT / "harvester" / "pilot_start.txt"
    if not f.exists():
        return False
    raw = f.read_text().strip()
    try:
        start = float(raw)
    except ValueError:
        start = time.mktime(time.strptime(raw, "%Y-%m-%d %H:%M"))
    newest = max((x.stat().st_mtime for x in MUAVIC.glob("*/yt_*.json")), default=0)
    now = time.time()
    return now - start > MUAVIC_SETTLE_MIN * 60 and now - newest > MUAVIC_QUIET_MIN * 60


def silent_items(_a):
    items = []
    for txt in sorted((ROOT / "clips").glob("*.txt")):
        crop = ROOT / "work" / "faces" / f"{txt.stem}.avi"
        if not crop.exists():
            return None, f"waiting: no crop {crop} (run evaluate.py once)"
        items.append(dict(id=txt.stem, src=crop, text=txt.read_text(encoding="utf8").strip(), speaker="owner"))
    return (items, "clips/ with evaluate.py crops") if items else (None, "no clips/*.txt")


def voiced_items(a):
    import whisper_eval as W
    W.configure("voiced")
    ids = W.clip_ids()[:a.limit or None]
    if not ids:
        return None, "no voiced clips with a dictation pair"
    verbatim = {}
    g = W.WORK / "gigaam.jsonl"
    if g.exists():
        verbatim = {r["id"]: r["text"] for r in W.read_jsonl(g) if r.get("cond") == "clean" and r.get("text")}
    items = [dict(id=cid, src=W.CLIPS / f"{cid}.mp4", text=verbatim.get(cid) or W.ref(cid), speaker="owner", raw=True)
             for cid in ids]
    n = sum(cid in verbatim for cid in ids)
    return items, (f"data/voiced paired with ~/.koe/recordings (whisper_eval.py audio_sources); reference GigaAM on the "
                   f"clean audio for {n}, the dictation text for {len(ids) - n}; cropped where the exam runs")


def channel_map() -> dict:
    out = {}
    if CHANNELS.exists():
        for line in CHANNELS.read_text().splitlines():
            v, _, c = line.partition("\t")
            if v and c:
                out[v] = c
    return out


def heldout_channel(meta: dict, stem: str, chans: dict, dev_pct: int):
    """The channel of a clip if train_e2e.py (rows_from_videos) puts it in dev, else None."""
    import split
    vid = str(meta.get("video_id") or stem.rsplit("__", 1)[0])
    ch = chans.get(vid[3:] if vid.startswith("yt_") else vid)
    if not ch or ch in NOT_A_CHANNEL:
        return None
    return ch if split.split_for(f"ch:{ch}", dev_pct) == "dev" else None


def read_text(p: Path) -> str:
    return " ".join(p.read_text(encoding="utf8").split()).strip()


def heldout_items(a):
    import metrics
    test = {metrics.normalize(read_text(t)) for t in (ROOT / "clips").glob("*.txt")}
    chans = channel_map()
    by_ch = {}
    for js in sorted(Path(a.public).glob("yt_*.json")):
        txt, mp4 = js.with_suffix(".txt"), js.with_suffix(".mp4")
        if not (txt.exists() and mp4.exists()):
            continue
        try:
            meta = json.loads(js.read_text())
        except ValueError:
            continue
        ch = heldout_channel(meta, js.stem, chans, a.dev_pct)
        if ch is None or not 10 <= int(meta.get("frames") or 0) <= 200:
            continue
        text = read_text(txt)
        if text and metrics.normalize(text) not in test:
            by_ch.setdefault(ch, []).append(dict(id=js.stem, src=mp4, text=text, speaker=ch))
    ok = {c: v for c, v in by_ch.items() if len(v) >= a.min_clips}
    if len(ok) < a.min_channels:
        return None, f"waiting: {len(ok)} held-out channels with >= {a.min_clips} clips, {a.min_channels} needed"
    items = []
    for c, v in sorted(ok.items()):
        step = max(1, len(v) // a.per_channel)
        items += v[::step][:a.per_channel]
    return items, f"held-out channels of train_e2e.py (dev_pct {a.dev_pct}, key ch:<channel>), {len(ok)} channels"


BUILDERS = dict(muavic=muavic_items, owner_silent=silent_items, owner_voiced=voiced_items, heldout=heldout_items)


def cmd_freeze(a):
    root = Path(a.exams)
    for name in (a.only.split(",") if a.only else ORDER):
        man = root / name / "manifest.json"
        if man.exists():
            m = json.loads(man.read_text())
            print(f"{name}: frozen {m['frozen']}, {m['n']} clips, {m['speakers']} speakers (never rebuilt)")
            continue
        items, why = BUILDERS[name](a)
        if items is None:
            print(f"{name}: not frozen, {why}")
            continue
        write_exam(name, items, why, root)


def load_exam(d: Path) -> dict:
    m = json.loads((d / "manifest.json").read_text())
    bad = [r["id"] for r in m["items"] if not (d / r["file"]).exists() or sha1(d / r["file"]) != r["sha1"]]
    if bad:
        raise SystemExit(f"[exam] {d.name}: {len(bad)} clips differ from the frozen exam (e.g. {bad[:3]}); an exam "
                         f"never changes during the collection: restore data/exams/{d.name} from a backup")
    return m


def face_file(d: Path, r: dict) -> Path:
    """The face crop of an exam clip; a raw video is cropped once into <exam>/.crops/ by preprocess.py."""
    if not r.get("raw"):
        return d / r["file"]
    crop = d / ".crops" / f"{r['id']}.avi"
    if not crop.exists():
        import preprocess
        crop.parent.mkdir(exist_ok=True)
        preprocess.preprocess_video(str(d / r["file"]), str(crop))
    return crop


def crop_all(root: Path, exams: dict, limit=0) -> dict:
    """Face crops of every exam item first: the face detector and MultiVSR are never in memory together.
    Returns exam -> ids whose crop failed (e.g. no face in a raw video); they are scored as an empty hypothesis."""
    failed = {}
    for name, ex in exams.items():
        for r in ex["items"][:limit or None]:
            try:
                face_file(root / name, r)
            except Exception as e:
                failed.setdefault(name, set()).add(r["id"])
                (root / name / ".crops" / f"{r['id']}.avi").unlink(missing_ok=True)  # never a half-written crop
                print(f"{name}/{r['id']}: no crop ({type(e).__name__}: {e}); scored as an empty hypothesis",
                      flush=True)
    return failed


def score(r: dict, hyp: str) -> list:
    """[id, speaker, errors, words, hyp] of one exam item."""
    import metrics
    e, k = metrics.wer_counts(metrics.normalize(r["text"]), metrics.normalize(hyp))
    return [r["id"], r["speaker"], e, k, hyp]


def cmd_run(a):
    import memguard  # noqa: F401  (MPS limits before import torch)
    import torch
    import mvsr
    root = Path(a.exams)
    only = set(a.only.split(",")) if a.only else set(ORDER)
    exams = {n: load_exam(root / n) for n in ORDER if n in only and (root / n / "manifest.json").exists()}
    if not exams:
        raise SystemExit(f"no frozen exams in {root}" + (f" among {a.only}" if a.only else "")
                         + ": run exams.py freeze on the Mac first")
    device = mvsr.pick_device(a.device)
    failed = crop_all(root, exams, a.limit)
    if any(r.get("raw") for ex in exams.values() for r in ex["items"]):
        import preprocess
        preprocess._DET = None
    if a.ckpt == "base":
        m = mvsr.MultiVSR(device=device, beam_size=a.beam)
    else:
        m = mvsr.MultiVSR(device=device, beam_size=a.beam, lora=a.ckpt)
        ck = torch.load(a.ckpt, map_location="cpu", weights_only=False)
        if "venc" in ck:  # train_e2e.py trains the visual front-end too
            m.venc.load_state_dict(ck["venc"])
        del ck
    out = dict(ckpt=a.ckpt, name=a.name or Path(a.ckpt).parent.name, time=time.strftime("%F %T"), beam=a.beam,
               device=device, exams={})
    for name, ex in exams.items():
        rows = ex["items"][:a.limit or None]
        t0, items, err, n = time.time(), [], 0, 0
        for r in rows:
            hyp = "" if r["id"] in failed.get(name, ()) else \
                m.transcribe_faces(mvsr.read_faces(face_file(root / name, r)))[0]
            items.append(score(r, hyp))
            err, n = err + items[-1][2], n + items[-1][3]
        spk = {}
        for _, s, e, k, _ in items:
            spk.setdefault(s, [0, 0])
            spk[s][0] += e
            spk[s][1] += k
        out["exams"][name] = dict(wer=round(100 * err / max(1, n), 2), errors=err, words=n, clips=len(items),
                                  frozen=ex["frozen"], complete=len(items) == ex["n"],
                                  no_crop=len(failed.get(name, ())),
                                  speaker_wer={s: round(100 * e / max(1, k), 1) for s, (e, k) in sorted(spk.items())},
                                  items=items)
        print(f"{name}: WER {100 * err / max(1, n):.1f}% on {len(items)} clips ({time.time() - t0:.0f} s)", flush=True)
    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    Path(a.out).write_text(json.dumps(out, ensure_ascii=False))


def owner_wer(ex: dict):
    parts = [ex[k] for k in OWNER if k in ex]
    w = sum(p["words"] for p in parts)
    return round(100 * sum(p["errors"] for p in parts) / w, 2) if w else None


def per_clip(res: dict, names) -> dict:
    """clip id -> (errors, words) over the given exams of a run result."""
    return {f"{n}/{it[0]}": (it[2], it[3]) for n in names if n in res["exams"] for it in res["exams"][n]["items"]}


def bootstrap(prev: dict, cur: dict, reps: int = BOOT_REPS, seed: int = 0):
    """Paired bootstrap over the clips both runs share: WER drop prev -> cur in points with its 95% interval.
    None when they share no clips."""
    import random
    ids = sorted(set(prev) & set(cur))
    if not ids:
        return None
    pe, ce, nw = [prev[i][0] for i in ids], [cur[i][0] for i in ids], [prev[i][1] for i in ids]
    total = sum(nw) or 1
    point = 100 * (sum(pe) - sum(ce)) / total
    rng, n, ds = random.Random(seed), len(ids), []
    for _ in range(reps):
        pick = rng.choices(range(n), k=n)
        w = sum(nw[k] for k in pick) or 1
        ds.append(100 * sum(pe[k] - ce[k] for k in pick) / w)
    ds.sort()
    lo, hi = ds[int(0.025 * reps)], ds[int(0.975 * reps) - 1]
    return dict(gain=round(point, 2), lo=round(lo, 2), hi=round(hi, 2), clips=n, significant=lo > 0)


def per_clip_speaker(res: dict, name: str) -> dict:
    """clip id -> (speaker, errors, words) on one exam of a run result."""
    return {it[0]: (it[1], it[2], it[3]) for it in res["exams"].get(name, {}).get("items", [])}


def speaker_bootstrap(prev: dict, cur: dict, reps: int = SPEAKER_BOOT_REPS, seed: int = 0):
    """Paired bootstrap over speakers for an exam of few people (MuAViC: 16): one speaker's clips are not independent,
    so the per-clip interval is too narrow. Resamples speakers with replacement and pools their clips' word errors.
    prev, cur: per_clip_speaker() of two runs. WER drop prev -> cur in points with its 95% interval over the clips
    both runs share; None when they share none."""
    import random
    ids = sorted(set(prev) & set(cur))
    if not ids:
        return None
    spk = {}
    for i in ids:
        s = spk.setdefault(prev[i][0], [0, 0, 0])
        s[0], s[1], s[2] = s[0] + prev[i][1], s[1] + cur[i][1], s[2] + prev[i][2]
    rows = list(spk.values())
    total = sum(r[2] for r in rows) or 1
    point = 100 * sum(r[0] - r[1] for r in rows) / total
    rng, n, ds = random.Random(seed), len(rows), []
    for _ in range(reps):
        pick = rng.choices(rows, k=n)
        w = sum(r[2] for r in pick) or 1
        ds.append(100 * sum(r[0] - r[1] for r in pick) / w)
    ds.sort()
    lo, hi = ds[int(0.025 * reps)], ds[int(0.975 * reps) - 1]
    return dict(gain=round(point, 2), lo=round(lo, 2), hi=round(hi, 2), speakers=n, clips=len(ids),
                prev_wer=round(100 * sum(r[0] for r in rows) / total, 2),
                cur_wer=round(100 * sum(r[1] for r in rows) / total, 2), significant=lo > 0)


def window_gain(history: list, row: dict, wer):
    """WER drop over the last WINDOW checkpoints: from the row WINDOW back (or the first row) to this one."""
    ref = history[-WINDOW] if len(history) >= WINDOW else history[0]
    a, b = wer(ref), wer(row)
    return round(a - b, 2) if a is not None and b is not None else None


def decide(history: list, row: dict) -> dict:
    """The decision rule over a window, since one +50 h step is noisy. history: earlier rows of
    results/checkpoints.jsonl in order (the first is the start); row["boot"]: paired bootstraps against the previous
    row. Continue while (a) gains >= WINDOW_GAIN over the last WINDOW checkpoints or the bootstrap shows a significant
    gain over the previous one; stop collecting after WINDOW checkpoints in a row without a significant gain."""
    if not history:
        return dict(verdict="baseline", best=True, flags=[], window_a=None, sig_a=None)
    main = lambda r: r["exams"].get(MAIN, {}).get("wer")  # noqa: E731
    if main(row) is None:
        return dict(verdict="no decision: main exam (a) missing", best=False, flags=[], window_a=None, sig_a=None)
    boot = row.get("boot") or {}
    sig_a = bool((boot.get(MAIN) or {}).get("significant"))
    win_a = window_gain(history, row, main)
    win_b = window_gain(history, row, lambda r: owner_wer(r["exams"]))
    a_up = (win_a is not None and win_a >= WINDOW_GAIN) or sig_a
    b_up = (win_b is not None and win_b >= WINDOW_GAIN) or bool((boot.get("owner") or {}).get("significant"))
    recent = [r.get("decision", {}).get("sig_a") for r in history[-(WINDOW - 1):]] + [sig_a]
    flags = []
    if a_up:
        verdict = "continue"
        if not b_up:
            flags.append("personal fine-tune needed: (a) improves, the owner's exam (b) does not")
    elif len(recent) == WINDOW and all(x is False for x in recent):
        verdict = "stop collecting"
    else:
        verdict = "continue (no clear gain yet)"
    best_a = min((main(r) for r in history if main(r) is not None), default=None)
    return dict(verdict=verdict, best=best_a is None or main(row) < best_a, flags=flags, window_a=win_a,
                window_b=win_b, sig_a=sig_a)


def fmt(e):
    return f"{e['wer']:.1f}" + ("" if e.get("complete", True) else "*") if e else "—"


def fmt_boot(b):
    return f"{b['gain']:+.1f} [{b['lo']:+.1f}, {b['hi']:+.1f}]{' sig' if b['significant'] else ''}" if b else "—"


def money(x):
    return f"${x:.2f}" if x is not None else "—"


def cmd_record(a):
    res = json.loads(Path(a.result).read_text())
    history = [json.loads(x) for x in LEDGER_JSONL.read_text().splitlines()] if LEDGER_JSONL.exists() else []
    exams = {k: {x: v[x] for x in ("wer", "errors", "words", "clips", "frozen", "complete")}
             for k, v in res["exams"].items()}
    row = dict(time=res["time"], name=a.label or res["name"], ckpt=res["ckpt"], stage=a.stage, clip_hours=a.clip_hours,
               beam=res["beam"], exams=exams, result=str(Path(a.result).resolve()),
               ckpt_cost=getattr(a, "ckpt_cost", None), stage_cost=getattr(a, "stage_cost", None))
    if history and history[0].get("beam") != row["beam"]:
        raise SystemExit(f"beam {row['beam']} differs from the first checkpoint's {history[0].get('beam')}: not the "
                         f"same exam")
    row["boot"] = {}
    if history and Path(history[-1].get("result", "")).is_file():
        prev = json.loads(Path(history[-1]["result"]).read_text())
        row["boot"] = {MAIN: bootstrap(per_clip(prev, [MAIN]), per_clip(res, [MAIN])),
                       "owner": bootstrap(per_clip(prev, OWNER), per_clip(res, OWNER))}
    row["decision"] = d = decide(history, row)
    with open(LEDGER_JSONL, "a") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")
    if not LEDGER_MD.exists():
        LEDGER_MD.write_text(
            "# Checkpoints of the 5000 h collection\n\n"
            f"WER %, beam {BEAM}, the same frozen exams in full for every row (exams.py). (a) MuAViC-ru valid+test, 16 "
            "speakers never trained on, human transcripts: the main exam. (b) the owner: 50 silent clips / voiced "
            "dictations. (c) channels held out of training. Δ = WER drop against the previous row, paired bootstrap "
            "per clip, [95% interval], sig = interval above 0. Window = WER drop over the last "
            f"{WINDOW} checkpoints. Rule: (a) window >= {WINDOW_GAIN:g} or Δ(a) sig -> continue; {WINDOW} rows in a "
            "row without a sig Δ(a) -> stop collecting; (a) improves, (b) does not -> personal fine-tune needed. "
            "Checkpoint $ = the trainer pod for this row (setup, idle wait, training, exams); stage $ = collection "
            "+ checkpoint of the stage so far. * = exam run on part of its clips.\n\n"
            "| time | checkpoint | stage | clip h | (a) MuAViC | (b) silent | (b) voiced | (c) held-out | Δ(a) | "
            "window (a) | Δ(b) | checkpoint $ | stage $ | decision |\n"
            "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|\n")
    ex = row["exams"]
    verdict = d["verdict"] + "".join(f"; {x}" for x in d["flags"])
    with open(LEDGER_MD, "a") as f:
        f.write(f"| {row['time']} | {row['name']} | {row['stage'] if row['stage'] is not None else '—'} | "
                f"{row['clip_hours'] if row['clip_hours'] is not None else '—'} | "
                + " | ".join(fmt(ex.get(k)) for k in ORDER)
                + f" | {fmt_boot(row['boot'].get(MAIN))} | "
                f"{d['window_a'] if d.get('window_a') is not None else '—'} | {fmt_boot(row['boot'].get('owner'))} | "
                f"{money(row['ckpt_cost'])} | {money(row['stage_cost'])} | {verdict} |\n")
    print(f"decision: {verdict}" + (f" (Δ(a) {fmt_boot(row['boot'].get(MAIN))}, window {d['window_a']})"
                                     if history else ""))
    return d


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    f = sub.add_parser("freeze")
    f.add_argument("--exams", default=str(EXAMS))
    f.add_argument("--only", default=None, help="comma-separated exam names")
    f.add_argument("--public", default=str(PUBLIC), help="collector clips for the held-out exam")
    f.add_argument("--dev-pct", type=int, default=3, help="train_e2e.py --dev-pct")
    f.add_argument("--min-channels", type=int, default=20)
    f.add_argument("--min-clips", type=int, default=10)
    f.add_argument("--per-channel", type=int, default=40)
    f.add_argument("--muavic-min-share", type=float, default=0.7, help="share of selected segments that must be cut")
    f.add_argument("--muavic-min-speakers", type=int, default=12, help="of the 16 MuAViC valid+test speakers")
    f.add_argument("--limit", type=int, default=0, help="owner_voiced: first N clips only (tests)")
    r = sub.add_parser("run")
    r.add_argument("--ckpt", required=True, help="train_e2e.py best.pt, or 'base'")
    r.add_argument("--out", required=True)
    r.add_argument("--name", default=None)
    r.add_argument("--exams", default=str(EXAMS))
    r.add_argument("--device", default="auto")
    r.add_argument("--beam", type=int, default=BEAM)
    r.add_argument("--limit", type=int, default=0, help="first N clips per exam (smoke test; marked * in the table)")
    r.add_argument("--only", default=None, help="comma-separated exams to run (default: every frozen one)")
    c = sub.add_parser("record")
    c.add_argument("result")
    c.add_argument("--label", default=None)
    c.add_argument("--stage", type=int, default=None)
    c.add_argument("--clip-hours", type=float, default=None)
    c.add_argument("--ckpt-cost", type=float, default=None, help="$ of the trainer pod for this checkpoint")
    c.add_argument("--stage-cost", type=float, default=None, help="$ of the stage so far, collection + checkpoint")
    a = ap.parse_args()
    dict(freeze=cmd_freeze, run=cmd_run, record=cmd_record)[a.cmd](a)


if __name__ == "__main__":
    main()
