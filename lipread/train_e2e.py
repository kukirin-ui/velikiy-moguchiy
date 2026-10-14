"""End-to-end fine-tuning of MultiVSR: the VTP visual front-end is trained in full (small learning rate) together with
LoRA adapters in the transformer, on face crops decoded from the clip videos on the fly.

train.py learns on cached VTP features, so the front-end that sees the lips never adapts; this script is the
variant where it does.

  python3 train_e2e.py --run e2e1 --manifest work/manifest_yt.jsonl --max-steps 1500
  python3 train_e2e.py --run e2e1 --manifest work/manifest_yt.jsonl --eval-wer --n 200   # base vs best.pt on dev
  python3 train_e2e.py --run syn1 --from-videos data/stage --synth-dir data/synth/golos --synth-frac 0.3
      # synthetic clips: train only, outside the R1 channel balance, 30% of every epoch (data_mix.json: what was used)

checkpoints/<run>/best.pt holds {"lora", "config", "step"} like train.py, so evaluate.py --lora reads it;
best_venc.pth holds the front-end in the authors' format, for evaluate.py --venc-ckpt.
"""
from __future__ import annotations

import memguard  # noqa: F401  (MPS limits before import torch)

import argparse
import json
import math
import random
import sys
import time
from pathlib import Path

import numpy as np
import torch

import lora as L
import metrics
import mvsr
import train as T

ROOT = Path(__file__).resolve().parent


class FaceClips(torch.utils.data.Dataset):
    def __init__(self, rows, tok, fmt, flip):
        self.rows, self.flip = rows, flip
        self.tokens = [T.encode_target(tok, r["text"], fmt) for r in rows]

    def __len__(self):
        return len(self.rows)

    def __getitem__(self, i):
        faces = mvsr.read_faces(self.rows[i]["mp4"])[0]  # (3, T, 96, 96)
        if self.flip and random.random() < 0.5:
            faces = faces.flip(-1)
        return faces, self.tokens[i], self.rows[i]["source"] == "synth"


def collate(items):
    return [f for f, _, _ in items], [t for _, t, _ in items], [s for _, _, s in items]


class MixSampler(torch.utils.data.Sampler):
    """An epoch is every real train clip once plus as many synthetic clips as make up `frac` of the epoch.
    Synthetic clips are drawn from a reshuffled pass over the whole pool that carries over between epochs, so a pool
    larger than one epoch's share is still seen in full over the run."""

    def __init__(self, rows, frac, seed):
        self.real = [i for i, r in enumerate(rows) if r["source"] != "synth"]
        self.syn = [i for i, r in enumerate(rows) if r["source"] == "synth"]
        self.n_syn = round(len(self.real) * frac / (1 - frac)) if frac and self.syn else 0
        self.rng = random.Random(seed)
        self.queue = []

    def __len__(self):
        return len(self.real) + self.n_syn

    def __iter__(self):
        picked = []
        while len(picked) < self.n_syn:
            if not self.queue:
                self.queue = self.rng.sample(self.syn, len(self.syn))
            take = min(self.n_syn - len(picked), len(self.queue))
            picked += self.queue[:take]
            del self.queue[:take]
        order = self.real + picked
        self.rng.shuffle(order)
        return iter(order)


def hours(rows):
    return sum(r["frames"] for r in rows) / 25 / 3600


def mix_line(n_real, f_real, n_syn, f_syn):
    n, f = n_real + n_syn, f_real + f_syn
    return (f"real {n_real} clips {f_real / 25 / 3600:.1f} h, synth {n_syn} clips {f_syn / 25 / 3600:.1f} h "
            f"(synth share {n_syn / max(n, 1):.0%} of clips, {f_syn / max(f, 1):.0%} of hours)")


CHUNK = 50
CHUNK_BATCH = 8  # chunks per VTP call; --chunk-batch raises it where GPU memory allows


