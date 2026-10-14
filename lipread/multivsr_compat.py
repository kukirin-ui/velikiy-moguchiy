"""Makes a MultiVSR checkout run on Apple Silicon (MPS) and on the CPU.

MultiVSR (https://github.com/Sindhu-Hegde/multivsr, Oxford VGG) has no license, so this repository
carries none of its code. setup.sh clones it from the authors at PINNED_COMMIT, and this script then
edits that local copy on your machine. What changes (see README, «Что изменено в коде MultiVSR для Mac»):

- config.py: --device defaults to cuda, then mps, then cpu; --fp16 defaults to on only for cuda;
- models.py: the hard-coded @autocast('cuda') becomes a switchable `amp` / `set_amp(device, enabled)`;
- inference.py: autocast by device type, no_grad around the encoders, torch.load(weights_only=True) with a
  fallback, frames read through ffmpeg (video_io.py) when decord is missing (it has no macOS arm64 wheel);
- preprocess/: S3FD on any device (cpu by default), weights path independent of the working directory,
  no index_select(out=) (fails on MPS);
- video_io.py (new, our code): an ffmpeg frame reader with the same 160x160 scaling as decord.

Each file is touched only when it still needs it: a file already in the edited state is left alone, a file
at the pinned commit is edited and then checked against the expected SHA-256, and a file in any other state
(edited by hand, another commit) is reported and not touched. The result is byte-for-byte the tree the
pipeline was developed and evaluated on.

    python3 multivsr_compat.py [multivsr_dir]      # default: ./multivsr next to this file
    python3 multivsr_compat.py --check [dir]       # report only; exit 1 if anything still needs editing
"""
import hashlib
import sys
from pathlib import Path

PINNED_COMMIT = "af28d8c4b687ee7e41942732eb240e0cdfff3ccd"

