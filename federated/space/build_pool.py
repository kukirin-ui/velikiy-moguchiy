"""Собрать пул роликов для заданий из отбора сборщика (lipread/fetch/build_selection.py, строки ru.jsonl).

  python -m space.build_pool --rows ru.jsonl --out pool.jsonl [--channels video_channels.tsv] [--exclude-videos FILE]
                             [--shards DIR]

Строки rows: video_id, t_start, t_end, transcript, split. Клипы val и test не берутся (они для проверки),
ролики из --exclude-videos (по одному id в строке, например ролики экзамена) тоже, как и каналы из журнала
data-governance/exclusions/channels.tsv. --channels: TSV «video_id<TAB>channel_id», нужен, чтобы исключения по
каналу работали. --shards: ещё и куски по --shard-size роликов (pool/shards/NNNNN.jsonl + pool/shards/index.json)
для сервера на Cloudflare Worker, которому дорого разбирать весь пул; ролики перемешаны (seed 0), чтобы в каждом
куске были разные каналы. Результат загружается в закрытый датасет
(путь FL_POOL_PATH, по умолчанию pool/pool.jsonl) и в git не попадает:

  huggingface-cli upload --repo-type dataset <владелец>/<датасет> pool.jsonl pool/pool.jsonl
"""
from __future__ import annotations

import argparse
import json
import random
import sys
from pathlib import Path

from hub.tasks import MAX_SEGMENT_SECONDS, MIN_SEGMENT_SECONDS, VIDEO_ID_RE, parse_exclusions

JOURNAL = Path(__file__).resolve().parents[2] / "data-governance" / "exclusions" / "channels.tsv"
SHARD_SIZE = 20


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rows", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--channels")
    ap.add_argument("--exclude-videos")
    ap.add_argument("--shards")
    ap.add_argument("--shard-size", type=int, default=SHARD_SIZE)
    ap.add_argument("--journal", default=str(JOURNAL))
    a = ap.parse_args(argv)
    banned = parse_exclusions(Path(a.journal).read_text(encoding="utf8")).channels if Path(a.journal).exists() else set()
    channels = {}
    if a.channels:
        for ln in Path(a.channels).read_text(encoding="utf8").splitlines():
            parts = ln.split("\t")
            if len(parts) >= 2:
                channels[parts[0].strip()] = parts[1].strip()
    skip = set()
    if a.exclude_videos:
        skip = {ln.strip() for ln in Path(a.exclude_videos).read_text().splitlines() if ln.strip()}
    videos: dict[str, list] = {}
    for ln in Path(a.rows).read_text(encoding="utf8").splitlines():
        if not ln.strip():
            continue
        r = json.loads(ln)
        vid = r.get("video_id", "")
        split = str(r.get("split", ""))
        if "val" in split or "test" in split:  # val_major, val_minor, test
            continue
        if not VIDEO_ID_RE.match(vid) or vid in skip:
            continue
        s, e = float(r["t_start"]), float(r["t_end"])
        if MIN_SEGMENT_SECONDS <= e - s <= MAX_SEGMENT_SECONDS and r.get("transcript", "").strip():
            videos.setdefault(vid, []).append({"start": s, "end": e, "text": r["transcript"].strip()})
    lines = [json.dumps({"video_id": vid, "channel_id": channels.get(vid, ""),
                         "segments": sorted(segs, key=lambda x: x["start"])}, ensure_ascii=False)
             for vid, segs in videos.items() if channels.get(vid, "") not in banned]
    random.Random(0).shuffle(lines)
    Path(a.out).write_text("".join(ln + "\n" for ln in lines), encoding="utf8")
    if a.shards:
        d = Path(a.shards)
        d.mkdir(parents=True, exist_ok=True)
        n = 0
        for n, i in enumerate(range(0, len(lines), a.shard_size)):
            (d / f"{n:05d}.jsonl").write_text("".join(ln + "\n" for ln in lines[i:i + a.shard_size]), encoding="utf8")
        (d / "index.json").write_text(json.dumps({"shards": (n + 1) if lines else 0}))
    print(f"пул: {len(lines)} роликов -> {a.out}" + (f", куски в {a.shards}" if a.shards else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
