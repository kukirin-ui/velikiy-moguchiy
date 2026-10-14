#!/usr/bin/env python3
"""Selection lists of Russian audio-visual segments from dataset metadata only (no video is downloaded).

  .venv/bin/python extdata/selection.py

Writes per dataset data/ext/<dataset>/selection.jsonl, one row per segment:
  dataset, video_id, url, start, end (s), speaker, split, transcript (when the dataset has one), face_xy (AVSpeech:
  speaker's face centre, 0..1), face_box (MultiVSR: track box file), lang ("ru" known, "?" = language ID on the pod),
  license.
Segments whose metadata already shows no face, or a face under PRE_FACE_PX720, are left out (the pod applies the
strict rule). VoxCeleb2 has no face sizes in its metadata and keeps every candidate segment.
Also data/ext/youtube_queue.txt for harvester/mac_feeder.py: `url  # speaker  @start-end` per section, sections of
every dataset merged per video, most valuable dataset first (run the feeder with --forward).

Inputs (metadata, fetched once):
  muavic_ru    data/ext/muavic_ru/meta/ru-ru/data/<split>/txt/{segments,<split>.ru} (mTEDx-ru, OpenSLR 100),
               face_meta.jsonl (extdata/muavic_faces.py)
  multivsr_ru  data/public_meta/ru.jsonl (MultiVSR HF CSVs joined with its face tracks, fetch/build_selection.py)
               and data/public_meta/tracks/<video>.npz
  avspeech_ru  data/ext/avspeech_ru/meta/avspeech_{train,test}.csv; Russian videos = MultiVSR's Russian videos
               (MultiVSR's video ids are AVSpeech's; its language label is Whisper LID on the audio)
  voxceleb2_ru data/ext/voxceleb2_ru/meta/candidate_videos.jsonl: VoxCeleb2 speakers with post-Soviet citizenship
               (Wikidata), segments from vox2_metadata.parquet
"""
from __future__ import annotations

import collections
import csv
import json
import os
import random
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EXT = ROOT / "data" / "ext"
PUB = ROOT / "data" / "public"
LICENSE = {
    "muavic_ru": "mTEDx transcripts CC BY-NC-ND 4.0; MuAViC CC BY-NC 4.0; video (c) uploader",
    "multivsr_ru": "MultiVSR annotations MIT; video (c) uploader",
    "avspeech_ru": "AVSpeech metadata CC BY 4.0 (Google LLC); video (c) uploader",
    "voxceleb2_ru": "VoxCeleb2 metadata CC BY-SA 4.0; video (c) uploader",
}
ORDER = ["muavic_ru", "voxceleb2_ru", "avspeech_ru", "multivsr_ru"]
SECTION_GAP = 60.0  # segments closer than this share one downloaded section
PAD = 0.5
MIN_SEG, MAX_SEG = 1.0, 30.0
# metadata pre-filter, looser than the pod's close-up rule (S3FD face >= 120 px at 720p in >= 97% of frames) so that
# it only drops what can't pass
PRE_FACE_PX720 = 100.0
PRE_FACE_FRAC = 0.9
STD_H = (360, 480, 720, 1080, 1440, 2160)
# citizenships where Russian is the usual public language; the rest of the candidates rely on language ID alone
RU_LIKELY = {"Q159", "Q15180", "Q34266", "Q184", "Q232", "Q813", "Q212"}


def url(vid):
    return f"https://www.youtube.com/watch?v={vid}"


def overlaps(a, b, spans, frac=0.5):
    return any(min(b, y) - max(a, x) > frac * (b - a) for x, y in spans)


def public_spans():
    """{video: [(start, end)]} of the MultiVSR-ru clips already cut into data/public."""
    spans = collections.defaultdict(list)
    for name in os.listdir(PUB):
        if not name.endswith(".json"):
            continue
        try:
            d = json.loads((PUB / name).read_text())
        except (OSError, ValueError):
            continue
        if d.get("source") == "multivsr-ru":
            v = d["video_id"][3:] if d["video_id"].startswith("yt_") else d["video_id"]
            spans[v].append((d["start"], d["end"]))
    return spans


def video_height(max_x, max_y):
    """Smallest standard frame height that holds every box of a video (S3FD boxes overhang the edges a little)."""
    for h in STD_H:
        if max_y <= h * 1.05 and max_x <= h * 16 / 9 * 1.05:
            return h
    return STD_H[-1]


