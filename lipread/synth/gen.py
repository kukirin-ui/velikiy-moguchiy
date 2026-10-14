"""Synthetic lip clips (SynthVSR idea): Russian speech with an exact transcript + a synthetic face still ->
MuseTalk 1.5 talking face -> the trainer's clip format.

Output per clip in --out (flat, like data/public):
  NAME.mp4   224x224, 25 fps, no audio: the face crop of facecrop.py (MultiVSR framing), so mvsr.read_faces
             sees what it sees on real clips (resize to 160, centre 96x96)
  NAME.txt   label normalised like the trainer's (metrics.normalize_loose)
  NAME.json  source=synth, speaker=face id, audio corpus/id/licence, generator; written last, marks the clip done
NAME = synth_<corpus>_<sha1(audio id)[:12]>: reruns skip finished clips, so a preempted pod just restarts.

The head is static (SynthVSR also used a static rotation); MuseTalk only redraws the lower half of the face box,
pasted back with a feathered mask below the box centre, as MuseTalk's own blending does.

  python synth/gen.py --faces data/synth/src/faces/sfhq4 --source parquet:data/synth/src/golos/*.parquet@golos \\
      --out data/synth/pilot --limit 50 --keep-wav data/synth/pilot_wav
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import cv2
import numpy as np
import torch

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "synth"))
import facecrop  # noqa: E402
import sources  # noqa: E402

FPS = 25
SR = 16000
GENERATOR = "MuseTalk 1.5 (TMElyralab, code MIT, weights 'available for any purpose') + sd-vae-ft-mse + whisper-tiny"

# MediaPipe FaceMesh indices: 152 chin, 195 lower nose bridge (dwpose 68-point #29, which MuseTalk's box uses)
CHIN, NOSE29 = 152, 195


def sha(s: str, n=12) -> str:
    return hashlib.sha1(s.encode()).hexdigest()[:n]


class PositionalEncoding(torch.nn.Module):
    """musetalk/models/unet.py (MIT)."""

    def __init__(self, d_model=384, max_len=5000):
        super().__init__()
        pe = torch.zeros(max_len, d_model)
        position = torch.arange(0, max_len, dtype=torch.float).unsqueeze(1)
        div_term = torch.exp(torch.arange(0, d_model, 2).float() * (-math.log(10000.0) / d_model))
        pe[:, 0::2] = torch.sin(position * div_term)
        pe[:, 1::2] = torch.cos(position * div_term)
        self.register_buffer("pe", pe.unsqueeze(0))

    def forward(self, x):
        return x + self.pe[:, :x.size(1)].to(x.dtype)


class Muse:
    """MuseTalk 1.5 inference: one UNet step in the sd-vae latent space, conditioned on whisper-tiny features."""

    def __init__(self, models: Path, device: str, fp16: bool, decoder: str = "taesd"):
        from diffusers import AutoencoderKL, AutoencoderTiny, UNet2DConditionModel
        from transformers import AutoFeatureExtractor, WhisperModel
        self.dev = device
        self.dt = torch.float16 if fp16 else torch.float32
        cfg = json.loads((models / "musetalkV15" / "musetalk.json").read_text())
        self.unet = UNet2DConditionModel(**{k: v for k, v in cfg.items() if not k.startswith("_")})
        self.unet.load_state_dict(torch.load(models / "musetalkV15" / "unet.pth", map_location="cpu"))
        self.unet.to(device, self.dt).eval()
        self.vae = AutoencoderKL.from_pretrained(models / "sd-vae").to(device, self.dt).eval()
        self.scale = self.vae.config.scaling_factor
        # TAESD decodes 18x cheaper (35 vs 620 GFLOP a frame); on the 96x96 the VSR model sees it is 42 dB PSNR
        # from the full VAE (results/synth/README.md). The full VAE stays the encoder: faces are encoded once.
        self.tae = None
        if decoder == "taesd":
            self.tae = AutoencoderTiny.from_pretrained(models / "taesd").to(device, self.dt).eval()
        self.fe = AutoFeatureExtractor.from_pretrained(models / "whisper")
        self.whisper = WhisperModel.from_pretrained(models / "whisper").encoder.to(device, self.dt).eval()
        self.pe = PositionalEncoding(384).to(device)
        self.t0 = torch.zeros(1, device=device, dtype=torch.long)

    @torch.inference_mode()
    def face_latents(self, crop256_bgr: np.ndarray) -> torch.Tensor:
        """(1, 8, 32, 32): latents of the face with the lower half blacked out + of the whole face (reference)."""
        x = torch.from_numpy(cv2.cvtColor(crop256_bgr, cv2.COLOR_BGR2RGB)).float().div(255).permute(2, 0, 1)
        masked = x.clone()
        masked[:, 128:] = 0
        lat = self.vae.encode(torch.stack([masked, x]).mul(2).sub(1).to(self.dev, self.dt)).latent_dist.mode()
        lat = lat * self.scale
        return torch.cat([lat[0:1], lat[1:2]], 1).cpu()

    @torch.inference_mode()
    def audio_chunks(self, wavs: list[np.ndarray]) -> list[torch.Tensor]:
        """Per clip (frames, 50, 384): whisper-tiny hidden states of all 5 layers, 10 steps (200 ms) around
        each video frame. Same indexing as musetalk/utils/audio_processor.py with padding 2/2. Clips <= 30 s."""
        feats = self.fe([w for w in wavs], sampling_rate=SR, return_tensors="pt").input_features
        hs = torch.stack(self.whisper(feats.to(self.dev, self.dt), output_hidden_states=True).hidden_states, 2)
        out = []
        for b, w in enumerate(wavs):
            n = math.floor(len(w) / SR * FPS)
            f = hs[b, :math.floor(len(w) / SR * 50)]
            f = torch.cat([f.new_zeros(4, *f.shape[1:]), f, f.new_zeros(12, *f.shape[1:])])
            idx = (torch.arange(n, device=f.device) * 2)[:, None] + torch.arange(10, device=f.device)[None]
            out.append(f[idx].reshape(n, 50, 384))
        return out

    @torch.inference_mode()
    def silent_latent(self, face_lat: torch.Tensor) -> torch.Tensor:
        """The UNet's output for this face on silence (whisper features of 1 s of zeros), the anchor of --mouth-gain."""
        if not hasattr(self, "_sil"):
            self._sil = self.audio_chunks([np.zeros(SR, np.float32)])[0][12:13]
        return self.unet(face_lat.to(self.dev, self.dt), self.t0,
                         encoder_hidden_states=self.pe(self._sil.to(self.dt))).sample.cpu()

    @torch.inference_mode()
    def render(self, latents: torch.Tensor, chunks: torch.Tensor, batch: int, sil: torch.Tensor | None = None,
               gain: float = 1.0) -> np.ndarray:
        """latents (N, 8, 32, 32), chunks (N, 50, 384) -> (N, 256, 256, 3) uint8 BGR. With gain != 1 the output is
        pushed away from the face's silent output: sil + gain * (pred - sil), sil (N, 4, 32, 32)."""
        out = np.empty((len(chunks), 256, 256, 3), np.uint8)
        for i in range(0, len(chunks), batch):
            lat = latents[i:i + batch].to(self.dev, self.dt)
            aud = self.pe(chunks[i:i + batch].to(self.dt))
            pred = self.unet(lat, self.t0, encoder_hidden_states=aud).sample
            if gain != 1.0:
                s0 = sil[i:i + batch].to(self.dev, self.dt)
                pred = s0 + gain * (pred - s0)
            img = self.tae.decode(pred).sample if self.tae is not None else self.vae.decode(pred / self.scale).sample
            img = ((img.float() / 2 + 0.5).clamp(0, 1) * 255).round().to(torch.uint8)
            out[i:i + batch] = img.permute(0, 2, 3, 1).cpu().numpy()[..., ::-1]
        return out


