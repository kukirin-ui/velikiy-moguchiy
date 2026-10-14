#!/usr/bin/env python3
"""Per-channel quality of the collection, and pruning of channels that do not pay for their downloads.

  python3 harvester/channel_quality.py [--no-prune]        (the supervisor runs it after every pull)

Reads only what is already on the Mac:
  data/public_pod/_pod_<pod>_rv_videos.jsonl   the collector's outcome per video (rv_state.db, dumped by every pull)
  data/public_pod/*.json + *.txt               clips: length, source height, SyncNet confidence, GigaAM text
  harvester/autosubs/<id>.ru.vtt               YouTube auto-subs the feeder saved for a few videos per channel
Writes harvester/channel_quality.json. Channel = the queue label the feeder shipped the video under
(harvester/feeder_channels.tsv, then the queue files), else the YouTube channel id (video_channels.tsv).

Pruning: a channel with PRUNE_MIN_VIDEOS processed videos whose yield (clip hours / video hours) is below
PRUNE_YIELD is appended to harvester/channel_skip.txt; mac_feeder.py stops downloading it. Every prune goes to
harvester/prune.log with the numbers behind it. Delete the line from channel_skip.txt to undo.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
MIRROR = ROOT / "data" / "public_pod"
OUT = HERE / "channel_quality.json"
CACHE = HERE / "clip_stats_cache.json"
SKIP = HERE / "channel_skip.txt"
PRUNE_LOG = HERE / "prune.log"
FEEDER_CHANNELS = HERE / "feeder_channels.tsv"
VIDEO_CHANNELS = HERE / "video_channels.tsv"
LEDGER = HERE / "channel_seconds.json"
AUTOSUBS = HERE / "autosubs"
QUEUES = [ROOT / "newdata" / "manual_order_mac.txt"] + sorted((ROOT / "newdata").glob("queue_diverse*.txt"))
PRUNE_MIN_VIDEOS = 3
PRUNE_YIELD = 0.10
# buckets of many speakers, not one channel: never pruned as a whole
NO_PRUNE = {"?", "manual"}
KEEP = HERE / "channel_keep.txt"  # same format as channel_skip.txt; channels kept on purpose (the pilot's narrow arm)
TOP_REASONS = 5
SYNC_LOW = 3.0

sys.path.insert(0, str(ROOT))
import metrics  # noqa: E402


def vid_of(stem: str) -> str:
    v = stem.split("__", 1)[0]
    return v[3:] if v.startswith("yt_") else v


def channel_lookup() -> dict:
    out = {}
    if VIDEO_CHANNELS.exists():
        for line in VIDEO_CHANNELS.read_text().splitlines():
            v, _, c = line.partition("\t")
            if v and c:
                out[v] = c
    for q in QUEUES:
        if q.exists():
            for line in q.read_text().splitlines():
                url, _, ch = line.partition("#")
                if "watch?v=" in url and ch.strip():
                    out[url.strip().rsplit("=", 1)[-1]] = ch.strip()
    if FEEDER_CHANNELS.exists():
        for line in FEEDER_CHANNELS.read_text().splitlines():
            v, _, c = line.partition("\t")
            if v and c:
                out[v] = c
    return out


def collector_records(mirror: Path) -> dict:
    """video id -> the latest collector record for it across all pods' dumps."""
    recs = {}
    for f in sorted(mirror.glob("_pod_*_rv_videos.jsonl")):
        for line in f.read_text().splitlines():
            try:
                r = json.loads(line)
            except ValueError:
                continue
            v = vid_of(r["video_id"])
            if v not in recs or (r.get("updated") or 0) >= (recs[v].get("updated") or 0):
                recs[v] = r
    return recs


def clip_stats(mirror: Path, cache_path: Path, subs_dir: Path) -> dict:
    """video id -> clip totals from the clip json files. A video is re-read only when its clip count changes or its
    auto-subs arrive, so a pull of a few thousand clips costs a directory listing plus those files."""
    try:
        cache = json.loads(cache_path.read_text())
    except (OSError, ValueError):
        cache = {}
    names = {}
    with os.scandir(mirror) as it:
        for e in it:
            n = e.name
            if n.endswith(".json") and not n.startswith("_") and not n.endswith(".tmp.json") and "__" in n:
                names.setdefault(vid_of(n[:-5]), []).append(n)
    for v, files in names.items():
        has_subs = (subs_dir / f"{v}.ru.vtt").exists()
        old = cache.get(v, {})
        if old.get("n") == len(files) and ("label" in old or not has_subs):
            continue
        s = dict(n=len(files), clips=0, sec=0.0, h={}, sync_sum=0.0, sync_n=0, sync_low=0)
        spans = []
        for n in files:
            try:
                m = json.loads((mirror / n).read_text())
            except (OSError, ValueError):
                continue
            s["clips"] += 1
            s["sec"] += (m.get("frames") or 0) / 25
            h = str(m.get("src_height") or "?")
            s["h"][h] = s["h"].get(h, 0) + 1
            sc = (m.get("scores") or {}).get("sync_conf")
            if sc is not None:
                s["sync_sum"] += sc
                s["sync_n"] += 1
                s["sync_low"] += sc < SYNC_LOW
            if m.get("start") is not None and m.get("end") is not None:
                spans.append((n[:-5], m["start"], m["end"]))
        if has_subs:
            s["label"] = label_check(v, spans, mirror, subs_dir)
        cache[v] = s
    cache_path.parent.mkdir(parents=True, exist_ok=True)
    tmp = cache_path.with_suffix(".tmp")
    tmp.write_text(json.dumps(cache))
    tmp.replace(cache_path)
    return cache


