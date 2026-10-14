"""Входящие обновления в закрытом датасете Hugging Face.

  pending/<логин>/v<база:06d>-<unix-время>-<sha256 нагрузки[:16]>/
      manifest.json        подписанный манифест (протокол v2)
      payload.safetensors  дельта fp16
      contribution.json    подписанные сведения о вкладе
      meta.json            что сервер проверил при приёме: логин, норма, ограничения задания
  rounds/v<версия:06d>.json  решения агрегатора по каждому обновлению (закрыто: логины и цифры)

Агрегатор удаляет каталог обновления после решения по нему и схлопывает историю датасета, поэтому дельты не
копятся и не остаются в истории.
"""
from __future__ import annotations

import re
from dataclasses import dataclass

from hub.storage import BlobStore

PENDING = "pending/"
FILES = ("manifest.json", "payload.safetensors", "contribution.json", "meta.json")
ENTRY_RE = re.compile(r"^pending/([A-Za-z0-9-]{1,39})/v(\d{6})-(\d{10})-([0-9a-f]{16})/(" + "|".join(FILES) + r")$")


@dataclass(frozen=True, order=True)
class Entry:
    received_at: int
    login: str
    base_version: int
    sha16: str

    @property
    def prefix(self) -> str:
        return f"{PENDING}{self.login}/v{self.base_version:06d}-{self.received_at:010d}-{self.sha16}/"


class Inbox:
    def __init__(self, store: BlobStore):
        self.store = store

    def put(self, login: str, base_version: int, received_at: int, payload_sha256: str, files: dict[str, bytes]) -> Entry:
        if set(files) != set(FILES):
            raise ValueError(f"нужны ровно файлы {FILES}")
        e = Entry(received_at, login, base_version, payload_sha256[:16])
        self.store.commit({e.prefix + n: b for n, b in files.items()}, message=f"update from {login} on v{base_version}")
        return e

    def entries(self, login: str | None = None) -> list[Entry]:
        found: dict[Entry, set[str]] = {}
        for path in self.store.list(PENDING + (f"{login}/" if login else "")):
            m = ENTRY_RE.match(path)
            if m:
                e = Entry(int(m.group(3)), m.group(1), int(m.group(2)), m.group(4))
                found.setdefault(e, set()).add(m.group(5))
        # an entry is visible only once all its files are there (a local store writes them one by one)
        return sorted(e for e, names in found.items() if names == set(FILES))

    def read(self, e: Entry, name: str) -> bytes:
        data = self.store.read(e.prefix + name)
        if data is None:
            raise FileNotFoundError(e.prefix + name)
        return data

    def delete(self, entries: list[Entry], message: str = "processed") -> None:
        if entries:
            self.store.commit({}, [e.prefix for e in entries], message)

    def write_report(self, name: str, data: bytes, delete: list[Entry] = ()) -> None:
        """Отчёт раунда и удаление обработанных обновлений одним коммитом; затем история схлопывается, чтобы
        удалённые дельты не оставались в прошлых коммитах."""
        self.store.commit({f"rounds/{name}": data}, [e.prefix for e in delete], f"round report {name}")
        self.store.squash()