# (file, text at the pinned commit, its replacement). Each `find` occurs exactly once in its file.
EDITS = [
    ('config.py',
     'import configargparse\n',
     "import configargparse\n\ndef default_device():\n  # Apple Silicon patch: prefer CUDA if present, then MPS, else CPU (original hard-coded 'cuda').\n  import torch\n  if torch.cuda.is_available(): return 'cuda'\n  if getattr(torch.backends, 'mps', None) is not None and torch.backends.mps.is_available(): return 'mps'\n  return 'cpu'\n"),
    ('config.py',
     "        raise argparse.ArgumentTypeError('Boolean value expected.')\n",
     "        raise configargparse.ArgumentTypeError('Boolean value expected.')\n"),
    ('config.py',
     "  parser.add_argument('--device', type=str, default='cuda')\n",
     '  parser.add_argument(\'--device\', type=str, default=default_device(), help="cuda | mps | cpu (default: auto)")\n'),
    ('config.py',
     "  parser.add_argument('--fp16', default=True, type=str2bool)\n",
     "  parser.add_argument('--fp16', default=None, type=str2bool, help='autocast to fp16; default: on for cuda only (fp32 on mps/cpu)')\n"),
    ('config.py',
     '  args = parser.parse_args()\n',
     "  args = parser.parse_args()\n  if args.fp16 is None: args.fp16 = (args.device == 'cuda')\n"),
    ('inference.py',
     'from models import build_model, build_visual_encoder\n',
     'from models import build_model, build_visual_encoder, set_amp\n'),
    ('inference.py',
     'from decord import VideoReader\n',
     'try:  # Apple Silicon patch: decord has no macOS arm64 wheel -> ffmpeg-based reader with identical scaling\n\tfrom decord import VideoReader\nexcept ImportError:\n\tVideoReader = None\n\tfrom video_io import read_rgb_frames\n'),
    ('inference.py',
     'args = load_args()\n',
     'args = load_args()\nset_amp(args.device, args.fp16)\n'),
    ('inference.py',
     '\t\tfeats = visual_encoder(chunk_faces)\n',
     '\t\twith torch.no_grad():\n\t\t\tfeats = visual_encoder(chunk_faces)\n'),
    ('inference.py',
     '\t\tencoder_output, src_mask = model.encode(feats, src_mask)\n',
     '\t\twith torch.no_grad():\n\t\t\tencoder_output, src_mask = model.encode(feats, src_mask)\n'),
    ('inference.py',
     "\t\t\twith autocast('cuda', enabled=args.fp16):\n",
     '\t\t\twith autocast(torch.device(args.device).type, enabled=args.fp16):\n'),
    ('inference.py',
     '\tprint("-------------------------------------------------------------------")\n\n\n',
     '\tprint("-------------------------------------------------------------------")\n\n\ndef load_ckpt(path, device):\n\t# torch>=2.6 defaults to weights_only=True; fall back to a full unpickle only for the\n\t# authors\' own checkpoints if they contain non-tensor objects.\n\ttry:\n\t\treturn torch.load(path, map_location=device, weights_only=True)\n\texcept Exception as e:\n\t\tprint(f"[patch] weights_only load failed for {path} ({type(e).__name__}); retrying with weights_only=False")\n\t\treturn torch.load(path, map_location=device, weights_only=False)\n\n'),
    ('inference.py',
     '\tcheckpoint = torch.load(args.ckpt_path, map_location=args.device)\n',
     '\tcheckpoint = load_ckpt(args.ckpt_path, args.device)\n'),
    ('inference.py',
     '\ts = torch.load(args.visual_encoder_ckpt_path, map_location=args.device)["state_dict"]\n',
     '\ts = load_ckpt(args.visual_encoder_ckpt_path, args.device)["state_dict"]\n'),
    ('inference.py',
     "\twith open(fpath, 'rb') as f:\n\t\tvideo_stream = VideoReader(f, width=160, height=160)\n",
     "\tif VideoReader is None:\n\t\tall_frames = read_rgb_frames(fpath, 160, 160)\n\t\tend = min(end, len(all_frames))\n\t\tframes = all_frames[int(start):int(end)].astype(np.float32)\n\telse:\n\t\twith open(fpath, 'rb') as f:\n\t\t\tvideo_stream = VideoReader(f, width=160, height=160)\n"),
    ('inference.py',
     '\t\tend = min(end, len(video_stream))\n',
     '\t\t\tend = min(end, len(video_stream))\n'),
    ('inference.py',
     '\t\tframes = video_stream.get_batch(list(range(int(start), int(end)))).asnumpy().astype(np.float32)\n',
     '\t\t\tframes = video_stream.get_batch(list(range(int(start), int(end)))).asnumpy().astype(np.float32)\n'),
    ('models.py',
     'from linear_attention_transformer import LinearAttentionTransformer\n',
     'from linear_attention_transformer import LinearAttentionTransformer\nimport functools\n'),
    ('models.py',
     'mask_value = -1e9\n',
     'mask_value = -1e9\n\n# --- Apple Silicon / CPU patch -------------------------------------------------\n# The original code hard-codes @autocast(\'cuda\') on several forward() methods (always on, i.e.\n# fp16 on CUDA). We make the autocast device type and on/off switch configurable at runtime:\n# set_amp(device, enabled) is called once by inference.py / our wrapper. Default: disabled (fp32).\n_AMP = {"device_type": "cpu", "enabled": False}\n\ndef set_amp(device, enabled):\n    dt = torch.device(device).type\n    _AMP["device_type"] = dt\n    _AMP["enabled"] = bool(enabled) and dt in ("cuda", "mps")\n\ndef amp(fn):\n    @functools.wraps(fn)\n    def wrapper(*a, **kw):\n        with autocast(_AMP["device_type"], enabled=_AMP["enabled"]):\n            return fn(*a, **kw)\n    return wrapper\n'),
    ('models.py',
     "    with autocast('cuda', enabled=False):\n",
     '    with autocast(_AMP["device_type"], enabled=False):\n'),
    ('models.py',
     "            Conv3d(512, d_model, kernel_size=(1, 3, 3), stride=1, padding=(0, 0, 0)),)\n\n    @autocast('cuda')\n",
     '            Conv3d(512, d_model, kernel_size=(1, 3, 3), stride=1, padding=(0, 0, 0)),)\n\n    @amp\n'),
    ('models.py',
     "        self.encoder = nn.Sequential(*layers)\n\n    @autocast('cuda')\n",
     '        self.encoder = nn.Sequential(*layers)\n\n    @amp\n'),
    ('models.py',
     "        self.encoder = encoder\n\n    @autocast('cuda')\n",
     '        self.encoder = encoder\n\n    @amp\n'),
    ('models.py',
     "            cur_dim = dim\n\n    @autocast('cuda')\n",
     '            cur_dim = dim\n\n    @amp\n'),
    ('preprocess/detectors/s3fd/__init__.py',
     "PATH_WEIGHT = './detectors/s3fd/weights/sfd_face.pth'\n",
     "import os\nPATH_WEIGHT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'weights', 'sfd_face.pth')  # patch: no dependency on cwd\n"),
    ('preprocess/detectors/s3fd/__init__.py',
     "    def __init__(self, device='cuda'):\n",
     "    def __init__(self, device='cpu'):\n"),
    ('preprocess/detectors/s3fd/box_utils.py',
     '        torch.index_select(x1, 0, idx, out=xx1)\n        torch.index_select(y1, 0, idx, out=yy1)\n        torch.index_select(x2, 0, idx, out=xx2)\n        torch.index_select(y2, 0, idx, out=yy2)\n',
     '        xx1 = torch.index_select(x1, 0, idx)  # patch: no out= (deprecated; fails on MPS)\n        yy1 = torch.index_select(y1, 0, idx)  # patch: no out= (deprecated; fails on MPS)\n        xx2 = torch.index_select(x2, 0, idx)  # patch: no out= (deprecated; fails on MPS)\n        yy2 = torch.index_select(y2, 0, idx)  # patch: no out= (deprecated; fails on MPS)\n'),
    ('preprocess/detectors/s3fd/box_utils.py',
     '        w.resize_as_(xx2)\n        h.resize_as_(yy2)\n',
     ''),
    ('preprocess/detectors/s3fd/nets.py',
     "    def __init__(self, device='cuda'):\n",
     "    def __init__(self, device='cpu'):\n"),
    ('preprocess/detectors/s3fd/nets.py',
     '            self.priors.type(type(x.data)).to(self.device)\n',
     '            self.priors.to(device=x.device, dtype=x.dtype)\n'),
    ('preprocess/run_pipeline.py',
     "parser.add_argument('--min_face_size',  type=int, default=25,  help='Minimum face size in pixels');\n",
     "parser.add_argument('--min_face_size',  type=int, default=25,  help='Minimum face size in pixels');\nparser.add_argument('--device',         type=str, default='cpu', help='Device for the S3FD face detector: cuda | cpu (mps gives wrong boxes)');\n"),
    ('preprocess/run_pipeline.py',
     "  DET = S3FD(device='cuda')\n",
     '  DET = S3FD(device=opt.device)\n'),
]

