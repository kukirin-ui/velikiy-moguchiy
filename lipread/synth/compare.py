"""Side by side of talking-face generators on the same speech and face: MuseTalk (synth/gen.py) against DashScope
outputs (synth/dashscope_gen.py). DashScope videos are portraits, so they are first framed like the trainer's
clips: 25 fps, S3FD box per frame, facecrop.py crop to 224x224 (NAME.mp4/.txt/.json next to MuseTalk's format).

Per clip and generator: SyncNet with the clip's own speech and with another clip's speech (newdata/gpu_server.py),
lip gap and mouth width over time in the 96x96 window mvsr.read_faces sees (FaceMesh, as in results/framing),
and a strip of the 96x96 window for the eye.

  python synth/compare.py --clip synth_golos_196dd81918d0 --clip ... --out results/synth/dashscope
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

import cv2
import numpy as np
import soundfile as sf

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "newdata"))
sys.path.insert(0, str(ROOT / "synth"))
import facecrop  # noqa: E402
from check import read_frames  # noqa: E402

DS = ROOT / "data" / "synth" / "dashscope"


def to25(src: Path) -> np.ndarray:
    """Frames resampled to 25 fps by ffmpeg's fps filter (wan2.2-s2v gives 16 fps: frames repeat, as a 16 fps
    camera clip would after the collector's own -r 25)."""
    with tempfile.TemporaryDirectory() as d:
        dst = Path(d) / "v.mp4"
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(src), "-an", "-vf", "fps=25", "-c:v", "libx264",
                        "-crf", "12", str(dst)], check=True)
        return read_frames(dst)


_DET = None


def frame_crop(frames: np.ndarray) -> np.ndarray:
    """preprocess.py's framing for a single-face video: S3FD box every frame, smoothed, facecrop.crop_frames."""
    global _DET
    if _DET is None:
        sys.path.insert(0, str(ROOT / "multivsr" / "preprocess"))
        from detectors import S3FD  # type: ignore
        _DET = S3FD(device="cpu")
    boxes, last = [], None
    for f in frames:
        b = _DET.detect_faces(cv2.cvtColor(f, cv2.COLOR_BGR2RGB), conf_th=0.9, scales=[0.5])
        if len(b):
            last = max(b, key=lambda x: (x[2] - x[0]) * (x[3] - x[1]))[:4]
        boxes.append(last)
    first = next(b for b in boxes if b is not None)
    boxes = [first if b is None else b for b in boxes]
    return facecrop.crop_frames(frames, facecrop.boxes_to_sxy(boxes))


def write_mp4(frames: np.ndarray, dst: Path):
    h, w = frames.shape[1:3]
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "bgr24", "-s", f"{w}x{h}", "-r", "25",
                    "-i", "-", "-c:v", "libx264", "-preset", "veryfast", "-crf", "18", "-pix_fmt", "yuv420p", str(dst)],
                   input=frames.tobytes(), check=True)


def window96(f):
    return cv2.resize(f, (160, 160))[32:128, 32:128]


_FM = None


def lip_stats(frames) -> dict:
    global _FM
    import mediapipe as mp
    if _FM is None:
        _FM = mp.solutions.face_mesh.FaceMesh(static_image_mode=False, max_num_faces=1)
    gap, wid = [], []
    for f in frames:
        r = _FM.process(cv2.cvtColor(cv2.resize(window96(f), (384, 384)), cv2.COLOR_BGR2RGB))
        if r.multi_face_landmarks:
            lm = np.array([(p.x * 96, p.y * 96) for p in r.multi_face_landmarks[0].landmark])
            gap.append(lm[14, 1] - lm[13, 1])
            wid.append(lm[291, 0] - lm[61, 0])
    g, w = np.array(gap), np.array(wid)
    return dict(lip_gap_mean=round(float(g.mean()), 2), lip_gap_p90_p10=round(float(np.percentile(g, 90) -
                np.percentile(g, 10)), 2), mouth_width_std=round(float(w.std()), 2), n=len(g))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--clip", action="append", required=True)
    ap.add_argument("--pilot", default=str(ROOT / "data" / "synth" / "pilot"))
    ap.add_argument("--wav", default=str(ROOT / "data" / "synth" / "pilot_wav"))
    ap.add_argument("--out", default=str(ROOT / "results" / "synth" / "dashscope"))
    a = ap.parse_args()
    from gpu_server import SyncNet, mfcc_of
    sn = SyncNet(device="cpu")
    crops = DS / "crops"
    crops.mkdir(parents=True, exist_ok=True)
    rows, strip = [], []
    mf = {c: mfcc_of(sf.read(str(Path(a.wav) / f"{c}.wav"), dtype="float32")[0]) for c in a.clip}
    for i, c in enumerate(a.clip):
        gens = {"musetalk": read_frames(Path(a.pilot) / f"{c}.mp4")}
        for src in sorted(DS.glob(f"{c}__*.mp4")):
            if src.stem.endswith("__still"):
                continue
            g = src.stem.split("__", 1)[1]
            dst = crops / f"{c}__{g}.mp4"
            if not dst.exists():
                write_mp4(frame_crop(to25(src)), dst)
                meta = json.loads((Path(a.pilot) / f"{c}.json").read_text())
                meta.update(generator=g, source="synth")
                dst.with_suffix(".json").write_text(json.dumps(meta, ensure_ascii=False))
                dst.with_suffix(".txt").write_text((Path(a.pilot) / f"{c}.txt").read_text())
            gens[g] = read_frames(dst)
        other = a.clip[(i + 1) % len(a.clip)]
        lab_row = []
        for g, fr in gens.items():
            own, null = sn.run(fr, mf[c]), sn.run(fr, mf[other])
            row = dict(clip=c, generator=g, frames=len(fr), sync_conf=round(own["conf"], 2), sync_offset=own["offset"],
                       null_conf=round(null["conf"], 2), **lip_stats(fr))
            rows.append(row)
            print(json.dumps(row, ensure_ascii=False), flush=True)
            idx = np.linspace(0, len(fr) - 1, 10).astype(int)
            lab = np.full((20, 1600, 3), 255, np.uint8)
            cv2.putText(lab, f"{c}  {g}  SyncNet {row['sync_conf']}  lip p90-p10 {row['lip_gap_p90_p10']}",
                        (4, 15), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (0, 0, 0), 1)
            lab_row += [lab, np.concatenate([cv2.resize(window96(fr[j]), (160, 160)) for j in idx], 1)]
        strip += lab_row + [np.full((8, 1600, 3), 0, np.uint8)]
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "compare.json").write_text(json.dumps(rows, ensure_ascii=False, indent=1))
    cv2.imwrite(str(out / "compare_strip.jpg"), np.concatenate(strip, 0), [cv2.IMWRITE_JPEG_QUALITY, 85])
    by = {}
    for r in rows:
        by.setdefault(r["generator"], []).append(r)
    for g, rs in by.items():
        print(g, {k: round(float(np.mean([r[k] for r in rs])), 2) for k in
                  ("sync_conf", "null_conf", "lip_gap_mean", "lip_gap_p90_p10", "mouth_width_std")}, f"n={len(rs)}")


if __name__ == "__main__":
    main()
