#!/usr/bin/env python3
"""Reads the channel exclusions log (channels.tsv next to this file).

    from exclusions import excluded_channel_ids
    if info["channel_id"] in excluded_channel_ids(): skip

    exclusions.py --check [file]   validate the format (CI runs this)
"""

from __future__ import annotations

import datetime as dt
import re
import sys
from pathlib import Path

LOG = Path(__file__).resolve().with_name("channels.tsv")
CHANNEL_ID = re.compile(r"^UC[0-9A-Za-z_-]{22}$")


def read(path: Path = LOG) -> list[tuple[str, dt.date]]:
    """Entries as (channel_id, date); raises ValueError naming the bad line."""
    entries = []
    seen = set()
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip() or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 2:
            raise ValueError(f"{path.name}:{number}: нужно два поля через табуляцию: идентификатор и дата")
        channel_id, date = fields
        if not CHANNEL_ID.match(channel_id):
            raise ValueError(f"{path.name}:{number}: {channel_id!r} — не идентификатор канала (UC и 22 символа)")
        try:
            day = dt.date.fromisoformat(date)
        except ValueError:
            raise ValueError(f"{path.name}:{number}: {date!r} — дата не в формате ГГГГ-ММ-ДД") from None
        if channel_id in seen:
            raise ValueError(f"{path.name}:{number}: {channel_id} уже есть в журнале")
        seen.add(channel_id)
        entries.append((channel_id, day))
    return entries


def excluded_channel_ids(path: Path = LOG) -> frozenset[str]:
    return frozenset(channel_id for channel_id, _ in read(path))


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3) or sys.argv[1] != "--check":
        sys.exit(__doc__)
    target = Path(sys.argv[2]) if len(sys.argv) == 3 else LOG
    try:
        count = len(read(target))
    except ValueError as error:
        sys.exit(f"Ошибка в журнале исключений: {error}")
    print(f"Журнал исключений в порядке: каналов {count}.")
