"""Новый ключ подписи общего адаптера (Ed25519):

  uv run --with cryptography python federated/aggregator/keys.py [--repo zigansh1n/velikiy-moguchiy]

Закрытый ключ сразу уходит в секрет GitHub FL_MODEL_SIGNING_KEY через `gh secret set` (stdin) и нигде не
печатается и не сохраняется; открытый записывается в client/community_defaults.py, откуда его берёт приложение.
Версии, подписанные прежним ключом, приложение с новым ключом не примет.
"""
import argparse
import base64
import subprocess
import sys
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from space.deploy import write_defaults  # noqa: E402

ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
ap.add_argument("--repo", default="zigansh1n/velikiy-moguchiy")
a = ap.parse_args()
key = Ed25519PrivateKey.generate()
priv = key.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption())
pub = base64.b64encode(key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)).decode()
subprocess.run(["gh", "secret", "set", "FL_MODEL_SIGNING_KEY", "-R", a.repo], input=base64.b64encode(priv).decode(),
               text=True, check=True)
write_defaults(None, pub)
print(f"FL_MODEL_SIGNING_KEY задан в {a.repo}; открытый ключ {pub} записан в client/community_defaults.py — закоммитьте его")