def _secs(ts: str) -> float:
    h, m, s = ts.strip().split()[0].split(":")
    return int(h) * 3600 + int(m) * 60 + float(s)


def vtt_words(text: str) -> list:
    """(start second, word) from a YouTube auto-sub .vtt. Auto-subs repeat the previous line in every cue; only the
    lines with per-word <hh:mm:ss.mmm> tags carry new words, so those are read when the file has them. Cues are cut at
    their "-->" lines, not at blank lines: auto-sub cues contain lines of a single space."""
    tagged = "<c>" in text
    cues = []
    for line in text.splitlines():
        if "-->" in line:
            a, b = line.split("-->")[:2]
            cues.append((_secs(a), _secs(b), []))
        elif cues and line.strip():
            cues[-1][2].append(line)
    words = []
    for t0, t1, body in cues:
        if tagged:
            for line in body:
                if "<" not in line:
                    continue
                t = t0
                for m in re.finditer(r"<(\d+:\d\d:\d\d\.\d+)>|([^<]+)", re.sub(r"</?c[^>]*>", "", line)):
                    if m.group(1):
                        t = _secs(m.group(1))
                    else:
                        words += [(t, w) for w in m.group(2).split()]
        else:
            ws = " ".join(re.sub(r"<[^>]+>", "", x) for x in body).split()
            words += [(t0 + (t1 - t0) * i / max(1, len(ws)), w) for i, w in enumerate(ws)]
    return words


def label_check(vid: str, spans: list, mirror: Path, subs_dir: Path):
    """(word errors, reference words) of the clip texts against the auto-subs over the same time spans."""
    vtt = subs_dir / f"{vid}.ru.vtt"
    words = vtt_words(vtt.read_text(encoding="utf8", errors="replace"))
    if not words:
        return None
    err = n = 0
    for stem, start, end in spans:
        txt = mirror / f"{stem}.txt"
        if not txt.exists():
            continue
        ref = " ".join(w for t, w in words if start - 0.3 <= t < end)
        if not ref:
            continue
        e, k = metrics.wer_counts(metrics.normalize_loose(ref), metrics.normalize_loose(txt.read_text(encoding="utf8")))
        err, n = err + e, n + k
    return (err, n) if n else None


def read_skip(path: Path = None) -> dict:
    """channel -> the reason written next to it."""
    path = path or SKIP
    out = {}
    if path.exists():
        for line in path.read_text().splitlines():
            ch, _, why = line.partition("#")
            if ch.strip():
                out[ch.strip()] = why.strip()
    return out


