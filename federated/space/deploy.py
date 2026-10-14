"""Развернуть или обновить Space на Hugging Face вручную (запасной сервер приёма; Docker-Space требует подписки PRO).

  python -m space.deploy [--dry-run DIR]

Окружение: HF_TOKEN (запись), FL_SPACE (владелец/имя Space), FL_INBOX и FL_MODELS (hf:владелец/имя),
FL_TASK_SECRET, FL_MODEL_SIGNING_KEY (из него берётся только открытый ключ), необязательно FL_GITHUB_CLIENT_ID
и HF_SPACE_TOKEN — отдельный токен для самого Space с записью только в датасет входящих (иначе Space получит HF_TOKEN).

Что делает: создаёт закрытый датасет для входящих, открытый репозиторий модели и Space (Docker), если их нет;
кладёт в Space секреты и переменные; загружает код (Dockerfile, protocol/, hub/, space/, server/ratelimit.py);
печатает адрес Space и записывает его вместе с открытым ключом подписи в client/community_defaults.py.
"""
from __future__ import annotations

import argparse
import base64
import os
import shutil
import sys
import tempfile
from pathlib import Path


FED = Path(__file__).resolve().parent.parent
DEFAULTS = FED / "client" / "community_defaults.py"
SPACE_VARIABLES = ("FL_INBOX", "FL_MODELS", "FL_GITHUB_CLIENT_ID", "FL_POOL_PATH", "FL_EXCLUSIONS_URLS",
                   "FL_MIN_ACCOUNT_AGE_DAYS", "FL_MAX_UPDATES_PER_DAY", "FL_MAX_TASKS_PER_DAY", "FL_MAX_UPDATE_NORM",
                   "FL_VIDEOS_PER_TASK", "FL_BANNED_LOGINS", "FL_TRAINING_JSON")


def assemble(dst: Path) -> Path:
    for pkg in ("protocol", "hub", "space"):
        shutil.copytree(FED / pkg, dst / pkg, ignore=shutil.ignore_patterns("__pycache__", "*.pyc", "Dockerfile",
                                                                          "SPACE_README.md", "requirements.txt"))
    (dst / "server").mkdir()
    (dst / "server" / "__init__.py").write_text("")
    shutil.copy(FED / "server" / "ratelimit.py", dst / "server" / "ratelimit.py")
    shutil.copy(FED / "space" / "Dockerfile", dst / "Dockerfile")
    shutil.copy(FED / "space" / "requirements.txt", dst / "requirements.txt")
    shutil.copy(FED / "space" / "SPACE_README.md", dst / "README.md")
    return dst


def public_key_b64(private_b64: str) -> str:
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    raw = base64.b64decode(private_b64.strip(), validate=True)
    pub = Ed25519PrivateKey.from_private_bytes(raw).public_key()
    return base64.b64encode(pub.public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)).decode()


def write_defaults(url: str | None, key: str | None, path: Path = DEFAULTS) -> bool:
    """None keeps the current value."""
    text = path.read_text(encoding="utf8")
    lines = []
    for ln in text.splitlines():
        if ln.startswith("SERVER_URL = ") and url is not None:
            ln = f'SERVER_URL = "{url}"'
        elif ln.startswith("MODEL_SIGNING_PUBLIC_KEY = ") and key is not None:
            ln = f'MODEL_SIGNING_PUBLIC_KEY = "{key}"'
        lines.append(ln)
    new = "\n".join(lines) + "\n"
    if new == text:
        return False
    path.write_text(new, encoding="utf8")
    return True


def repo_name(spec: str) -> str:
    if not spec.startswith("hf:"):
        raise SystemExit(f"ожидалось hf:владелец/имя, а не {spec!r}")
    return spec[3:]


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry-run", metavar="DIR", help="только собрать папку Space в DIR")
    a = ap.parse_args(argv)
    if a.dry_run:
        assemble(Path(a.dry_run))
        print(f"папка Space: {a.dry_run}")
        return 0
    from huggingface_hub import HfApi

    env = os.environ
    api = HfApi(token=env["HF_TOKEN"])
    space = env["FL_SPACE"]
    api.create_repo(repo_name(env["FL_INBOX"]), repo_type="dataset", private=True, exist_ok=True)
    api.create_repo(repo_name(env["FL_MODELS"]), repo_type="model", private=False, exist_ok=True)
    api.create_repo(space, repo_type="space", space_sdk="docker", exist_ok=True)
    api.add_space_secret(space, "HF_TOKEN", env.get("HF_SPACE_TOKEN") or env["HF_TOKEN"])
    api.add_space_secret(space, "FL_TASK_SECRET", env["FL_TASK_SECRET"])
    for k in SPACE_VARIABLES:
        if env.get(k):
            api.add_space_variable(space, k, env[k])
    with tempfile.TemporaryDirectory() as td:
        api.upload_folder(repo_id=space, repo_type="space", folder_path=str(assemble(Path(td))),
                          commit_message="deploy from GitHub", delete_patterns="*")
    host = api.space_info(space).host or f"https://{space.replace('/', '-').replace('_', '-').replace('.', '-').lower()}.hf.space"
    changed = write_defaults(host, public_key_b64(env["FL_MODEL_SIGNING_KEY"]))
    print(f"Space: {host}" + ("; client/community_defaults.py обновлён" if changed else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
