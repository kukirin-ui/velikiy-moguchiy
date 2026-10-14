"""ONE tiny MPS measurement: train step of the MultiVSR transformer, batch 1, 50 frames (2 s), 20 target tokens.
Configs run sequentially in one process: full FT fp32 / LoRA r=16 fp32 / LoRA r=16 bf16 weights.
Run: PYTORCH_MPS_HIGH_WATERMARK_RATIO=0.3 PYTORCH_ENABLE_MPS_FALLBACK=0 .venv/bin/python plan/bench/train_step_tiny.py
"""
import sys, time, gc, torch, torch.nn as nn, torch.nn.functional as F
sys.path.insert(0, "multivsr"); a = sys.argv; sys.argv = a[:1]
import models
dev = "mps"; models.set_amp(dev, False)
ck = torch.load("weights/model.pth", map_location="cpu", weights_only=False, mmap=True)["state_dict"]
sd = {(k[7:] if k.startswith("module.") else k): v for k, v in ck.items()}
GB = 1e9
def mem(): torch.mps.synchronize(); return torch.mps.current_allocated_memory() / GB, torch.mps.driver_allocated_memory() / GB

class LoRA(nn.Module):
    def __init__(s, base, r=16, alpha=32):
        super().__init__(); s.base = base; s.sc = alpha / r
        s.A = nn.Parameter(torch.randn(r, base.in_features) * 0.01); s.B = nn.Parameter(torch.zeros(base.out_features, r))
    def forward(s, x): return s.base(x) + (x @ s.A.t().to(x.dtype) @ s.B.t().to(x.dtype)) * s.sc

def build(mode, dtype):
    m = models.build_model(); m.load_state_dict(sd); 
    if mode == "lora":
        for p in m.parameters(): p.requires_grad_(False)
        for name, mod in list(m.named_modules()):
            if isinstance(mod, models.MultiHeadedAttention):
                mod.linears = nn.ModuleList([LoRA(l) if i in (0, 2) else l for i, l in enumerate(mod.linears)])  # q, v only
    m = m.to(dev).to(dtype)
    return m.train()

def step(m, dtype, opt):
    T, L = 50, 20
    src = torch.randn(1, T, 512, device=dev, dtype=dtype); smask = torch.ones(1, 1, T, device=dev, dtype=torch.long)
    tgt = torch.randint(0, 50000, (1, L), device=dev); tmask = models.__dict__.get("subsequent_mask", None)
    tm = (torch.triu(torch.ones(1, L, L, device=dev), 1) == 0)
    out = m(src, tgt[:, :-1], smask, tm[:, :-1, :-1])
    loss = F.cross_entropy(out.float(), tgt[:, 1:].reshape(-1))
    loss.backward(); opt.step(); opt.zero_grad(set_to_none=True)
    return loss.item()

for mode, dtype in [("full", torch.float32), ("lora", torch.float32), ("lora", torch.bfloat16)]:
    m = build(mode, dtype); tr = [p for p in m.parameters() if p.requires_grad]
    n_tr = sum(p.numel() for p in tr); opt = torch.optim.Adam(tr, lr=1e-5 if mode == "full" else 1e-4)
    m0 = mem()
    try:
        step(m, dtype, opt); torch.mps.synchronize(); t0 = time.perf_counter()
        for _ in range(3): l = step(m, dtype, opt)
        torch.mps.synchronize(); dt = (time.perf_counter() - t0) / 3
        print(f"{mode} {str(dtype)[6:]}: trainable {n_tr/1e6:.2f}M; after-load alloc {m0[0]:.2f} GB; after steps alloc {mem()[0]:.2f} GB, driver {mem()[1]:.2f} GB; {dt*1000:.0f} ms/step (B=1,2s); loss {l:.2f}", flush=True)
    except Exception as e:
        print(mode, dtype, "FAILED", type(e).__name__, str(e)[:300], flush=True)
    del m, opt, tr; gc.collect(); torch.mps.empty_cache()
