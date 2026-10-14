"""Params / ckpt structure of MultiVSR. CPU only. Run: .venv/bin/python plan/bench/inspect_ckpt.py"""
import sys, collections, torch
sys.path.insert(0, "multivsr"); a = sys.argv; sys.argv = a[:1]
import models
for name in ["weights/model.pth", "weights/feature_extractor.pth"]:
    ck = torch.load(name, map_location="cpu", weights_only=False)
    print("==", name, type(ck), list(ck.keys()) if isinstance(ck, dict) else "")
    for k, v in ck.items():
        if k != "state_dict":
            print("  extra key:", k, type(v), (str(v)[:200] if not hasattr(v, "keys") else list(v.keys())[:10]))
    sd = ck["state_dict"]
    tot = sum(v.numel() for v in sd.values() if torch.is_tensor(v))
    print("  state_dict tensors:", len(sd), "numel:", tot, "dtype set:", {str(v.dtype) for v in sd.values() if torch.is_tensor(v)})
    pre = collections.Counter(".".join(k.split(".")[:2]) for k in sd)
    print("  prefixes:", dict(list(pre.items())[:25]))
m = models.build_model(); v = models.build_visual_encoder()
def cnt(mod): return sum(p.numel() for p in mod.parameters())
print("MODEL total", cnt(m))
for n in ["encoder", "decoder", "src_embed", "tgt_embed", "generator"]:
    print("  ", n, cnt(getattr(m, n)))
print("  encoder layer", cnt(m.encoder.layers[0]), " decoder layer", cnt(m.decoder.layers[0]))
print("  tgt_embed lut", m.tgt_embed[0].lut.weight.shape, " generator", m.generator.proj.weight.shape)
print("  attn per layer:", cnt(m.encoder.layers[0].self_attn), " ff:", cnt(m.encoder.layers[0].feed_forward))
print("VTP total", cnt(v), " feat_extrator(CNN3d)", cnt(v.feat_extrator), " VTP transformer", cnt(v.encoder), "hwpos", cnt(v.hwposition), "pooler", cnt(v.pooler))
# is generator tied to embedding?
print("tied?", m.generator.proj.weight.data_ptr()==m.tgt_embed[0].lut.weight.data_ptr())
