#!/usr/bin/env python3
"""Pod side of the external datasets: cuts dataset segments out of the sections the Mac feeder ships.

  python3 extdata/pod_segments.py --inbox /root/newdata/inbox_seg --ext /root/lr/data/ext [--procs 6]

Needs on the pod: the repo (newdata/, facecrop.py, extdata/), data/ext/<dataset>/selection.jsonl from the Mac,
newdata/gpu_server.py serving SyncNet and GigaAM, and for language ID speechbrain (extdata/pod_requirements.txt).

An inbox item is yt_<video>__s<section start ms>.mp4 (+ .info.json), cut by mac_feeder from a data/ext/youtube_queue.txt
line. For every selected segment inside it, in order:
  lang      VoxLingua107 says Russian (only datasets without a known language: AVSpeech, VoxCeleb2)
  shots     segments labelled by GigaAM are split at camera cuts and face gaps into parts >= 2 s; a segment with a
            dataset transcript is rejected instead, since its text can't be split
  close_up  the S3FD-equivalent face is >= 120 px at 720p (scaled to the source height) in >= 97% of frames, then
            newdata/collect.py seg_arrays_ok: no gap or face jump, yaw p90 <= 0.30, a second face in <= 10% of frames,
            sharpness
  sync      SyncNet conf and offset within newdata/rv_collect.py RTH (rv_thresholds.json)
  text      dataset transcript (GigaAM output kept as asr_raw with label_cer), or GigaAM with the collector's word
            rate and noise-tag checks
and writes <ext>/<dataset>/<split>/yt_<video>__<start ms>.{mp4,txt,json} (face crop from the source frames through
facecrop.py, json last) or one line in <ext>/<dataset>/rejects.jsonl. The section file is deleted afterwards.
Stop: touch <inbox>/STOP.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import traceback
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(ROOT / "newdata"))
sys.path.insert(0, str(ROOT))

FPS, SR = 25, 16000
CLOSE_UP_PX_720 = 120.0
CLOSE_UP_FRAC = 0.97
EXAM_SPLITS = ("valid", "test", "val_major")
EXAM_FACE_PX_720 = 60.0
EXAM_FACE_FRAC = 0.85
MIN_PART = 2 * FPS
P_RU = 0.5
TEXT_SOURCE = {"muavic_ru": "human (mTEDx)", "multivsr_ru": "MultiVSR (WhisperX large-v3)"}


def load_selection(ext: Path) -> dict:
    """{video: [row]} over every data/ext/<dataset>/selection.jsonl."""
    by = {}
    for sel in sorted(ext.glob("*/selection.jsonl")):
        for line in open(sel, encoding="utf8"):
            r = json.loads(line)
            by.setdefault(r["video_id"], []).append(r)
    return by


def parse_name(stem: str):
    """yt_<video>__s<section start ms> (harvester/mac_feeder.job_stem) -> (video, start s)."""
    vid, _, ms = stem.removeprefix("yt_").rpartition("__")
    return vid, int(ms.removeprefix("s")) / 1000


def shot_parts(o, n, min_len=MIN_PART):
    """Frame ranges of one continuous face: split where the face jumps (a cut) or is missing for > 3 frames."""
    face = o["face"][:n] > 0
    bad = np.zeros(n, bool)
    miss = np.flatnonzero(~face)
    if len(miss):
        for run in np.split(miss, np.flatnonzero(np.diff(miss) > 1) + 1):
            if len(run) > 3:
                bad[run] = True
    cuts = set(np.flatnonzero(o["jump"][:n] > 0).tolist())
    parts, a = [], None
    for i in range(n + 1):
        if i == n or bad[i] or i in cuts:
            if a is not None and i - a >= min_len:
                parts.append((a, i))
            a = None if i == n or bad[i] else i
        elif a is None:
            a = i
    return parts


def close_up(o, a, b, ky, scale_to_src, src_h, collect, exam=False):
    """None if the face is a frontal single close-up, else the reason. o is FaceFeat rows of the decoded frames;
    scale_to_src converts their pixels to the source frame's. Exam segments (TEDx stage shots that cut between close
    and wide views) only need a visible face in most frames: every model sits the same exam, so a harder exam is
    fair, while the training filter would leave too few exam speakers to compare on."""
    fh_src = o["fh"][a:b] * ky * scale_to_src * (o["face"][a:b] > 0)
    if exam:
        return None if (fh_src >= EXAM_FACE_PX_720 * src_h / 720).mean() >= EXAM_FACE_FRAC else "exam_no_face"
    need = CLOSE_UP_PX_720 * src_h / 720
    if (fh_src >= need).mean() < CLOSE_UP_FRAC:
        return "not_close_up"
    return collect.seg_arrays_ok(o, a, b, ky)


class Deps:
    """Everything that touches video, models or the GPU server; tests replace it."""

    def __init__(self):
        import collect
        import gpu_server as G
        import rv_collect
        import vision as V
        rv_collect.load_thresholds()
        self.collect, self.V, self.G, self.RTH = collect, V, G, rv_collect.RTH
        assert collect.TH["seg_yaw_p90"] <= 0.30 and collect.TH["seg_second_max"] <= 0.10
        assert self.RTH["seg_conf_min"] >= 3.0
        self.cl = G.Client()
        self._lid = None
        self.ky = V.load_calib()["box"]["ky"]

    def dims(self, path):
        return self.V._dims(path)

    def audio(self, path):
        return self.V.decode_audio(path)

    def frames(self, path, ss, t, out_h):
        """RGB frames at 25 fps."""
        return self.V.decode_frames(path, ss, t, out_h=out_h)

    def features(self, frames_rgb):
        return self.V.analyze_frames(frames_rgb)

    def sxy(self, o, a, b):
        return self.V.s3fd_like_track(o, slice(a, b))

    def crop(self, frames_bgr, sxy):
        return self.V.crop_clip(frames_bgr, sxy)

    def write_mp4(self, arr, dst):
        self.V.write_mp4(arr, dst)

    def sync(self, crops_bgr, audio):
        return self.cl.sync(crops_bgr, self.G.mfcc_of(audio))

    def sync_ok(self, r):
        return (r is not None and r["conf"] >= self.RTH["seg_conf_min"]
                and abs(r["offset"] - self.RTH["off_center"]) <= self.RTH["off_tol"])

    def asr(self, audio):
        return self.cl.asr(audio)

    def lid(self, audio):
        if self._lid is None:
            import torch
            from speechbrain.inference.classifiers import EncoderClassifier
            m = EncoderClassifier.from_hparams(source="speechbrain/lang-id-voxlingua107-ecapa",
                                               savedir=str(Path.home() / ".cache" / "sb_voxlingua107"))
            labels = [None] * len(m.hparams.label_encoder.lab2ind)
            for lab, i in m.hparams.label_encoder.lab2ind.items():
                labels[i] = lab.split(":")[0]
            self._lid = (torch, m, labels)
        torch, m, labels = self._lid
        with torch.no_grad():
            p = torch.softmax(m.classify_batch(torch.from_numpy(audio[None].astype(np.float32)))[0][0], -1)
        return float(p[labels.index("ru")]), labels[int(p.argmax())]

    def label_text(self, text):
        return self.collect.label_text(text)

    def words(self, text):
        import textnorm
        return textnorm.words(text)

    def noise(self, text):
        import textnorm
        return textnorm.has_noise_tag(text)


def process_section(path: Path, rows: list, ext: Path, d) -> dict:
    """Cuts the selected segments inside one section file. Returns {"kept": n, "sec": s, "rejected": {reason: n}}."""
    vid, s0 = parse_name(path.stem)
    w, h = d.dims(path)
    h360 = 360 if w >= h else int(round(360 * h / w / 2) * 2)
    audio = d.audio(path)
    s1 = s0 + len(audio) / SR
    channel = None
    info = path.with_name(f"{path.stem}.info.json")
    if info.exists():
        try:
            j = json.loads(info.read_text())
            channel = j.get("channel_id") or j.get("uploader_id") or j.get("channel")
        except (OSError, ValueError):
            pass
    out = {"kept": 0, "sec": 0.0, "rejected": {}}

    def reject(r, a, b, why, **extra):
        out["rejected"][why] = out["rejected"].get(why, 0) + 1
        with open(ext / r["dataset"] / "rejects.jsonl", "a") as f:
            f.write(json.dumps(dict(video_id=vid, start=round(a, 3), end=round(b, 3), reason=why, **extra)) + "\n")

    for r in sorted(rows, key=lambda r: r["start"]):
        if r["start"] < s0 - 0.05 or r["end"] > s1 + 0.05:
            continue  # belongs to another section of this video
        ds = r["dataset"]
        a_s, b_s = r["start"] - s0, r["end"] - s0
        seg_audio = audio[int(a_s * SR):int(b_s * SR)]
        if len(seg_audio) < SR:
            reject(r, r["start"], r["end"], "no_audio")
            continue
        p_ru = None
        if r.get("lang") != "ru":
            p_ru, top = d.lid(seg_audio)
            if top != "ru" or p_ru < P_RU:
                reject(r, r["start"], r["end"], "not_russian", lang=top)
                continue
        frames = d.frames(path, a_s, b_s - a_s, h360)
        n = len(frames)
        if n < MIN_PART:
            reject(r, r["start"], r["end"], "short")
            continue
        o = d.features(frames)
        has_text = r.get("transcript") is not None
        parts = [(0, n)] if has_text else shot_parts(o, n)
        if not parts:
            reject(r, r["start"], r["end"], "face_gap_or_cut")
            continue
        for a, b in parts:
            if not has_text:
                o["jump"][a] = 0  # the cut that opens this part is its first frame, not a jump inside it
            t0, t1 = r["start"] + a / FPS, r["start"] + b / FPS
            why = close_up(o, a, b, d.ky, h / h360, h, d.collect, exam=r["split"] in EXAM_SPLITS)
            if why:
                reject(r, t0, t1, why)
                continue
            sxy = d.sxy(o, a, b)
            pa = seg_audio[int(a / FPS * SR):int(b / FPS * SR)]
            sync = d.sync(d.crop(np.ascontiguousarray(frames[a:b][..., ::-1]), sxy), pa)
            if not d.sync_ok(sync):
                reject(r, t0, t1, "sync", conf=None if sync is None else round(sync["conf"], 2))
                continue
            asr = d.asr(pa)
            meta = dict(video_id=f"yt_{vid}", speaker=r.get("speaker") or channel or f"yt:{vid}", start=round(t0, 3),
                        end=round(t1, 3), frames=b - a, source=ds, split=r["split"], url=r["url"],
                        license=r["license"], src_height=h, asr_raw=asr,
                        scores={"sync_conf": round(sync["conf"], 2), "sync_offset": sync["offset"],
                                "face_h_p10_src": round(float(np.percentile(o["fh"][a:b] * d.ky * h / h360, 10)), 1),
                                "yaw_p90": round(float(np.percentile(o["yaw"][a:b], 90)), 3)})
            if r["split"] in EXAM_SPLITS:
                meta["face_filter"] = "exam"
            if p_ru is not None:
                meta["p_ru"] = round(p_ru, 3)
            if has_text:
                text = d.label_text(r["transcript"])
                meta.update(text_source=TEXT_SOURCE.get(ds, ds), text_raw=r["transcript"])
                hyp = d.label_text(asr)
                import textnorm
                meta["label_cer"] = round(min(1.0, textnorm.edit_distance(list(text), list(hyp)) / max(1, len(text))), 4)
            else:
                ws = d.words(asr)
                if len(ws) < d.collect.TH["words_min"]:
                    reject(r, t0, t1, "asr_empty")
                    continue
                if not d.collect.TH["wps_seg_min"] <= len(ws) / (t1 - t0) <= d.collect.TH["wps_seg_max"]:
                    reject(r, t0, t1, "wps")
                    continue
                if d.noise(asr):
                    reject(r, t0, t1, "noise_tag")
                    continue
                text = d.label_text(asr)
                meta["text_source"] = "GigaAM v3 RNNT"
            # the crop itself comes from the source frames: sharper than the 360p ones the checks used
            src = d.frames(path, t0 - s0, (b - a) / FPS, h)
            if len(src) < b - a:
                src = np.concatenate([src, np.repeat(src[-1:], b - a - len(src), 0)])
            arr = d.crop(np.ascontiguousarray(src[:b - a][..., ::-1]), sxy * (h / h360))
            dst = ext / ds / r["split"]
            dst.mkdir(parents=True, exist_ok=True)
            name = f"yt_{vid}__{int(round(t0 * 1000)):08d}"
            d.write_mp4(arr, dst / f"{name}.mp4")
            (dst / f"{name}.txt").write_text(text + "\n", encoding="utf8")
            tmp = dst / f"{name}.json.tmp"
            tmp.write_text(json.dumps(meta, ensure_ascii=False))
            os.replace(tmp, dst / f"{name}.json")
            out["kept"] += 1
            out["sec"] += (b - a) / FPS
    return out


def take(inbox: Path):
    wk = inbox / ".work"
    wk.mkdir(exist_ok=True)
    for f in sorted(inbox.glob("*.mp4")):
        try:
            os.rename(f, wk / f.name)
        except FileNotFoundError:
            continue
        try:
            os.rename(inbox / f"{f.stem}.info.json", wk / f"{f.stem}.info.json")
        except FileNotFoundError:
            pass
        return wk / f.name
    return None


def worker(inbox: Path, ext: Path, sel: dict):
    os.nice(5)
    d = None
    log = open(ext / "pod_segments.log", "a")
    failed = inbox / ".failed"
    failed.mkdir(exist_ok=True)
    while not (inbox / "STOP").exists():
        if d is None:
            try:
                d = Deps()
            except (ConnectionError, EOFError, OSError):  # the GPU servers are (re)starting
                time.sleep(10)
                continue
        path = take(inbox)
        if path is None:
            time.sleep(5)
            continue
        info = path.with_name(f"{path.stem}.info.json")
        vid, s0 = parse_name(path.stem)
        try:
            res = process_section(path, sel.get(vid, []), ext, d)
            log.write(f"{time.strftime('%F %T')} {path.name}: kept {res['kept']} ({res['sec']:.0f} s), "
                      f"rejected {res['rejected']}\n")
            path.unlink(missing_ok=True)
            info.unlink(missing_ok=True)
        except (ConnectionError, EOFError, BrokenPipeError) as e:
            # a restarted GPU server is not the section's fault: back to the queue, new connection
            log.write(f"{time.strftime('%F %T')} {path.name}: GPU server lost ({type(e).__name__}), requeued\n")
            for f in (path, info):
                if f.exists():
                    os.rename(f, inbox / f.name)
            d = None
        except Exception as e:  # noqa: BLE001  one bad file must not stop the worker
            log.write(f"{time.strftime('%F %T')} {path.name}: ERROR {type(e).__name__}: {e} "
                      f"{traceback.format_exc()[-300:]}\n")
            for f in (path, info):
                if f.exists():
                    os.rename(f, failed / f.name)
        log.flush()

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--inbox", default="/root/newdata/inbox_seg")
    ap.add_argument("--ext", default="/root/lr/data/ext")
    ap.add_argument("--procs", type=int, default=6)
    a = ap.parse_args()
    import multiprocessing as mp
    inbox, ext = Path(a.inbox), Path(a.ext)
    inbox.mkdir(parents=True, exist_ok=True)
    for f in (inbox / ".work").glob("*"):  # a killed run's claims go back to the queue
        os.rename(f, inbox / f.name)
    sel = load_selection(ext)
    procs = [mp.Process(target=worker, args=(inbox, ext, sel)) for _ in range(a.procs)]
    for p in procs:
        p.start()
    for p in procs:
        p.join()


if __name__ == "__main__":
    main()
