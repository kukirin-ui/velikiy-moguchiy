"""Живые признаки VTP: следит за data/public/, для каждого готового клипа (есть .json, есть .mp4, нет .npy)
считает признаки так же, как dataset.py (mvsr.read_faces -> замороженный VTP, чанк 350 кадров, fp16) и пишет
data/public/<id>.npy рядом (атомарно). Единственный GPU-процесс: ждёт, пока не завершатся train/evaluate/dataset/
nbest/lora. Запускать только под tools/mem_guard.py (см. fetch/start.sh).
Остановка: touch fetch/FEATURES_STOP или kill. --once: обработать накопленное и выйти."""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
import memguard  # noqa: E402,F401  (до import torch)

import argparse, os, subprocess, time, zlib  # noqa: E402

import numpy as np  # noqa: E402

CHUNK_FRAMES = 14 * 25
PUB = ROOT / "data" / "public"
GPU_PROCS = r"(train|evaluate|dataset|nbest|nbest_oracle|lora|baseline)\.py"


def other_gpu_job():
    r = subprocess.run(["pgrep", "-f", GPU_PROCS], capture_output=True, text=True)
    me = {str(os.getpid()), str(os.getppid())}
    return [p for p in r.stdout.split() if p not in me]


SHARD = (0, 1)


def pending():
    out = []
    for j in sorted(PUB.glob("*.json")):
        if j.name.endswith(".tmp.json"):
            continue
        s = j.stem
        if zlib.crc32(s.encode()) % SHARD[1] != SHARD[0]:
            continue
        if (PUB / f"{s}.mp4").exists() and not (PUB / f"{s}.npy").exists():
            out.append(s)
    # clips from new sources first: the MultiVSR replay is already in the model and can wait
    out.sort(key=lambda s: not s.startswith(("yt_", "rt_", "vk_")))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--once", action="store_true")
    ap.add_argument("--min-free", type=int, default=12)
    ap.add_argument("--shard", default="1/1", help="k/n: only clips whose id hashes to k, so n workers can share a dir")
    a = ap.parse_args()
    global SHARD
    k, n_shards = map(int, a.shard.split("/"))
    SHARD = (k - 1, n_shards)
    import torch
    import mvsr
    device = mvsr.pick_device(None)
    venc = mvsr.load_venc(device)
    print(f"{time.strftime('%F %T')} feature worker: устройство {device}", flush=True)
    n = 0
    bad = set()
    t0 = time.time()
    while True:
        if (ROOT / "fetch" / "FEATURES_STOP").exists():
            break
        # rescan often: new clips keep arriving and must not wait behind a long backlog of old ones
        todo = [x for x in pending() if x not in bad][:300]
        if not todo:
            if a.once:
                break
            time.sleep(20)
            continue
        for s in todo:
            if (ROOT / "fetch" / "FEATURES_STOP").exists():
                return
            # on the Mac the GPU shares RAM with everything else; a 24 GB CUDA card fits training and features at once
            while (device != "cuda" and other_gpu_job()) or memguard.free_pct() < a.min_free:
                time.sleep(30)
            try:
                faces = mvsr.read_faces(PUB / f"{s}.mp4")
                feats = None
                # a long clip that does not fit at 350 frames is retried in smaller chunks instead of looping forever
                for chunk in (CHUNK_FRAMES, CHUNK_FRAMES // 4, 25):
                    try:
                        outs = []
                        with torch.no_grad():
                            for i in range(0, faces.size(2), chunk):
                                outs.append(venc(faces[:, :, i:i + chunk].to(device))[0].float().cpu())
                        feats = torch.cat(outs, 0).numpy().astype(np.float16)
                        break
                    except RuntimeError as e:
                        if "out of memory" not in str(e).lower():
                            raise
                        outs = None
                        memguard.mps_cleanup()
                if feats is None:
                    raise RuntimeError("out of memory even at 25-frame chunks")
                assert feats.ndim == 2 and feats.shape[1] == 512 and feats.shape[0] == faces.size(2), feats.shape
                tmp = PUB / f"{s}.tmp.npy"
                np.save(tmp, feats)
                os.replace(tmp, PUB / f"{s}.npy")
                n += 1
            except Exception as e:  # noqa
                faces = None
                memguard.mps_cleanup()
                print(f"{s}: {type(e).__name__}: {e}", flush=True)
                (PUB / f"{s}.npy.err").write_text(str(e))
                bad.add(s)
            faces = None
            memguard.mps_cleanup()
            if n % 50 == 0 and n:
                print(f"{time.strftime('%F %T')} признаков {n}, {n / (time.time() - t0):.1f} клип/с", flush=True)
        if a.once:
            continue


if __name__ == "__main__":
    main()