# SHA-256 of every file at the pinned commit and after the edits.
ORIGINAL = {
    'config.py': 'ec3af7455fed7d2900887b60d5306b30b66a88734b347afa52daf482cce1d0b4',
    'inference.py': '8967a0c13cd5af683bda61df95bb113717cc141d038a84544ab4011e06d084d7',
    'models.py': '837002bd29fcc902955f1d55e179600a6c1a1b2e0b0ea5e7b71ca4b0fc40f10f',
    'preprocess/detectors/s3fd/__init__.py': '7a08a66d67f26328e045d182d4827115a9ef3a5dc1b9edc6014d1f43fcdf67d0',
    'preprocess/detectors/s3fd/box_utils.py': '10bf21754804d3a6f010f4235b657cde027e8d3ee9267c2628d5fba2aada21b8',
    'preprocess/detectors/s3fd/nets.py': '3e9dad22a2f1234014b46e4f96f46d5ff578d524eb332d063a69a476924f0ee5',
    'preprocess/run_pipeline.py': '7dee3592632a69c8d91db7d9c915b7f19a64f0ec6ec8c79a8dc38211ec8c80b0',
}
EDITED = {
    'config.py': 'c880a399486cd5a3d85d8a5b3ab24985efb35a1a0c27ce86fd0cf8177bf17e17',
    'inference.py': 'b8bb5400e30c5e7da9d6a04f41b3a82367d89f8243dc1df2a8afd990335aaad5',
    'models.py': 'aac2cee4944ca6ae7164766c855f4fdc6a22d18ad6dc3382e008d42647889f1a',
    'preprocess/detectors/s3fd/__init__.py': '39d0cb33ec01ebc49a022768d93f1c1498146beec119d59dd8c557a236349af8',
    'preprocess/detectors/s3fd/box_utils.py': '156455ed4e8b100248980db6a61fccb2d831d640bfa217c9da9fc188a7ed7695',
    'preprocess/detectors/s3fd/nets.py': 'd61721ac7d51c55ec37bb3bf9865d190a1d2569160a9974452ad484dd33952c7',
    'preprocess/run_pipeline.py': '12007cd4d534ebe2129f962bd1222f051a5c3212f34cb673e7e26d6b06ce89cf',
    'video_io.py': '8ad072e6af3f70e222dd965ec06197b4de55a18d7bb013462d4906b559d5a902',
}

