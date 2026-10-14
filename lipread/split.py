"""Deterministic train/dev split shared by dataset.py, train_e2e.py and the collection loop. No ML imports, so the
Mac can compute the same split train_e2e.py uses on a pod (memguard refuses ML runs on the Mac, R11)."""
import hashlib

SPLIT_SALT = "lipread-ru-split-v1"


def bucket(key: str) -> int:
    """Детерминированное число 0..99 из строки (разбиение train/dev)."""
    return int(hashlib.sha1((SPLIT_SALT + key).encode("utf8")).hexdigest()[:8], 16) % 100


def split_for(key: str, dev_pct: int) -> str:
    return "dev" if bucket(key) < dev_pct else "train"
