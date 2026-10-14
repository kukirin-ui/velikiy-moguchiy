"""Read a video by the lips with a trained checkpoint, next to the base model.

  .venv/bin/python lips_try.py --record 5            # 5 s from the webcam, then read it
  .venv/bin/python lips_try.py some_video.mp4         # an existing video
  .venv/bin/python lips_try.py VIDEO --run results/pod_runs/t1/checkpoints/e2e_full

--run is a folder with best.pt (LoRA) and best_venc.pth (visual front-end) from train_e2e.py; by default the model
fine-tuned on the owner's clips.
"""
import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path

import memguard  # noqa: F401  (MPS limits before import torch)

ROOT = Path(__file__).resolve().parent


def record(seconds: float, out: Path):
    # avfoundation device 0 is the built-in camera; the terminal app needs camera permission
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "avfoundation", "-framerate", "30", "-video_size", "1280x720",
                    "-i", "0", "-t", str(seconds), "-r", "25", str(out)], check=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("video", nargs="?")
    ap.add_argument("--record", type=float, default=0, help="record N seconds from the webcam instead of a file")
    ap.add_argument("--run", default=str(ROOT / "results" / "pod_runs" / "t1" / "checkpoints" / "me1"))
    ap.add_argument("--no-base", action="store_true", help="skip the base model (half the time and memory)")
    a = ap.parse_args()
    tmp = Path(tempfile.mkdtemp(prefix="lips_try_"))
    src = Path(a.video) if a.video else tmp / "rec.mp4"
    if a.record:
        print(f"Recording {a.record:g} s: speak to the camera now", flush=True)
        record(a.record, src)
    elif not a.video:
        sys.exit("give a video path or --record N")

    from preprocess import preprocess_video
    import mvsr
    crop = tmp / "face.avi"
    preprocess_video(str(src), str(crop))
    run = Path(a.run)
    models = [] if a.no_base else [("base model", {})]
    models.append((f"trained ({run.name})", {"lora": str(run / "best.pt"), "venc_ckpt": str(run / "best_venc.pth")}))
    for name, kw in models:
        m = mvsr.MultiVSR(device="auto", **kw)
        text, _ = m.transcribe_faces(m.load_faces(crop))
        print(f"{name:22} {text}", flush=True)
        del m


if __name__ == "__main__":
    os.chdir(ROOT)
    main()
