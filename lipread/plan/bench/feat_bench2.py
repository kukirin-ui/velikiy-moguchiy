"""VTP features on MPS: fp32 vs fp16/bf16 (weights cast, real cast not the no-op autocast), batch scaling, memory.
Run: PYTORCH_ENABLE_MPS_FALLBACK=0 .venv/bin/python plan/bench/feat_bench2.py
"""
import sys, time, glob, copy, gc
import numpy as np, torch
sys.path.insert(0, "multivsr"); a = sys.argv; sys.argv = a[:1]
import models, video_io
dev = "mps"; models.set_amp(dev, False)
v32 = models.build_visual_encoder()
sd = torch.load("weights/feature_extractor.pth", map_location="cpu", weights_only=False)["state_dict"]
v32.load_state_dict({k.replace("module.face_encoder.", ""): x for k, x in sd.items() if "face_encoder" in k}); v32 = v32.eval()
def sync(): torch.mps.synchronize()
def load(p):
    fr = video_io.read_rgb_frames(p, 160, 160).astype(np.float32) / 255.0
    return torch.from_numpy(fr).unsqueeze(0).permute(0, 4, 1, 2, 3)[:, :, :, 32:128, 32:128].contiguous()
files = sorted(glob.glob("work/faces/*.avi")); clips = [load(f) for f in files]
secs = sum(c.shape[2] for c in clips) / 25
def run(dtype, tag):
    v = copy.deepcopy(v32).to(dev).to(dtype); outs = []
    with torch.no_grad():
        for _ in range(2): v(clips[0].to(dev, dtype))
        sync(); t0 = time.perf_counter()
        for c in clips: outs.append(v(c.to(dev, dtype)).float().cpu())
        sync(); dt = time.perf_counter() - t0
    print(f"[{tag}] B=1: {secs/dt:.1f} s video / s wall ({dt:.2f}s for {secs:.0f}s)", flush=True)
    del v; gc.collect(); torch.mps.empty_cache(); return outs
ref = run(torch.float32, "fp32")
for dt_, tag in [(torch.float16, "fp16"), (torch.bfloat16, "bf16")]:
    try:
        o = run(dt_, tag)
        cs = np.mean([torch.nn.functional.cosine_similarity(x.reshape(-1, 512), y.reshape(-1, 512), dim=1).mean().item() for x, y in zip(ref, o)])
        rel = np.mean([((x - y).norm() / x.norm()).item() for x, y in zip(ref, o)])
        print(f"    {tag} vs fp32: cos {cs:.5f}, rel L2 {rel:.4f}", flush=True)
    except Exception as e: print(tag, "FAILED", type(e).__name__, str(e)[:300], flush=True)
v = v32.to(dev)
with torch.no_grad():
    for B in (1, 4, 8, 16):
        T = 100; x = torch.rand(B, 3, T, 96, 96, device=dev); v(x); sync(); torch.mps.empty_cache()
        t0 = time.perf_counter()
        for _ in range(3): f = v(x)
        sync(); d = (time.perf_counter() - t0) / 3
        print(f"fp32 batched B={B} T={T}: {B*T/25/d:.1f} s video / s wall; driver mem {torch.mps.driver_allocated_memory()/1e9:.1f} GB", flush=True)
