import torch
for name in ["weights/model.pth", "weights/feature_extractor.pth"]:
    ck = torch.load(name, map_location="cpu", weights_only=False)
    for key in ["optimizer", "vis_optimizer"]:
        o = ck[key]
        if o is None: print(name, key, None); continue
        print(name, key, "n_state", len(o["state"]), "groups:")
        for g in o["param_groups"]:
            print("   ", {k: (v if k != "params" else f"{len(v)} params") for k, v in g.items()})
        if o["state"]:
            k0 = next(iter(o["state"])); st = o["state"][k0]
            print("    state keys", {k: (tuple(v.shape) if torch.is_tensor(v) else v) for k, v in st.items()})