def forward_loss(venc, model, faces, toks, device, reduction="mean"):
    from torch.utils.checkpoint import checkpoint
    with torch.autocast("cuda", dtype=torch.bfloat16, enabled=device == "cuda"):
        grad = torch.is_grad_enabled()
        # every clip is cut into CHUNK-frame pieces (the last one zero-padded) and pieces of all clips go through VTP
        # together: one clip at a time leaves a large GPU idle. Each call is recomputed in backward to bound memory.
        pieces, owner = [], []
        for ci, f in enumerate(faces):
            f = f.to(device, non_blocking=True)  # slicing and padding on the CPU starved the GPU
            for i in range(0, f.shape[1], CHUNK):
                p = f[:, i:i + CHUNK]
                n = p.shape[1]
                if n < CHUNK:
                    p = torch.cat([p, p.new_zeros(p.shape[0], CHUNK - n, *p.shape[2:])], 1)
                pieces.append(p)
                owner.append((ci, n))
        outs = []
        for i in range(0, len(pieces), CHUNK_BATCH):
            x = torch.stack(pieces[i:i + CHUNK_BATCH])
            outs.append(checkpoint(venc, x, use_reentrant=False) if grad else venc(x))
        out = torch.cat(outs, 0)  # (pieces, CHUNK, 512)
        per = [[] for _ in faces]
        for k, (ci, n) in enumerate(owner):
            per[ci].append(out[k, :n])
        feats = [torch.cat(p, 0) for p in per]
    B, Tm = len(feats), max(f.shape[0] for f in feats)
    x = torch.zeros(B, Tm, feats[0].shape[1], device=device)
    smask = torch.zeros(B, 1, Tm, dtype=torch.long, device=device)
    for i, f in enumerate(feats):
        x[i, :f.shape[0]] = f.float()
        smask[i, 0, :f.shape[0]] = 1
    Lt = max(len(t) for t in toks) - 1
    tin = torch.zeros(B, Lt, dtype=torch.long)
    tout = torch.full((B, Lt), -100, dtype=torch.long)
    for i, t in enumerate(toks):
        tin[i, :len(t) - 1] = torch.tensor(t[:-1])
        tout[i, :len(t) - 1] = torch.tensor(t[1:])
    tmask = (torch.tril(torch.ones(1, Lt, Lt)) > 0).to(device)
    return T.seq_loss(model, (x, smask, tin.to(device), tout.to(device), tmask), reduction=reduction)


def test_keys(a):
    """R10: normalised texts of the owner's test phrases; no training clip may say one of them."""
    import dataset
    return {dataset.text_key(dataset.read_text(t)) for t in Path(a.clips_dir).glob("*.txt")}


def rows_from_videos(a):
    """Rows straight from NAME.mp4 + .txt + .json clips, so clips whose features are not computed yet still train."""
    import dataset
    test = test_keys(a)
    chans = {}
    if Path(a.channel_map).exists():
        for line in Path(a.channel_map).read_text().splitlines():
            v, _, c = line.partition("\t")
            chans[v] = c
    rows = []
    for js in sorted(Path(a.from_videos).glob("yt_*.json")):
        txt = js.with_suffix(".txt")
        if not txt.exists() or not js.with_suffix(".mp4").exists():
            continue
        try:
            meta = json.loads(js.read_text())
        except ValueError:
            continue  # still being written
        text = dataset.read_text(txt)
        if not text or dataset.text_key(text) in test:
            continue
        vid = str(meta.get("video_id") or js.stem.rsplit("__", 1)[0])
        ch = chans.get(vid[3:] if vid.startswith("yt_") else vid)
        # R2: held-out videos come from whole channels (people the model never saw), not from seen speakers
        key = f"ch:{ch}" if ch else f"yt:{vid}"
        rows.append(dict(id=f"public/{js.stem}", source="public", text=text, frames=int(meta.get("frames") or 0),
                         hash=js.stem, channel=ch, split=dataset.split_for(key, a.dev_pct)))
    return rows


def rows_synth(a):
    """Synthetic clips of synth/gen.py (synth_*.mp4 + .txt + .json, json source=synth). They are always train:
    dev and the R1 channel balance stay real channels only (R1, R2)."""
    import dataset
    test = test_keys(a)
    rows = []
    for d in a.synth_dir.split(","):
        for js in sorted(Path(d).glob("synth_*.json")):
            txt, mp4 = js.with_suffix(".txt"), js.with_suffix(".mp4")
            if not txt.exists() or not mp4.exists():
                continue
            try:
                meta = json.loads(js.read_text())
            except ValueError:
                continue
            if meta.get("source") != "synth":
                continue
            text = dataset.read_text(txt)
            if not text or dataset.text_key(text) in test:
                continue
            rows.append(dict(id=f"synth/{js.stem}", source="synth", text=text, frames=int(meta.get("frames") or 0),
                             hash=js.stem, channel=None, speaker=meta.get("speaker"), split="train", mp4=str(mp4)))
    return rows