class FacePrep:
    """Face still -> everything per-frame work needs: the 224 crop of facecrop.py (S3FD box, MultiVSR framing),
    MuseTalk's box mapped into that crop, the blend mask, and the 256x256 MuseTalk input."""

    MAX_SIDE = 768

    def __init__(self, det_device="cpu"):
        sys.path.insert(0, str(ROOT / "multivsr" / "preprocess"))
        from detectors import S3FD  # type: ignore
        import mediapipe as mp
        self.det = S3FD(device=det_device)  # never "mps": preprocess.py found S3FD boxes wrong there
        self.mesh = mp.solutions.face_mesh.FaceMesh(static_image_mode=True, max_num_faces=1, refine_landmarks=False)
        self.oval = sorted({i for e in mp.solutions.face_mesh.FACEMESH_FACE_OVAL for i in e})

    def __call__(self, path: Path) -> dict | str:
        img = cv2.imread(str(path))
        if img is None:
            return "unreadable"
        k = self.MAX_SIDE / max(img.shape[:2])
        if k < 1:
            img = cv2.resize(img, None, fx=k, fy=k, interpolation=cv2.INTER_AREA)
        rgb = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
        boxes = self.det.detect_faces(rgb, conf_th=0.9, scales=[0.5])
        if len(boxes) != 1:
            return f"s3fd faces={len(boxes)}"
        x0, y0, x1, y1 = boxes[0][:4]
        s, cx, cy = max(y1 - y0, x1 - x0) / 2, (x0 + x1) / 2, (y0 + y1) / 2
        res = self.mesh.process(rgb)
        if not res.multi_face_landmarks:
            return "no facemesh"
        h, w = img.shape[:2]
        lm = np.array([(p.x * w, p.y * h) for p in res.multi_face_landmarks[0].landmark], np.float64)
        ov = lm[self.oval]
        bx0, bx1 = ov[:, 0].min(), ov[:, 0].max()
        chin, nose = lm[CHIN, 1], lm[NOSE29, 1]
        by0 = max(0.0, nose - (chin - nose))
        by1 = min(h, chin + 0.04 * (chin - by0))  # MuseTalk v1.5 extra_margin, 10 px at its usual face size
        bx0, bx1, by0, by1 = int(max(0, bx0)), int(min(w, bx1)), int(by0), int(by1)
        crop256 = cv2.resize(img[by0:by1, bx0:bx1], (256, 256), interpolation=cv2.INTER_LANCZOS4)

        base = facecrop.crop_frame(img, s, cx, cy)
        # facecrop.crop_frame window in image coordinates: rows cy - s .. cy + 1.8 s, cols cx -+ 1.4 s
        top, left = cy - s, cx - s * (1 + facecrop.CROP_SCALE)
        side = 2 * s * (1 + facecrop.CROP_SCALE)
        m = facecrop.SIZE / side

        def to224(x, y):
            return (x - left) * m, (y - top) * m

        X0, Y0 = (int(round(v)) for v in to224(bx0, by0))
        X1, Y1 = (int(round(v)) for v in to224(bx1, by1))
        S = facecrop.SIZE
        if X1 - X0 < 40 or Y1 - Y0 < 40 or X0 < -S // 4 or Y0 < -S // 4 or X1 > S * 5 // 4 or Y1 > S * 5 // 4:
            return "box outside crop"
        # the box may poke out of the crop a little (its static top half, usually): compose() clips it
        cX0, cY0, cX1, cY1 = max(X0, 0), max(Y0, 0), min(X1, S), min(Y1, S)
        # blend mask: face oval, stretched down for the open jaw, only below the box centre, feathered
        pts = np.stack(to224(ov[:, 0], ov[:, 1]), 1)
        jaw = pts[pts[:, 1] > to224(0, nose)[1]] + [0, 0.08 * (Y1 - Y0)]
        mask = np.zeros((facecrop.SIZE, facecrop.SIZE), np.uint8)
        cv2.fillConvexPoly(mask, cv2.convexHull(np.concatenate([pts, jaw]).astype(np.int32)), 255)
        mask[:max((Y0 + Y1) // 2, 0)] = 0
        keep = np.zeros_like(mask)
        keep[cY0:cY1, cX0:cX1] = 255
        mask = np.minimum(mask, keep)
        kb = int(0.1 * (X1 - X0)) // 2 * 2 + 1
        mask = cv2.GaussianBlur(mask, (kb, kb), 0)
        mask = np.minimum(mask, keep)  # the generated patch ends at the box, so must the mask
        return dict(base=base, box=np.array([X0, Y0, X1, Y1]), mask=mask, crop256=crop256,
                    face_px=round(2 * s, 1), src_h=h)


def compose(prep: dict, gen: np.ndarray) -> np.ndarray:
    X0, Y0, X1, Y1 = (int(v) for v in prep["box"])
    S = facecrop.SIZE
    cX0, cY0, cX1, cY1 = max(X0, 0), max(Y0, 0), min(X1, S), min(Y1, S)
    base = prep["base"]
    m = (prep["mask"][cY0:cY1, cX0:cX1, None] / 255.0).astype(np.float32)
    roi = base[cY0:cY1, cX0:cX1].astype(np.float32)
    out = np.repeat(base[None], len(gen), 0)
    for t, g in enumerate(gen):
        g = cv2.resize(g, (X1 - X0, Y1 - Y0), interpolation=cv2.INTER_AREA)
        g = g[cY0 - Y0:cY1 - Y0, cX0 - X0:cX1 - X0].astype(np.float32)
        out[t, cY0:cY1, cX0:cX1] = (roi * (1 - m) + g * m + 0.5).astype(np.uint8)
    return out


def write_clip(out: Path, name: str, frames: np.ndarray, text: str, meta: dict, wav=None, wav_dir=None):
    tmp = out / f".{name}.mp4"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "bgr24", "-s", "224x224",
                    "-r", str(FPS), "-i", "-", "-c:v", "libx264", "-preset", "veryfast", "-crf", "18",
                    "-pix_fmt", "yuv420p", "-threads", "2", str(tmp)], input=frames.tobytes(), check=True)
    tmp.rename(out / f"{name}.mp4")
    (out / f"{name}.txt").write_text(text + "\n", encoding="utf8")
    if wav_dir is not None:
        import soundfile as sf
        sf.write(str(Path(wav_dir) / f"{name}.wav"), wav, SR)
    (out / f"{name}.json").write_text(json.dumps(meta, ensure_ascii=False))


