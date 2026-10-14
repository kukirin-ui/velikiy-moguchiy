"""Конвертер формата адаптера прогоняется окружением lipread (там есть torch); пропускается, если окружения нет."""
import json
import subprocess
from pathlib import Path

import numpy as np
import pytest

from protocol.adapter_io import load_adapter, save_adapter
from protocol.spec import init_adapter, load_spec

LIPREAD_PY = Path(__file__).resolve().parents[2] / "lipread" / ".venv" / "bin" / "python"
CONVERT = Path(__file__).resolve().parent.parent / "client" / "convert_adapter.py"
SPEC = Path(__file__).resolve().parent.parent / "protocol" / "specs" / "multivsr_lora_r16.json"


@pytest.mark.skipif(not LIPREAD_PY.exists(), reason="нет окружения lipread")
def test_roundtrip_through_lipread_pt_format(tmp_path):
    spec = load_spec(SPEC)
    ad = init_adapter(spec, 3)
    ad = {k: v + (0.01 if k.endswith(".B") else 0) for k, v in ad.items()}
    st, pt, st2 = tmp_path / "a.safetensors", tmp_path / "a.pt", tmp_path / "b.safetensors"
    save_adapter(ad, st)
    run = lambda *a: json.loads(subprocess.run([str(LIPREAD_PY), str(CONVERT), *a], capture_output=True, text=True, check=True).stdout.strip().splitlines()[-1])
    assert run("to-pt", str(st), str(pt))["tensors"] == 144
    assert run("from-pt", str(pt), str(st2))["tensors"] == 144
    back = load_adapter(st2)
    assert set(back) == set(ad) and all(np.array_equal(back[k], ad[k]) for k in ad)
    # формат совпадает с тем, что читает lipread/lora.py: {путь: {A, B}} и config.r
    check = subprocess.run([str(LIPREAD_PY), "-c",
                            f"import torch;c=torch.load('{pt}',weights_only=False);"
                            "print(len(c['lora']), c['config']['r'], sorted(next(iter(c['lora'].values()))))"],
                           capture_output=True, text=True, check=True).stdout.split()
    assert check[:2] == ["72", "16"]