class Tracks:
    """MultiVSR face tracks (S3FD boxes in the source pixels) of one video at a time."""

    def __init__(self):
        self.vid, self.t, self.h = None, {}, 720

    def load(self, vid):
        import numpy as np
        if vid == self.vid:
            return
        self.vid, self.t = vid, {}
        p = ROOT / "data" / "public_meta" / "tracks" / f"{vid}.npz"
        if not p.exists():
            return
        z = np.load(p)
        mx = my = 0
        for k in z.files:
            if k.endswith("_bbox"):
                tr = k[:-5]
                b = z[k].astype(np.float32)
                self.t[tr] = (int(z[tr + "_frame0"]), b)
                mx, my = max(mx, b[:, 2].max()), max(my, b[:, 3].max())
        self.h = video_height(mx, my)

    def face(self, vid, f0, f1):
        """(share of frames f0..f1 inside one track, 3rd percentile of the face height in 720p pixels)."""
        import numpy as np
        self.load(vid)
        best = (0.0, 0.0)
        for start, b in self.t.values():
            a, z = max(f0, start), min(f1, start + len(b))
            if z <= a:
                continue
            hh = (b[a - start:z - start, 3] - b[a - start:z - start, 1]) * 720 / self.h
            cov = (z - a) / max(1, f1 - f0)
            if cov > best[0]:
                best = (cov, float(np.percentile(hh, 3)))
        return best


def muavic():
    """mTEDx-ru segments; MuAViC's own landmarks (extdata/muavic_faces.py, its 1280x720 downloads) drop the
    segments without a large enough face. Landmark height is ~0.85 of the S3FD box."""
    meta = {}
    for line in open(EXT / "muavic_ru" / "meta" / "face_meta.jsonl"):
        m = json.loads(line)
        meta[m["id"]] = m
    rows = []
    base = EXT / "muavic_ru" / "meta" / "ru-ru" / "data"
    for split in ("test", "valid", "train"):
        txt = base / split / "txt"
        segs = (txt / "segments").read_text().splitlines()
        texts = (txt / f"{split}.ru").read_text(encoding="utf8").splitlines()
        assert len(segs) == len(texts), split
        for line, text in zip(segs, texts):
            sid, vid, s, e = line.split()
            m = meta.get(sid)
            if not m or not m["frames"] or not m["face_h_med"]:
                continue
            px720 = m["face_h_med"] / 0.85 * (720 / video_height(m["video_max_x"], m["video_max_y"]))
            if m["with_face"] / m["frames"] < PRE_FACE_FRAC or px720 < PRE_FACE_PX720:
                continue
            rows.append(dict(video_id=vid, start=float(s), end=float(e), speaker=f"muavic:{vid}", split=split,
                             transcript=text, lang="ru", meta_face_px720=round(px720)))
    return rows


def multivsr(done, tracks):
    rows = []
    for line in open(ROOT / "data" / "public_meta" / "ru.jsonl"):
        c = json.loads(line)
        vid, s, e = c["video_id"], c["t_start"], c["t_end"]
        if overlaps(s, e, done.get(vid, ())):
            continue
        f0 = c["track_frame0"] + c["start"]
        cov, px = tracks.face(vid, f0, f0 + c["length"])
        if cov < PRE_FACE_FRAC or px < PRE_FACE_PX720:
            continue
        rows.append(dict(video_id=vid, start=s, end=e, speaker=None, split=c["split"], transcript=c["transcript"],
                         face_box=c["boxes"], track_frame0=f0, lang="ru", meta_face_px720_p3=round(px)))
    return rows


def avspeech(done, mv_rows, tracks):
    ru = {json.loads(line)["video_id"] for line in open(ROOT / "data" / "public_meta" / "ru.jsonl")}
    taken = collections.defaultdict(list)
    for r in mv_rows:
        taken[r["video_id"]].append((r["start"], r["end"]))
    rows = []
    for split in ("train", "test"):
        for vid, s, e, x, y in csv.reader(open(EXT / "avspeech_ru" / "meta" / f"avspeech_{split}.csv")):
            if vid not in ru:
                continue
            s, e = float(s), float(e)
            # MultiVSR covers the same videos with transcripts and face tracks: AVSpeech adds only what it misses
            if overlaps(s, e, done.get(vid, ())) or overlaps(s, e, taken.get(vid, ())):
                continue
            # MultiVSR tracked every face of these videos: no track here means no usable face
            cov, px = tracks.face(vid, int(s * 25), int(e * 25))
            if cov < PRE_FACE_FRAC or px < PRE_FACE_PX720:
                continue
            rows.append(dict(video_id=vid, start=s, end=e, speaker=None, split=split,
                             face_xy=[float(x), float(y)], lang="?", meta_face_px720_p3=round(px)))
    return rows