def load_faces(face_dir: Path, cache: Path, muse: Muse, limit: int, det_device="cpu") -> dict:
    """Face id -> prep + latents, cached as npz (S3FD + FaceMesh + one VAE encode, ~40 ms a face on a GPU pod)."""
    cache.mkdir(parents=True, exist_ok=True)
    paths = sorted(p for p in face_dir.rglob("*") if p.suffix.lower() in (".jpg", ".jpeg", ".png"))[:limit or None]
    prep_fn, faces, bad = None, {}, {}
    t0 = time.time()
    for n, p in enumerate(paths):
        c = cache / f"{p.stem}.npz"
        pr = None
        if c.exists():
            try:
                z = np.load(c, allow_pickle=False)
                pr = {k: z[k] for k in z.files}
            except (OSError, ValueError, EOFError):  # half-written by a killed run
                pr = None
        if pr is None:
            prep_fn = prep_fn or FacePrep(det_device)
            pr = prep_fn(p)
            if isinstance(pr, str):
                pr = {"fail": np.array(pr)}
            else:
                pr["lat"] = muse.face_latents(pr["crop256"]).float().numpy()
            np.savez(str(c) + ".tmp.npz", **pr)
            os.replace(str(c) + ".tmp.npz", c)
        if "fail" in pr:
            bad[p.stem] = str(pr["fail"])
            continue
        if "lat" not in pr:
            pr["lat"] = muse.face_latents(pr["crop256"]).float().numpy()
        pr["lat"] = torch.from_numpy(pr["lat"])
        pr["file"] = p.name
        faces[p.stem] = pr
        if n and n % 2000 == 0:
            print(f"faces {n}/{len(paths)}, {time.time() - t0:.0f} s", flush=True)
    print(f"faces: {len(faces)} usable of {len(paths)}; rejected {len(bad)}: "
          f"{dict(sorted({v: list(bad.values()).count(v) for v in set(bad.values())}.items()))}", flush=True)
    return faces


