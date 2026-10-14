"""Checks of synthetic clips (synth/gen.py --keep-wav): SyncNet with the clip's own audio against audio of another
clip (the null), plus a strip of frames for the eye.

SyncNet is newdata/gpu_server.py's (the collector's sync filter), with its thresholds from newdata/rv_collect.py:
a real segment passes at conf >= 3.0 and |offset - off_center| <= off_tol.
MuseTalk was not trained against this SyncNet, so the score is an independent check (Wav2Lip would be: it is
trained with a SyncNet discriminator and scores high regardless of how readable the lips are).

  python synth/check.py --clips data/synth/pilot --wav data/synth/pilot_wav --out results/synth
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import cv2
import numpy as np
import soundfile as sf

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "newdata"))


def read_frames(mp4: Path) -> np.ndarray:
    cap = cv2.VideoCapture(str(mp4))
    fr = []
    while True:
        ok, f = cap.read()
        if not ok:
            break
        fr.append(f)
    cap.release()
    return np.stack(fr)


def strip(clips: list[Path], out: Path, n_frames=8):
    rows = []
    for mp4 in clips:
        fr = read_frames(mp4)
        idx = np.linspace(0, len(fr) - 1, n_frames).astype(int)
        view = [cv2.resize(cv2.resize(fr[i], (160, 160))[32:128, 32:128], (160, 160), interpolation=cv2.INTER_NEAREST)
                for i in idx]
        full = [cv2.resize(fr[i], (160, 160)) for i in idx]
        lab = np.full((22, 160 * n_frames, 3), 255, np.uint8)
        cv2.putText(lab, f"{mp4.stem}", (4, 16), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (0, 0, 0), 1)
        rows += [lab, np.concatenate(full, 1), np.concatenate(view, 1)]
    cv2.imwrite(str(out), np.concatenate(rows, 0), [cv2.IMWRITE_JPEG_QUALITY, 85])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--clips", required=True)
    ap.add_argument("--wav", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--device", default="cpu")
    ap.add_argument("--strip-n", type=int, default=10)
    a = ap.parse_args()
    from gpu_server import SyncNet, mfcc_of
    th = {"seg_conf_min": 3.0, "off_center": 0, "off_tol": 3}
    tf = ROOT / "newdata" / "rv_thresholds.json"
    if tf.exists():
        th.update({k: v for k, v in json.loads(tf.read_text()).items() if k in th})

    clips = sorted(p for p in Path(a.clips).glob("synth_*.mp4") if (Path(a.wav) / f"{p.stem}.wav").exists())
    sn = SyncNet(device=a.device)
    frames = {c.stem: read_frames(c) for c in clips}
    mfcc = {}
    for c in clips:
        w, sr = sf.read(str(Path(a.wav) / f"{c.stem}.wav"), dtype="float32")
        assert sr == 16000
        mfcc[c.stem] = mfcc_of(w)

    def passes(r):
        return r["conf"] >= th["seg_conf_min"] and abs(r["offset"] - th["off_center"]) <= th["off_tol"]

    rows = []
    names = [c.stem for c in clips]
    for i, n in enumerate(names):
        own = sn.run(frames[n], mfcc[n])
        other = names[(i + len(names) // 2) % len(names)]
        null = sn.run(frames[n], mfcc[other])
        meta = json.loads((Path(a.clips) / f"{n}.json").read_text())
        rows.append(dict(clip=n, corpus=meta["audio_corpus"], face=meta["speaker"], sec=meta["end"],
                         own=own, null=null, pass_own=passes(own), pass_null=passes(null)))
        print(f"{n} {meta['audio_corpus']:6s} own conf {own['conf']:5.2f} off {own['offset']:+3d} | "
              f"null conf {null['conf']:5.2f} off {null['offset']:+3d}", flush=True)

    def med(k, f):
        return round(float(np.median([r[k][f] for r in rows])), 2)

    summ = dict(n=len(rows), thresholds=th,
                own_conf_median=med("own", "conf"), null_conf_median=med("null", "conf"),
                own_offset_median=med("own", "offset"),
                pass_own=round(float(np.mean([r["pass_own"] for r in rows])), 3),
                pass_null=round(float(np.mean([r["pass_null"] for r in rows])), 3),
                by_corpus={c: dict(n=sum(r["corpus"] == c for r in rows),
                                   own_conf_median=round(float(np.median([r["own"]["conf"] for r in rows
                                                                          if r["corpus"] == c])), 2),
                                   pass_own=round(float(np.mean([r["pass_own"] for r in rows if r["corpus"] == c])), 3))
                           for c in sorted({r["corpus"] for r in rows})})
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "syncnet_pilot.json").write_text(json.dumps(dict(summary=summ, rows=rows), ensure_ascii=False, indent=1))
    print("SUMMARY " + json.dumps(summ, ensure_ascii=False))
    pick = clips[:: max(1, len(clips) // a.strip_n)][:a.strip_n]
    strip(pick, out / "pilot_strip.jpg")


if __name__ == "__main__":
    main()
