"""Хранилища на Hugging Face: репозиторий-датасет (закрытый) для входящих обновлений и служебных записей и
репозиторий модели (открытый) для версий адаптера. Для тестов и локального запуска то же самое на каталоге.

BlobStore — минимальный общий интерфейс: прочитать файл, перечислить файлы, одним коммитом добавить и удалить.
"""
from __future__ import annotations

import os
import shutil
from pathlib import Path
from typing import Iterable, Protocol


class BlobStore(Protocol):
    def read(self, path: str) -> bytes | None: ...
    def list(self, prefix: str = "") -> list[str]: ...
    def commit(self, adds: dict[str, bytes], deletes: Iterable[str] = (), message: str = "") -> None: ...
    def squash(self) -> None: ...


def _check_path(path: str) -> str:
    parts = path.strip("/").split("/")
    if not path or path.startswith("/") or any(p in ("", ".", "..") for p in parts):
        raise ValueError(f"недопустимый путь в хранилище: {path!r}")
    return path


class LocalBlobStore:
    """Каталог на диске. deletes: путь файла или каталога (с «/» на конце)."""

    def __init__(self, root: Path):
        self.root = Path(root)

    def read(self, path: str) -> bytes | None:
        p = self.root / _check_path(path)
        return p.read_bytes() if p.is_file() else None

    def list(self, prefix: str = "") -> list[str]:
        if not self.root.exists():
            return []
        out = []
        for p in self.root.rglob("*"):
            if p.is_file() and not p.name.endswith(".tmp"):
                rel = p.relative_to(self.root).as_posix()
                if rel.startswith(prefix):
                    out.append(rel)
        return sorted(out)

    def commit(self, adds: dict[str, bytes], deletes: Iterable[str] = (), message: str = "") -> None:
        for path in deletes:
            p = self.root / _check_path(path)
            if p.is_dir():
                shutil.rmtree(p)
            else:
                p.unlink(missing_ok=True)
        for path, data in adds.items():
            p = self.root / _check_path(path)
            p.parent.mkdir(parents=True, exist_ok=True)
            tmp = p.with_name(p.name + ".tmp")
            tmp.write_bytes(data)
            os.replace(tmp, p)

    def squash(self) -> None:
        """A directory has no history to squash."""


class HfBlobStore:
    """Репозиторий на Hugging Face через huggingface_hub. Каждый commit() — один коммит репозитория."""

    def __init__(self, repo_id: str, repo_type: str, token: str | None, *, api=None, revision: str = "main"):
        if api is None:
            from huggingface_hub import HfApi
            api = HfApi(token=token)
        self.api, self.repo_id, self.repo_type, self.token, self.revision = api, repo_id, repo_type, token, revision

    def _missing(self) -> tuple[type[BaseException], ...]:
        errs: list[type[BaseException]] = [FileNotFoundError]
        try:
            from huggingface_hub.utils import EntryNotFoundError
            errs.append(EntryNotFoundError)
        except ImportError:
            pass
        return tuple(errs)

    def read(self, path: str) -> bytes | None:
        try:
            local = self.api.hf_hub_download(repo_id=self.repo_id, filename=_check_path(path), repo_type=self.repo_type,
                                             revision=self.revision, token=self.token)
        except self._missing():
            return None
        return Path(local).read_bytes()

    def list(self, prefix: str = "") -> list[str]:
        files = self.api.list_repo_files(repo_id=self.repo_id, repo_type=self.repo_type, revision=self.revision,
                                         token=self.token)
        return sorted(f for f in files if f.startswith(prefix))

    def commit(self, adds: dict[str, bytes], deletes: Iterable[str] = (), message: str = "") -> None:
        from huggingface_hub import CommitOperationAdd, CommitOperationDelete
        ops = [CommitOperationDelete(path_in_repo=_check_path(p), is_folder=p.endswith("/")) for p in deletes]
        ops += [CommitOperationAdd(path_in_repo=_check_path(p), path_or_fileobj=data) for p, data in adds.items()]
        if ops:
            self.api.create_commit(repo_id=self.repo_id, repo_type=self.repo_type, operations=ops,
                                   commit_message=message or "update", revision=self.revision, token=self.token)


    def squash(self) -> None:
        """Схлопнуть историю репозитория в один коммит: удалённые файлы пропадают и из истории."""
        self.api.super_squash_history(repo_id=self.repo_id, repo_type=self.repo_type, branch=self.revision,
                                      commit_message="squash", token=self.token)


def open_store(spec: str, token: str | None, repo_type: str) -> BlobStore:
    """'hf:owner/name' -> репозиторий Hugging Face, 'dir:/path' или просто путь -> каталог."""
    if spec.startswith("hf:"):
        return HfBlobStore(spec[3:], repo_type, token)
    return LocalBlobStore(Path(spec[4:] if spec.startswith("dir:") else spec))
