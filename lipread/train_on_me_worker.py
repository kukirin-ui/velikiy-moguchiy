"""Model steps of «Обучить на мне»; train_on_me.py starts them under ../tools/mem_guard.py at nice 10.

  prepare  --job JOB.json --out OUT.json
           face crops of every clip, made as the lips service makes them (preprocess.py with the detector on every
           5th frame), cached by the video's sha1; light mode: VTP features of the training clips through the
           installed model's front-end; full mode: the start checkpoint of train_e2e.py (installed LoRA + front-end)
  evaluate --clips HOLDOUT.json --venc VENC [--lora LORA] --out OUT.json
           WER/CER of one model on the held-out clips, decoded as the lips service decodes (beam 20, no rescoring)

Progress goes to stdout as `@@stage <name>` and `@@progress <done> <total>` lines.
"""
from __future__ import annotations

import memguard  # noqa: F401  (the R11 check and the MPS limits, before import torch)

import argparse
import json
import multiprocessing as mp
import os
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

DET_EVERY = 5               # as lips_service.py --det-every
CROP_WORKERS = 3            # CPU processes for the face detector (dataset.py uses 3 too)
CHUNK_FRAMES = 14 * 25      # VTP in 14 s pieces, as dataset.py and the MultiVSR inference


def say(*parts):
    print(*parts, flush=True)


def write_json(path: Path, obj):
    tmp = Path(path).with_suffix(".tmp")
    tmp.write_text(json.dumps(obj, ensure_ascii=False), encoding="utf8")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def no_face(err: BaseException) -> bool:
    """preprocess_video's verdict that the clip has no usable face track: the only failure remembered for good.
    Anything else (ffmpeg missing or broken, a writer error, a damaged file) is retried by the next job."""
    return isinstance(err, RuntimeError) and "лицо не найдено" in str(err)


def _crop(job):
    """In a crop process (CPU only, one thread). -> (hash, error or None, the error is "no face")."""
    h, src, dst = job
    import torch
    torch.set_num_threads(1)
    from preprocess import preprocess_video
    dst = Path(dst)
    part = dst.with_name(dst.stem + ".part.avi")
    try:
        preprocess_video(src, part, det_every=DET_EVERY)
        os.replace(part, dst)
        return h, None, False
    except Exception as e:
        part.unlink(missing_ok=True)
        return h, f"{type(e).__name__}: {e}"[:300], no_face(e)


def avi_frames(path: Path) -> int:
    import cv2
    cap = cv2.VideoCapture(str(path))
    n = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    cap.release()
    return n