def check_speakers(a, rows):
    """R1: no single channel (speaker) may dominate the public training data; there is no override flag.
    Synthetic rows pass through untouched and are not counted."""
    from collections import Counter
    synth = [r for r in rows if r.get("source") == "synth"]
    rows = [r for r in rows if r.get("source") != "synth"]
    if a.max_per_channel:
        seen = Counter()
        keep = []
        for r in sorted(rows, key=lambda r: r["hash"]):
            c = r.get("channel")
            if c is None or seen[c] < a.max_per_channel:
                seen[c] += 1
                keep.append(r)
        rows = keep
    train = [r for r in rows if r["split"] == "train"]
    if not train:
        return rows + synth
    known = [r["channel"] for r in train if r.get("channel")]
    if len(known) < 0.95 * len(train):
        raise SystemExit(f"[R1] only {len(known)}/{len(train)} train clips have a known channel "
                         f"(harvester/video_channels.tsv); refusing to train blind to speaker balance")
    cnt = Counter(known)
    top, n = cnt.most_common(1)[0]
    print(f"channels: {len(cnt)}, largest {top} = {n / len(known):.0%} of train", flush=True)
    if len(cnt) < 5 or n / len(known) > 0.25:
        raise SystemExit(f"[R1] {len(cnt)} channels, '{top}' is {n / len(known):.0%} of train clips: the model would "
                         f"learn that speaker, not lip reading. Need >= 5 channels and <= 25% each; thin out with "
                         f"--max-per-channel N or collect more channels.")
    return rows + synth


def smoke_key(a, device):
    """R4: a long run needs a finished short run of the same code, GPU and batch layout."""
    import hashlib
    h = hashlib.sha1()
    for f in ("train_e2e.py", "train.py", "mvsr.py", "lora.py"):
        h.update((ROOT / f).read_bytes())
    gpu = torch.cuda.get_device_name(0) if device == "cuda" else device
    tag = f"{h.hexdigest()[:12]}|{gpu}|b{a.batch}a{a.accum}c{a.chunk_batch}s{a.max_seconds}"
    if a.synth_frac:
        dirs = ",".join(sorted(Path(d).name for d in a.synth_dir.split(",")))
        tag += f"|synth{a.synth_frac:g}:{dirs}"
    return ROOT / "checkpoints" / ".smoke" / (hashlib.sha1(tag.encode()).hexdigest()[:16] + ".ok"), tag


def rows_personal(a):
    """The owner's face crops (preprocess.py output: NAME.avi + NAME.txt); 15% of clips go to dev."""
    import cv2
    import dataset
    rows = []
    for d in a.personal_dir.split(","):
        for avi in sorted(Path(d).glob("*.avi")):
            txt = avi.with_suffix(".txt")
            if not txt.exists():
                continue
            cap = cv2.VideoCapture(str(avi))
            frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
            cap.release()
            key = f"{Path(d).name}/{avi.stem}"
            rows.append(dict(id=f"personal/{key}", source="personal", text=dataset.read_text(txt), frames=frames,
                             hash=key, mp4=str(avi), split=dataset.split_for("me:" + key, 15)))
    return rows


def load_rows(a, tok_max_frames):
    rows = []
    public = rows_from_videos(a) if a.from_videos else T.load_manifest(Path(a.manifest))
    if a.from_videos and not a.personal_dir:  # a personal fine-tune only mixes public clips in as replay
        public = check_speakers(a, public)
    if a.public_limit:
        random.Random(a.seed).shuffle(public)
        dev_pub = [r for r in public if r["split"] == "dev"][:a.dev_n]
        public = [r for r in public if r["split"] == "train"][:a.public_limit] + dev_pub
    for r in public:
        if r["source"] != "public" or r["split"] not in ("train", "dev"):
            continue
        mp4 = Path(a.video_dir) / (r["id"].split("/", 1)[1] + ".mp4")
        if not mp4.exists() or not (10 <= r["frames"] <= tok_max_frames):
            continue
        rows.append(dict(r, mp4=str(mp4)))
    if a.personal_dir:
        own = [r for r in rows_personal(a) if 10 <= r["frames"] <= tok_max_frames]
        # personal dev replaces public dev: it is what best.pt should be picked on
        rows = [r for r in rows if r["split"] == "train"] + [r for r in own if r["split"] == "dev"]
        rows += [r for r in own if r["split"] == "train"] * a.personal_repeat
    if a.synth_frac:
        rows += [r for r in rows_synth(a) if 10 <= r["frames"] <= tok_max_frames]
    dev = sorted([r for r in rows if r["split"] == "dev"], key=lambda r: r["hash"])
    if any(r["source"] == "synth" for r in dev):
        raise SystemExit("[R2] synthetic clips in dev: dev must be held-out real channels only")
    return [r for r in rows if r["split"] == "train"], dev