VIDEO_IO = '"""Frame reader used instead of decord (decord has no wheel for macOS arm64 / Python 3.13).\n\ndecord.VideoReader(width=W, height=H) decodes with ffmpeg and resizes through the libavfilter\n`scale=W:H` filter (default swscale flags, bicubic) into RGB24. We reproduce exactly that with the\nffmpeg CLI, so the 160x160 frames are the same as in the original pipeline.\n"""\nimport subprocess\nimport numpy as np\n\n\ndef read_rgb_frames(path, width=160, height=160):\n    """Returns uint8 array (N, height, width, 3), RGB, every decoded frame of the first video stream."""\n    cmd = ["ffmpeg", "-v", "error", "-i", path, "-an", "-vf", f"scale={width}:{height}",\n           "-f", "rawvideo", "-pix_fmt", "rgb24", "-"]\n    out = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)\n    if out.returncode != 0:\n        raise RuntimeError(f"ffmpeg failed on {path}: {out.stderr.decode(errors=\'replace\')}")\n    buf = np.frombuffer(out.stdout, dtype=np.uint8)\n    return buf.reshape(-1, height, width, 3)\n'


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def edited_text(name, text):
    for file, find, replace in EDITS:
        if file != name:
            continue
        if text.count(find) != 1:
            raise ValueError(f"{name}: expected text not found once: {find.strip()[:60]!r}")
        text = text.replace(find, replace)
    return text


def main(argv):
    check = "--check" in argv
    args = [a for a in argv if a != "--check"]
    root = Path(args[0]) if args else Path(__file__).resolve().parent / "multivsr"
    if not root.is_dir():
        print(f"multivsr_compat: no MultiVSR checkout at {root} (run ./setup.sh)")
        return 1
    pending, problems = [], []
    for name, done in EDITED.items():
        path = root / name
        if path.exists() and sha256(path) == done:
            continue
        if name == "video_io.py" and not path.exists():
            pending.append(name)
        elif name in ORIGINAL and path.exists() and sha256(path) == ORIGINAL[name]:
            pending.append(name)
        else:
            problems.append(name)
    for name in problems:
        print(f"multivsr_compat: {name} differs from both the pinned commit and the edited version; left as is")
    if check or not pending:
        state = "needs editing: " + ", ".join(pending) if pending else "up to date"
        print(f"multivsr_compat: {root} {state}")
        return 1 if (pending or problems) else 0
    for name in pending:
        path = root / name
        if name == "video_io.py":
            text = VIDEO_IO
        else:
            text = edited_text(name, path.read_text(encoding="utf-8"))
        if hashlib.sha256(text.encode("utf-8")).hexdigest() != EDITED[name]:
            raise SystemExit(f"multivsr_compat: {name}: the edit did not give the expected file; nothing written")
        path.write_text(text, encoding="utf-8")
        print(f"multivsr_compat: edited {name}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
