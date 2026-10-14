"""Signs a lips model release for the Mac app: SHA256SUMS.txt.sig next to SHA256SUMS.txt.

    FL_MODEL_SIGNING_KEY=... python3 tools/models/sign_lips_release.py lips-0.2 SHA256SUMS.txt
    python3 tools/models/sign_lips_release.py --verify lips-0.2 SHA256SUMS.txt [SHA256SUMS.txt.sig]

The key is the project's model-signing key (base64 of the raw 32-byte Ed25519 private key), the one that also
signs community adapter versions (federated/aggregator). The app pins its public half
(mac/MacApp/VelikiyMoguchiy/LipData/SPLipsRuntimePolicy.m) and refuses releases after lips-0.1 without a valid
signature. Upload the .sig file to the GitHub release and to the Hugging Face mirror together with SHA256SUMS.txt.
"""
from __future__ import annotations

import argparse
import base64
import os
import sys
from pathlib import Path

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey

DOMAIN = b"velikiy-moguchiy/lips-release/v1\n"
PUBLIC_KEY = "MqbG8ht29PUCKCdki4D6yfi6OJuovhXwC6EN44QWtag="


def message(tag: str, sums: bytes) -> bytes:
    return DOMAIN + tag.encode() + b"\n" + sums


def sign(tag: str, sums: bytes, private_b64: str) -> str:
    key = Ed25519PrivateKey.from_private_bytes(base64.b64decode(private_b64, validate=True))
    return base64.b64encode(key.sign(message(tag, sums))).decode() + "\n"


def verify(tag: str, sums: bytes, signature_b64: str, public_b64: str = PUBLIC_KEY) -> bool:
    key = Ed25519PublicKey.from_public_bytes(base64.b64decode(public_b64, validate=True))
    try:
        key.verify(base64.b64decode(signature_b64.strip(), validate=True), message(tag, sums))
        return True
    except InvalidSignature:
        return False


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--verify", action="store_true", help="check an existing signature against the pinned key")
    ap.add_argument("tag", help="release tag, e.g. lips-0.2")
    ap.add_argument("sums", type=Path, help="SHA256SUMS.txt exactly as published")
    ap.add_argument("signature", type=Path, nargs="?", help="default: <sums>.sig")
    a = ap.parse_args(argv)
    sig_path = a.signature or a.sums.with_name(a.sums.name + ".sig")
    sums = a.sums.read_bytes()
    if a.verify:
        ok = verify(a.tag, sums, sig_path.read_text())
        print(f"{sig_path}: {'OK' if ok else 'BAD signature'}")
        return 0 if ok else 1
    private = os.environ.get("FL_MODEL_SIGNING_KEY")
    if not private:
        print("FL_MODEL_SIGNING_KEY is not set", file=sys.stderr)
        return 2
    sig_path.write_text(sign(a.tag, sums, private))
    print(f"wrote {sig_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