def save_atomic(obj, path):
    tmp = path.with_suffix(".tmp")
    torch.save(obj, tmp)
    tmp.replace(path)


@torch.no_grad()
def eval_wer(a, dev, device):
    """WER of the base model and of best.pt on the same dev clips."""
    run_dir = Path(a.ckpt_dir) / a.run
    out = {}
    for name in ("base", "best"):
        ck = run_dir / "best.pt"
        if name == "best" and not ck.exists():
            break
        m = mvsr.MultiVSR(device=device, beam_size=a.beam, lora=str(ck) if name == "best" else None)
        if name == "best":
            m.venc.load_state_dict(torch.load(ck, map_location=device, weights_only=False)["venc"])
        pairs = []
        for r in dev[:a.n]:
            hyp, _ = m.transcribe_faces(mvsr.read_faces(r["mp4"]))
            pairs.append((r["text"], hyp))
        wer, cer = metrics.corpus_rates(pairs)
        out[name] = dict(wer=round(wer * 100, 1), cer=round(cer * 100, 1), n=len(pairs))
        print(f"{name}: WER {wer * 100:.1f}% CER {cer * 100:.1f}% on {len(pairs)} dev clips", flush=True)
        del m
        torch.cuda.empty_cache() if device == "cuda" else None
    (run_dir / "eval_wer.json").write_text(json.dumps(out, ensure_ascii=False))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", required=True)
    ap.add_argument("--manifest", default=str(ROOT / "data" / "manifest.jsonl"))
    ap.add_argument("--video-dir", default=str(ROOT / "data" / "public"), help="NAME.mp4 face crops of public clips")
    ap.add_argument("--from-videos", default=None, help="build the split from this clip folder instead of --manifest")
    ap.add_argument("--dev-pct", type=int, default=3, help="--from-videos: share of videos held out for dev, %%")
    ap.add_argument("--clips-dir", default=str(ROOT / "clips"), help="test phrases that must not be trained on")
    ap.add_argument("--ckpt-dir", default=str(ROOT / "checkpoints"))
    ap.add_argument("--device", default="auto")
    ap.add_argument("--lr", type=float, default=2e-4, help="LoRA")
    ap.add_argument("--venc-lr", type=float, default=3e-5, help="visual front-end, full weights")
    ap.add_argument("--rank", type=int, default=16)
    ap.add_argument("--alpha", type=float, default=32.0)
    ap.add_argument("--batch", type=int, default=4)
    ap.add_argument("--accum", type=int, default=8)
    ap.add_argument("--max-seconds", type=float, default=8.0)
    ap.add_argument("--max-steps", type=int, default=1500)
    ap.add_argument("--max-minutes", type=float, default=0)
    ap.add_argument("--warmup", type=int, default=100)
    ap.add_argument("--eval-every", type=int, default=100)
    ap.add_argument("--dev-n", type=int, default=150, help="dev clips for the loss that picks best.pt")
    ap.add_argument("--workers", type=int, default=6, help="video decoding processes")
    ap.add_argument("--chunk-batch", type=int, default=8, help="50-frame pieces per VTP call (memory vs speed)")
    ap.add_argument("--target-format", default="norm")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--init", default=None, help="start from this train_e2e best.pt (LoRA + VTP)")
    ap.add_argument("--personal-dir", default=None, help="comma-separated folders of the owner's NAME.avi + NAME.txt")
    ap.add_argument("--personal-repeat", type=int, default=1, help="repeat the owner's train clips this many times")
    ap.add_argument("--public-limit", type=int, default=0, help="at most N public train clips (0 = all)")
    ap.add_argument("--channel-map", default=str(ROOT / "harvester" / "video_channels.tsv"),
                    help="video_id<TAB>channel, written by the Mac feeder")
    ap.add_argument("--max-per-channel", type=int, default=0, help="R1: keep at most N clips per channel")
    ap.add_argument("--synth-dir", default=None, help="comma-separated folders of synth/gen.py clips (train only)")
    ap.add_argument("--synth-frac", type=float, default=0.0,
                    help="share of synthetic clips in each epoch, e.g. 0.3 (0 = off)")
    ap.add_argument("--save-last", action="store_true",
                    help="also save last.pt + last_venc.pth at every evaluation and the final step (best.pt depends on the "
                         "dev loss)")
    ap.add_argument("--eval-wer", action="store_true")
    ap.add_argument("--n", type=int, default=200)
    ap.add_argument("--beam", type=int, default=5)
    a = ap.parse_args()
    if not 0 <= a.synth_frac < 1 or (a.synth_frac and not a.synth_dir):
        ap.error("--synth-frac needs --synth-dir and must be in [0, 1)")

    device = mvsr.pick_device(a.device)
    global CHUNK_BATCH
    CHUNK_BATCH = a.chunk_batch
    random.seed(a.seed)
    torch.manual_seed(a.seed)
    train_rows, dev = load_rows(a, int(a.max_seconds * 25))
    print(f"train {len(train_rows)} clips, dev {len(dev)} clips (with video, <= {a.max_seconds} s)", flush=True)
    real_rows = [r for r in train_rows if r["source"] != "synth"]
    syn_rows = [r for r in train_rows if r["source"] == "synth"]
    if a.synth_frac and not syn_rows:
        sys.exit(f"--synth-frac {a.synth_frac}: no usable synthetic clips in {a.synth_dir}")
    print("train pool: " + mix_line(len(real_rows), sum(r["frames"] for r in real_rows), len(syn_rows),
                                    sum(r["frames"] for r in syn_rows)), flush=True)
    if a.eval_wer:
        return eval_wer(a, dev, device)
    if len(train_rows) < 100 or len(dev) < 10:
        sys.exit("too few clips with videos")

    long_run = a.max_steps > 60 or (a.max_minutes and a.max_minutes > 10)
    stamp, tag = smoke_key(a, device)
    if long_run and not stamp.exists():
        raise SystemExit(f"[R4] no smoke run for this code/GPU/batch ({tag}). Run the same command with "
                         f"--max-steps 30 first; it must finish without errors.")
    model, mv = T.build_base_model(device, torch.float32)
    tok = mv["tokenizer"]
    L.apply_lora(model, a.rank, a.alpha, 0.0)
    model = model.to(device)
    venc = mvsr.load_venc(device)
    if a.init:
        ck0 = torch.load(a.init, map_location="cpu", weights_only=False)
        L.load_lora_state_dict(model, ck0["lora"])
        venc.load_state_dict(ck0["venc"])
        print(f"init from {a.init} (step {ck0.get('step')})", flush=True)
    for p in venc.parameters():
        p.requires_grad_(True)

    def train_mode():
        model.train(), venc.train()
        # BatchNorm3d in the VTP front-end would re-estimate its statistics from a few clips and undo 845 h of them
        for m in venc.modules():
            if isinstance(m, torch.nn.modules.batchnorm._BatchNorm):
                m.eval()
    train_mode()
    groups = [dict(params=L.lora_params(model), lr=a.lr, base=a.lr),
              dict(params=list(venc.parameters()), lr=a.venc_lr, base=a.venc_lr)]
    opt = torch.optim.AdamW(groups, weight_decay=0.01)
    print(f"trainable: LoRA {sum(p.numel() for p in groups[0]['params']) / 1e6:.2f} M, "
          f"VTP {sum(p.numel() for p in groups[1]['params']) / 1e6:.2f} M", flush=True)

    ds = FaceClips(train_rows, tok, a.target_format, flip=True)
    sampler = MixSampler(train_rows, a.synth_frac, a.seed) if a.synth_frac else None
    if sampler:
        print(f"epoch: {len(sampler.real)} real + {sampler.n_syn} synthetic clips", flush=True)
    dl = torch.utils.data.DataLoader(ds, batch_size=a.batch, shuffle=sampler is None, sampler=sampler,
                                     num_workers=a.workers, collate_fn=collate, drop_last=True,
                                     persistent_workers=True, prefetch_factor=4)
    dev_ds = FaceClips(dev[:a.dev_n], tok, a.target_format, flip=False)
    dev_cache = [dev_ds[i] for i in range(len(dev_ds))]

    def dev_loss():
        model.eval(), venc.eval()
        tot = n = 0
        with torch.no_grad():
            for i in range(0, len(dev_cache), 8):
                f, t, _ = collate(dev_cache[i:i + 8])
                tot += float(forward_loss(venc, model, f, t, device)) * len(f)
                n += len(f)
        train_mode()
        return tot / n

    run_dir = Path(a.ckpt_dir) / a.run
    run_dir.mkdir(parents=True, exist_ok=True)

    def ckpt(step):
        return dict(lora=L.lora_state_dict(model), venc={k: v.detach().cpu() for k, v in venc.state_dict().items()},
                    config=dict(r=a.rank, alpha=a.alpha, targets="q,v", target_format=a.target_format, dtype="fp32",
                                e2e=True), step=step)

    best = dev_loss()
    print(f"step 0 dev loss {best:.4f}", flush=True)
    it = iter(dl)
    used = dict(n_real=0, f_real=0, n_syn=0, f_syn=0)
    t0 = time.time()
    for step in range(1, a.max_steps + 1):
        scale = step / a.warmup if step < a.warmup else \
            0.1 + 0.9 * 0.5 * (1 + math.cos(math.pi * (step - a.warmup) / max(1, a.max_steps - a.warmup)))
        for g in opt.param_groups:
            g["lr"] = g["base"] * scale
        opt.zero_grad(set_to_none=True)
        tot = 0.0
        for _ in range(a.accum):
            try:
                faces, toks, syn = next(it)
            except StopIteration:
                it = iter(dl)
                faces, toks, syn = next(it)
            for f, s in zip(faces, syn):
                used["n_syn" if s else "n_real"] += 1
                used["f_syn" if s else "f_real"] += f.shape[1]
            loss = forward_loss(venc, model, faces, toks, device) / a.accum
            loss.backward()
            tot += float(loss)
        torch.nn.utils.clip_grad_norm_([p for g in groups for p in g["params"]], 1.0)
        opt.step()
        if step % 10 == 0:
            el = time.time() - t0
            print(f"step {step}/{a.max_steps} loss {tot:.4f} {el / step:.2f} s/step", flush=True)
        if step % a.eval_every == 0 or step == a.max_steps:
            dl_ = dev_loss()
            mark = ""
            if dl_ < best:
                best, mark = dl_, " best"
                ck = ckpt(step)
                save_atomic({k: ck[k] for k in ("lora", "config", "step", "venc")}, run_dir / "best.pt")
                save_atomic({"state_dict": {"module.face_encoder." + k: v for k, v in ck["venc"].items()}},
                            run_dir / "best_venc.pth")
            if a.save_last and step < a.max_steps:  # a pod that dies loses at most eval_every steps
                ck = ckpt(step)
                save_atomic({k: ck[k] for k in ("lora", "config", "step", "venc")}, run_dir / "last.pt")
                save_atomic({"state_dict": {"module.face_encoder." + k: v for k, v in ck["venc"].items()}},
                            run_dir / "last_venc.pth")
            print(f"step {step} dev loss {dl_:.4f}{mark}", flush=True)
            print("trained on: " + mix_line(**used), flush=True)
        if a.max_minutes and time.time() - t0 > a.max_minutes * 60:
            print("time limit", flush=True)
            break
    if a.save_last:
        ck = ckpt(step)
        save_atomic({k: ck[k] for k in ("lora", "config", "step", "venc")}, run_dir / "last.pt")
        save_atomic({"state_dict": {"module.face_encoder." + k: v for k, v in ck["venc"].items()}},
                    run_dir / "last_venc.pth")
    (run_dir / "data_mix.json").write_text(json.dumps(dict(
        used, synth_frac=a.synth_frac, synth_dir=a.synth_dir, pool_real=len(real_rows), pool_synth=len(syn_rows),
        pool_real_h=round(hours(real_rows), 2), pool_synth_h=round(hours(syn_rows), 2))))
    (run_dir / "DONE").touch()
    if not long_run:
        stamp.parent.mkdir(parents=True, exist_ok=True)
        stamp.write_text(tag + "\n")
    print(f"done, best dev loss {best:.4f}", flush=True)


if __name__ == "__main__":
    main()
