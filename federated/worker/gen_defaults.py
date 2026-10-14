"""Пишет worker/src/defaults.json из кода на Python, чтобы у Worker и Space была одна спецификация адаптера,
одни настройки обучения в задании и одни закреплённые файлы:

  python worker/gen_defaults.py          (из federated/; tests/test_worker_compat.py проверяет, что файл свежий)
"""
import json
import sys
from pathlib import Path

FED = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(FED))

from hub.tasks import DEFAULT_TRAINING  # noqa: E402
from protocol.spec import load_spec  # noqa: E402
from space.settings import DEFAULT_ASSETS, DEFAULT_EXCLUSIONS  # noqa: E402

OUT = Path(__file__).resolve().parent / "src" / "defaults.json"


def render() -> str:
    spec = load_spec(FED / "protocol" / "specs" / "multivsr_lora_r16.json")
    doc = {"spec": {"spec_id": spec.spec_id, "spec_hash": spec.hash, "max_payload_bytes": spec.max_payload_bytes(),
                    "tensors": [{"name": t.name, "shape": t.shape} for t in spec.delta_tensors]},
           "training": DEFAULT_TRAINING, "assets": DEFAULT_ASSETS, "exclusions_url": DEFAULT_EXCLUSIONS}
    return json.dumps(doc, ensure_ascii=False, indent=1) + "\n"


if __name__ == "__main__":
    OUT.write_text(render(), encoding="utf8")
    print(OUT)