def prepare(a):
    job = json.loads(Path(a.job).read_text(encoding="utf8"))
    clips = job["clips"]
    faces_dir = Path(job["faces_dir"])
    faces_dir.mkdir(parents=True, exist_ok=True)
    face = {c["id"]: faces_dir / f"{c['hash']}.avi" for c in clips}
    skipf = {c["id"]: faces_dir / f"{c['hash']}.skip.json" for c in clips}

    # 1. face crops (cached; a clip without a face is remembered and not retried)
    todo, seen = [], set()
    for c in clips:
        if face[c["id"]].exists() or skipf[c["id"]].exists() or c["hash"] in seen:
            continue
        seen.add(c["hash"])
        todo.append((c["hash"], c["mp4"], str(face[c["id"]])))
    say("@@stage prepare")
    say(f"@@progress 0 {max(1, len(todo))}")
    failed = {}
    if todo:
        memguard.require_free(what="кадры лица")
        t0 = time.perf_counter()
        with mp.get_context("spawn").Pool(CROP_WORKERS) as pool:
            for k, (h, err, permanent) in enumerate(pool.imap_unordered(_crop, todo), 1):
                if err and permanent:
                    write_json(faces_dir / f"{h}.skip.json", {"reason": err})
                    say(f"no face: {h[:10]} ({err})")
                elif err:
                    failed[h] = err
                    say(f"crop failed, will retry next time: {h[:10]} ({err})")
                say(f"@@progress {k} {len(todo)}")
        say(f"crops: {len(todo)} in {time.perf_counter() - t0:.0f} s")
        if failed and len(failed) == len(todo):
            sys.exit(f"ERROR: no crop could be made, first error: {next(iter(failed.values()))}")
    out = {}
    for c in clips:
        f = face[c["id"]]
        if f.exists():
            out[c["id"]] = dict(face=str(f), frames=avi_frames(f), feats=None, skip=None)
        else:
            sk = skipf[c["id"]]
            reason = (json.loads(sk.read_text()).get("reason") if sk.exists() else failed.get(c["hash"])) \
                or "нет кропа лица"
            out[c["id"]] = dict(face=None, frames=0, feats=None, skip=reason)

    # 2. light mode: VTP features through the installed model's front-end (cached per front-end)
    if job.get("feats_dir"):
        import numpy as np
        feats_dir = Path(job["feats_dir"])
        feats_dir.mkdir(parents=True, exist_ok=True)
        want = [c for c in clips if c.get("feats") and out[c["id"]]["face"]]
        need = [c for c in want if not (feats_dir / f"{c['hash']}.npy").exists()]
        say("@@stage features")
        say(f"@@progress 0 {max(1, len(need))}")
        if need:
            import torch
            import mvsr
            device = mvsr.pick_device("auto")
            venc = mvsr.load_venc(device, job["venc"])
            for k, c in enumerate(need, 1):
                memguard.require_free(what="признаки VTP")
                faces = mvsr.read_faces(out[c["id"]]["face"])
                parts = []
                with torch.no_grad():
                    for i in range(0, faces.size(2), CHUNK_FRAMES):
                        parts.append(venc(faces[:, :, i:i + CHUNK_FRAMES].to(device))[0].float().cpu())
                feats = torch.cat(parts, 0).numpy().astype(np.float16)
                assert feats.ndim == 2 and feats.shape[1] == 512, feats.shape
                dst = feats_dir / f"{c['hash']}.npy"
                tmp = dst.with_name(dst.stem + ".tmp.npy")
                np.save(tmp, feats)
                os.replace(tmp, dst)
                del faces, parts
                if k % 10 == 0:
                    memguard.mps_cleanup()
                say(f"@@progress {k} {len(need)}")
            del venc
            memguard.mps_cleanup()
        for c in want:
            p = feats_dir / f"{c['hash']}.npy"
            if p.exists():
                out[c["id"]].update(feats=str(p), frames=int(np.load(p, mmap_mode="r").shape[0]))

    # 3. full mode: train_e2e.py --init wants one checkpoint with the LoRA and the front-end
    if job.get("init_e2e") and job.get("lora"):
        import torch
        import mvsr
        ck = torch.load(job["lora"], map_location="cpu", weights_only=False)
        sd = mvsr._load_ckpt(job["venc"], "cpu")["state_dict"]
        venc = {k.replace("module.face_encoder.", ""): v for k, v in sd.items() if "face_encoder" in k}
        dst = Path(job["init_e2e"])
        torch.save(dict(lora=ck["lora"], venc=venc, config=ck.get("config", {}), step=ck.get("step", 0)),
                   dst.with_suffix(".tmp"))
        os.replace(dst.with_suffix(".tmp"), dst)
        say(f"init checkpoint: {dst}")

    write_json(Path(a.out), {"clips": out})
    n_face = sum(1 for v in out.values() if v["face"])
    say(f"prepared: {n_face}/{len(clips)} clips with a face")


def evaluate(a):
    import metrics
    import mvsr
    clips = json.loads(Path(a.clips).read_text(encoding="utf8"))
    say(f"@@progress 0 {max(1, len(clips))}")
    t0 = time.perf_counter()
    m = mvsr.MultiVSR(device=a.device, lora=a.lora or None, venc_ckpt=a.venc, beam_size=a.beam,
                      venc_max_frames=25, last_logits_only=True)
    say(f"model loaded in {time.perf_counter() - t0:.1f} s on {m.device}")
    pairs, rows = [], []
    for k, c in enumerate(clips, 1):
        memguard.require_free(what="проверка модели")
        hyp, _ = m.transcribe_faces(m.load_faces(c["face"]))
        pairs.append((c["text"], hyp))
        rows.append(dict(id=c["id"], ref=c["text"], hyp=hyp))
        if k % 5 == 0:
            memguard.mps_cleanup()
        say(f"@@progress {k} {len(clips)}")
    wer, cer = metrics.corpus_rates(pairs)
    write_json(Path(a.out), dict(wer=wer, cer=cer, n=len(pairs), lora=a.lora, venc=a.venc, clips=rows,
                                 seconds=round(time.perf_counter() - t0, 1)))
    say(f"WER {wer * 100:.1f}% CER {cer * 100:.1f}% on {len(pairs)} held-out clips")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("prepare")
    p.add_argument("--job", required=True)
    p.add_argument("--out", required=True)
    e = sub.add_parser("evaluate")
    e.add_argument("--clips", required=True)
    e.add_argument("--venc", required=True)
    e.add_argument("--lora", default=None)
    e.add_argument("--out", required=True)
    e.add_argument("--beam", type=int, default=20)
    e.add_argument("--device", default="auto")
    a = ap.parse_args()
    prepare(a) if a.cmd == "prepare" else evaluate(a)


if __name__ == "__main__":
    main()