def pick_device(d):
    if d != "auto":
        return d
    return "cuda" if torch.cuda.is_available() else "mps" if torch.backends.mps.is_available() else "cpu"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--faces", required=True, help="dir of face stills (synthetic faces, one face each)")
    ap.add_argument("--face-limit", type=int, default=0)
    ap.add_argument("--face-cache", default=None, help="default: <out>/../face_cache")
    ap.add_argument("--source", action="append", required=True, help="see synth/sources.py; repeatable")
    ap.add_argument("--out", required=True)
    ap.add_argument("--models", default=str(ROOT / "work" / "synth" / "models"))
    ap.add_argument("--device", default="auto")
    ap.add_argument("--fp32", action="store_true")
    ap.add_argument("--decoder", choices=("taesd", "vae"), default="taesd")
    ap.add_argument("--mouth-gain", type=float, default=1.0, help="exaggerate mouth motion (1 = MuseTalk as is)")
    ap.add_argument("--batch", type=int, default=32, help="frames per UNet + VAE call")
    ap.add_argument("--group", type=int, default=16, help="clips per whisper call / render group")
    ap.add_argument("--writers", type=int, default=4)
    ap.add_argument("--min-sec", type=float, default=1.0)
    ap.add_argument("--max-sec", type=float, default=8.0, help="train_e2e.py --max-seconds default")
    ap.add_argument("--limit", type=int, default=0, help="stop after N new clips")
    ap.add_argument("--max-hours", type=float, default=0, help="stop after this much new video")
    ap.add_argument("--part", default="0/1", help="i/n: this worker takes rows with sha1(id) %% n == i")
    ap.add_argument("--keep-wav", default=None, help="also write NAME.wav here (for the SyncNet check)")
    ap.add_argument("--prep-only", action="store_true", help="fill the face cache and exit (run once before parts)")
    a = ap.parse_args()

    dev = pick_device(a.device)
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    if a.keep_wav:
        Path(a.keep_wav).mkdir(parents=True, exist_ok=True)
    part, nparts = (int(v) for v in a.part.split("/"))
    t_load = time.time()
    muse = Muse(Path(a.models), dev, fp16=not a.fp32 and dev != "cpu", decoder=a.decoder)
    faces = load_faces(Path(a.faces), Path(a.face_cache or out.parent / "face_cache"), muse, a.face_limit,
                       "cuda" if dev == "cuda" else "cpu")
    face_ids = sorted(faces)
    if not face_ids:
        raise SystemExit("no usable faces")
    if a.prep_only:
        return
    print(f"device {dev}, models + faces ready in {time.time() - t_load:.0f} s", flush=True)

    pool = ThreadPoolExecutor(a.writers)
    pending = []
    stats = dict(clips=0, frames=0, skipped={}, t_gpu=0.0)
    t0 = time.time()
    last_log = t0

    def skip(why):
        stats["skipped"][why] = stats["skipped"].get(why, 0) + 1

    def rows():
        # round robin over the sources, so --max-hours takes a mix and not the first corpus only
        its = [sources.iter_source(spec) for spec in a.source]
        while its:
            for it in list(its):
                r = next(it, None)
                if r is None:
                    its.remove(it)
                elif int(sha(f"{r['corpus']}:{r['id']}", 8), 16) % nparts == part:
                    yield r

    def flush(group):
        t = time.time()
        chunks = muse.audio_chunks([g["wav"] for g in group])
        lat = torch.cat([faces[g["face"]]["lat"].expand(len(c), -1, -1, -1) for g, c in zip(group, chunks)])
        sil = None
        if a.mouth_gain != 1.0:
            for g in group:
                pr = faces[g["face"]]
                if "sil" not in pr:
                    pr["sil"] = muse.silent_latent(pr["lat"])
            sil = torch.cat([faces[g["face"]]["sil"].expand(len(c), -1, -1, -1) for g, c in zip(group, chunks)])
        gen = muse.render(lat, torch.cat(chunks), a.batch, sil, a.mouth_gain)
        if dev == "cuda":
            torch.cuda.synchronize()
        stats["t_gpu"] += time.time() - t
        i = 0
        for g, c in zip(group, chunks):
            frames = gen[i:i + len(c)]
            i += len(c)
            pr = faces[g["face"]]
            meta = dict(video_id=f"synth_{g['face']}", source="synth", speaker=g["face"], face_file=pr["file"],
                        face_license=FACE_LICENSE, audio_corpus=g["corpus"], audio_id=g["id"],
                        audio_speaker=g.get("speaker", ""), license=g["license"], text_source="corpus transcript",
                        text_raw=g["text_raw"], generator=f"{GENERATOR}, decoder {a.decoder}, mouth gain {a.mouth_gain}", start=0.0, end=round(len(g["wav"]) / SR, 3),
                        frames=len(c), src_height=int(pr["src_h"]), face_px_src=float(pr["face_px"]))
            pending.append(pool.submit(lambda f=frames, g=g, pr=pr, meta=meta: write_clip(
                out, g["name"], compose(pr, f), g["text"], meta, g["wav"], a.keep_wav)))
            stats["clips"] += 1
            stats["frames"] += len(c)
        while len(pending) > 2 * a.writers:
            pending.pop(0).result()

    group = []
    stop_file = out.parent / "STOP"
    for r in rows():
        if stop_file.exists():
            print("STOP file: finishing the current group", flush=True)
            break
        name = f"synth_{r['corpus']}_{sha(r['corpus'] + ':' + r['id'])}"
        if (out / f"{name}.json").exists():
            skip("done before")
            continue
        text = sources.clean_text(r["text"])
        if not text:
            skip("text not cyrillic")
            continue
        try:
            wav = r["audio"]()
        except Exception as e:  # noqa: BLE001 - one broken file must not stop a pod
            skip(f"audio {type(e).__name__}")
            continue
        dur = len(wav) / SR
        if not a.min_sec <= dur <= a.max_sec:
            skip("duration")
            continue
        face = face_ids[int(sha(r["corpus"] + ":" + r["id"] + ":face", 8), 16) % len(face_ids)]
        group.append(dict(r, name=name, text=text, text_raw=r["text"], wav=wav, face=face))
        if len(group) >= a.group:
            flush(group)
            group = []
        done = (a.limit and stats["clips"] >= a.limit) or (a.max_hours and stats["frames"] / FPS / 3600 >= a.max_hours)
        if time.time() - last_log > 30 or done:
            last_log = time.time()
            el = time.time() - t0
            vid = stats["frames"] / FPS
            print(f"{time.strftime('%T')} clips {stats['clips']}, video {vid / 3600:.3f} h, "
                  f"{stats['frames'] / max(el, 1e-6):.0f} frames/s wall, "
                  f"{stats['frames'] / max(stats['t_gpu'], 1e-6):.0f} frames/s model, skipped {stats['skipped']}",
                  flush=True)
        if done:
            break
    if group:
        flush(group)
    for f in pending:
        f.result()
    pool.shutdown()
    el = time.time() - t0
    vid = stats["frames"] / FPS
    summary = dict(clips=stats["clips"], video_s=round(vid, 1), wall_s=round(el, 1), model_s=round(stats["t_gpu"], 1),
                   video_s_per_wall_s=round(vid / max(el, 1e-6), 3),
                   frames_per_model_s=round(stats["frames"] / max(stats["t_gpu"], 1e-6), 1),
                   device=dev, batch=a.batch, decoder=a.decoder, skipped=stats["skipped"])
    print("SUMMARY " + json.dumps(summary, ensure_ascii=False), flush=True)
    (out.parent / f"gen_summary_{out.name}_{part}of{nparts}.json").write_text(json.dumps(summary, ensure_ascii=False))


FACE_LICENSE = "SFHQ synthetic faces (Kaggle release: CC0; no real person); see data/synth/LICENSES.md"

if __name__ == "__main__":
    main()