def voxceleb2():
    meta = EXT / "voxceleb2_ru" / "meta"
    sets = {r["voxceleb2_id"]: r for r in csv.DictReader(open(meta / "candidates_postsoviet.csv"))}
    cit = json.loads((meta / "wikidata_citizenship.json").read_text())
    rows = []
    for line in open(meta / "candidate_videos.jsonl"):
        r = json.loads(line)
        sp = sets[r["speaker_id"]]
        likely = bool(set(cit.get(sp["name"], ())) & RU_LIKELY)
        for a, b in r["segments"]:
            rows.append(dict(video_id=r["video_id"], start=a / 25, end=b / 25, speaker=f"vox2:{r['speaker_id']}",
                             split=sp["set"], lang="?", ru_likely=likely, src_quality=r["video_quality"]))
    return rows


def sections(rows):
    out = []
    for r in sorted(rows, key=lambda r: r["start"]):
        a, b = max(0.0, r["start"] - PAD), r["end"] + PAD
        if out and a - out[-1][1] < SECTION_GAP:
            out[-1][1] = max(out[-1][1], b)
        else:
            out.append([a, b])
    return out


def main():
    done = public_spans()
    tracks = Tracks()
    sel = {"muavic_ru": muavic(), "multivsr_ru": multivsr(done, tracks), "voxceleb2_ru": voxceleb2()}
    sel["avspeech_ru"] = avspeech(done, sel["multivsr_ru"], tracks)
    stats = {}
    for ds, rows in sel.items():
        rows = [r for r in rows if MIN_SEG <= r["end"] - r["start"] <= MAX_SEG]
        sel[ds] = rows
        (EXT / ds).mkdir(parents=True, exist_ok=True)
        with open(EXT / ds / "selection.jsonl", "w") as f:
            for r in rows:
                f.write(json.dumps(dict(dataset=ds, url=url(r["video_id"]), license=LICENSE[ds], **r),
                                   ensure_ascii=False) + "\n")
        hours = sum(r["end"] - r["start"] for r in rows) / 3600
        spk = {r["speaker"] for r in rows if r["speaker"]}
        stats[ds] = dict(segments=len(rows), videos=len({r["video_id"] for r in rows}), hours=round(hours, 1),
                         speakers=len(spk) or None,
                         by_split={k: round(sum(r["end"] - r["start"] for r in rows if r["split"] == k) / 3600, 1)
                                   for k in sorted({r["split"] for r in rows})})
        if ds == "voxceleb2_ru":
            lk = [r for r in rows if r["ru_likely"]]
            stats[ds]["ru_likely_hours"] = round(sum(r["end"] - r["start"] for r in lk) / 3600, 1)
            stats[ds]["ru_likely_speakers"] = len({r["speaker"] for r in lk})

    # one queue for the Mac feeder: each video once, its sections from every dataset merged
    by_vid = collections.OrderedDict()
    for ds in ORDER:
        order = list(dict.fromkeys(r["video_id"] for r in sel[ds]))
        if ds in ("multivsr_ru", "avspeech_ru"):  # any prefix of the queue then spans many channels (R1)
            random.Random(0).shuffle(order)
        rank = {v: i for i, v in enumerate(order)}
        for r in sorted(sel[ds], key=lambda r: rank[r["video_id"]]):
            v = by_vid.setdefault(r["video_id"], {"speaker": r["speaker"], "rows": []})
            v["rows"].append(r)
            v["speaker"] = v["speaker"] or r["speaker"]
    lines, sec_total = [], 0.0
    for vid, v in by_vid.items():
        for a, b in sections(v["rows"]):
            lines.append(f"{url(vid)}  # {v['speaker'] or '?'}  @{a:.2f}-{b:.2f}")
            sec_total += b - a
    (EXT / "youtube_queue.txt").write_text("\n".join(lines) + "\n")
    stats["youtube_queue"] = dict(sections=len(lines), videos=len(by_vid), hours_to_download=round(sec_total / 3600, 1))
    (EXT / "selection_stats.json").write_text(json.dumps(stats, indent=1, ensure_ascii=False))
    print(json.dumps(stats, indent=1, ensure_ascii=False))


if __name__ == "__main__":
    main()
