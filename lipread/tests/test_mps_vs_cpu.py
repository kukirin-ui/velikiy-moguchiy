"""Случайные веса одной и той же модели: MPS даёт те же числа, что CPU, без PYTORCH_ENABLE_MPS_FALLBACK.
Запуск: PYTORCH_ENABLE_MPS_FALLBACK=0 uv run python tests/test_mps_vs_cpu.py"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import torch, time
from mvsr import MultiVSR
torch.manual_seed(0)
m = MultiVSR(device="cpu", random_weights=True)
x = torch.rand(1, 3, 100, 96, 96)
with torch.no_grad():
    f_cpu = m.venc(x); e_cpu,_ = m.model.encode(f_cpu, torch.ones(1,1,100).long())
    tgt = torch.tensor([[50258, 50263, 5, 6, 7]])
    from dataloader import subsequent_mask
    d_cpu = m.model.decode(e_cpu, torch.ones(1,1,100).long(), tgt, subsequent_mask(5).long())
m.model.to("mps"); m.venc.to("mps")
import models; models.set_amp("mps", False)
with torch.no_grad():
    f = m.venc(x.to("mps")); e,_ = m.model.encode(f, torch.ones(1,1,100).long().to("mps"))
    d = m.model.decode(e, torch.ones(1,1,100).long().to("mps"), tgt.to("mps"), subsequent_mask(5).long().to("mps"))
for n,a,b in [("venc",f_cpu,f),("enc",e_cpu,e),("dec",d_cpu,d)]:
    b=b.cpu(); print(n, "max abs diff", (a-b).abs().max().item(), "ref scale", a.abs().mean().item())
agree = (d_cpu.argmax(-1)==d.cpu().argmax(-1)).float().mean().item()
print("top1 agree:", agree)
assert agree == 1.0 and (d_cpu - d.cpu()).abs().max() < 1e-3
print("mps vs cpu: ok")