def build(mirror: Path = None) -> dict:
    mirror, cache_path, subs_dir = mirror or MIRROR, CACHE, AUTOSUBS
    chan = channel_lookup()
    recs = collector_records(mirror)
    clips = clip_stats(mirror, cache_path, subs_dir)
    ledger = json.loads(LEDGER.read_text()) if LEDGER.exists() else {}
    rows = {}

    def row(ch):
        return rows.setdefault(ch, dict(videos_done=0, videos_failed=0, videos_rejected=0, video_sec=0.0,
                                        collector_clip_sec=0.0, clips=0, clip_sec=0.0, reasons={}, segments=0,
                                        h={}, sync_sum=0.0, sync_n=0, sync_low=0, label_err=0, label_words=0,
                                        label_videos=0))

    for v, r in recs.items():
        x = row(chan.get(v, "?"))
        st = (json.loads(r["probe"]) if r.get("probe") else {}).get("video") or {}
        if r["status"] == "done":
            x["videos_done"] += 1
            x["video_sec"] += r.get("dur") or st.get("dur") or 0
            x["collector_clip_sec"] += r.get("clip_sec") or 0
            x["segments"] += st.get("n_seg") or 0
            for k, n in (st.get("seg_face_rej") or {}).items():
                x["reasons"]["face:" + k] = x["reasons"].get("face:" + k, 0) + n
            for k, n in (st.get("s8_drops") or {}).items():
                x["reasons"][k] = x["reasons"].get(k, 0) + n
        elif r["status"] == "failed":
            x["videos_failed"] += 1
        else:
            x["videos_rejected"] += 1
            k = "video:" + str(r.get("reason") or r.get("stage"))
            x["reasons"][k] = x["reasons"].get(k, 0) + 1
    total_sec = 0.0
    for v, s in clips.items():
        x = row(chan.get(v, "?"))
        total_sec += s["sec"]
        x["clips"] += s["clips"]
        x["clip_sec"] += s["sec"]
        for h, n in s["h"].items():
            x["h"][h] = x["h"].get(h, 0) + n
        for k in ("sync_sum", "sync_n", "sync_low"):
            x[k] += s[k]
        lc = s.get("label")
        if lc:
            x["label_err"] += lc[0]
            x["label_words"] += lc[1]
            x["label_videos"] += 1

    out = {}
    for ch, x in sorted(rows.items()):
        if x["videos_done"]:
            basis, vsec, csec = "collector", x["video_sec"], x["collector_clip_sec"]
        elif ledger.get(ch):
            basis, vsec, csec = "ledger", ledger[ch], x["clip_sec"]
        else:
            basis, vsec, csec = None, 0.0, x["clip_sec"]
        seg = x["segments"] or 1
        reasons = sorted(x["reasons"].items(), key=lambda kv: -kv[1])[:TOP_REASONS]
        nh = sum(x["h"].values()) or 1
        out[ch] = {
            "videos_done": x["videos_done"], "videos_failed": x["videos_failed"],
            "videos_rejected": x["videos_rejected"], "video_hours": round(vsec / 3600, 2),
            "clip_hours": round(csec / 3600, 2), "yield": round(csec / vsec, 3) if vsec else None, "basis": basis,
            "clips": x["clips"], "top_rejections": [[k, n, round(n / seg, 3)] for k, n in reasons],
            "src_height": {h: round(n / nh, 3) for h, n in sorted(x["h"].items())},
            "sync_conf_mean": round(x["sync_sum"] / x["sync_n"], 2) if x["sync_n"] else None,
            "sync_below_3": round(x["sync_low"] / x["sync_n"], 3) if x["sync_n"] else None,
            "label_wer": round(x["label_err"] / x["label_words"], 3) if x["label_words"] else None,
            "label_words": x["label_words"], "label_videos": x["label_videos"]}
    lw = sum(x["label_words"] for x in rows.values())
    return dict(updated=time.strftime("%F %T"), total_clip_hours=round(total_sec / 3600, 2),
                collector_videos=len(recs), channels_seen=len(out),
                label_wer=round(sum(x["label_err"] for x in rows.values()) / lw, 3) if lw else None,
                prune_rule=f">= {PRUNE_MIN_VIDEOS} processed videos and yield < {PRUNE_YIELD:.0%}", channels=out)


def prune(report: dict) -> list:
    """Appends channels that fail the rule to the skip list; returns the log lines of the new prunes."""
    skip_path, log_path = SKIP, PRUNE_LOG
    have = read_skip(skip_path)
    keep = read_skip(KEEP) if KEEP.exists() else {}
    new = []
    for ch, r in report["channels"].items():
        if ch in have or ch in NO_PRUNE or ch in keep or r["basis"] != "collector":
            continue
        if r["videos_done"] >= PRUNE_MIN_VIDEOS and r["yield"] is not None and r["yield"] < PRUNE_YIELD:
            top = ", ".join(f"{k} {s:.0%}" for k, _, s in r["top_rejections"][:2]) or "no rejection data"
            why = (f"yield {r['yield']:.1%} over {r['videos_done']} videos ({r['video_hours']} h video -> "
                   f"{r['clip_hours']} h clips); top rejections: {top}")
            new.append((ch, why))
    if new:
        stamp = time.strftime("%F %T")
        with open(skip_path, "a") as f:
            for ch, why in new:
                f.write(f"{ch}  # {stamp} {why}\n")
        with open(log_path, "a") as f:
            for ch, why in new:
                f.write(f"{stamp} pruned {ch}: {why}\n")
    for ch, r in report["channels"].items():
        if ch in have or any(ch == c for c, _ in new):
            r["pruned"] = True
    return [f"pruned {ch}: {why}" for ch, why in new]


def update(do_prune: bool = True) -> list:
    out = OUT
    report = build()
    lines = prune(report) if do_prune else []
    tmp = out.with_suffix(".tmp")
    tmp.write_text(json.dumps(report, ensure_ascii=False, indent=1))
    tmp.replace(out)
    return lines


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--no-prune", action="store_true", help="write the report only")
    a = ap.parse_args()
    for line in update(not a.no_prune):
        print(line)
    r = json.loads(OUT.read_text())
    print(f"{r['channels_seen']} channels, {r['collector_videos']} collector videos, {r['total_clip_hours']} h of clips, "
          f"label WER vs auto-subs {r['label_wer']} -> {OUT}")


if __name__ == "__main__":
    main()
