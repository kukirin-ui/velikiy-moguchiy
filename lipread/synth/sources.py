"""Russian speech corpora with exact transcripts -> rows (id, audio 16 kHz float32, text) for synth/gen.py.

Source spec: "<kind>:<path or glob>[@<corpus name>]". Kinds:
  parquet  Hugging Face parquet shards with an `audio` struct {bytes, path} and a text column
           (bond005/sberdevices_golos_*, bond005/rulibrispeech, ...)
  cv       Common Voice release dir: validated.tsv + clips/*.mp3
  golos    Golos manifest (jsonl with audio_filepath, text) next to its audio files
  jsonl    any jsonl with {"audio": path, "text": ..., "id": ...}

Licences are in data/synth/LICENSES.md; each clip's json repeats the short form from LICENSE.
"""
from __future__ import annotations

import csv
import glob
import io
import json
import re
import sys
from pathlib import Path

import numpy as np
import soundfile as sf

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from metrics import normalize_loose  # noqa: E402

SR = 16000

LICENSE = {
    "golos": "Golos (SberDevices): public licence with attribution, BY-SA-like, commercial use allowed",
    "ruls": "Russian LibriSpeech (OpenSLR 96, LibriVox): public domain in the USA",
    "cv": "Common Voice: CC0-1.0; terms forbid re-hosting the dataset and identifying speakers",
    "openstt": "Open STT: CC-BY-NC 4.0, commercial use only by agreement",
    "qwentts": "generated: Qwen phrases + qwen3-tts-flash speech (owner's Alibaba Model Studio account)",
}

_CYR = re.compile(r"^[а-яё ]+$")


def clean_text(text: str) -> str | None:
    """Trainer-style label (metrics.normalize_loose: lower case, no punctuation, digits as words) or None
    when anything but Cyrillic is left (Latin brand names, symbols): a wrong label is worse than no clip."""
    t = normalize_loose(text)
    return t if t and _CYR.match(t) else None


def _to16k(data: np.ndarray, sr: int) -> np.ndarray:
    if data.ndim > 1:
        data = data.mean(1)
    if sr != SR:
        import librosa
        data = librosa.resample(data, orig_sr=sr, target_sr=SR)
    return np.ascontiguousarray(data, np.float32)


def _decode(src) -> np.ndarray:
    try:
        data, sr = sf.read(src, dtype="float32", always_2d=False)
    except Exception:  # mp3/opus that this libsndfile cannot read
        import librosa
        data, sr = librosa.load(src, sr=SR, mono=True)
    return _to16k(data, sr)


def _parquet(pattern, corpus):
    import pyarrow.parquet as pq
    for shard in sorted(glob.glob(pattern)):
        pf = pq.ParquetFile(shard)
        names = pf.schema_arrow.names
        tcol = next(c for c in ("transcription", "sentence", "text", "normalized_text") if c in names)
        stem = "-".join(Path(shard).stem.split("-")[:2])  # validation-00000-of-00001-<hash> -> validation-00000
        i = 0
        for batch in pf.iter_batches(batch_size=256, columns=["audio", tcol]):
            for row in batch.to_pylist():
                a = row["audio"]
                yield dict(id=f"{stem}:{i}", src_name=a.get("path"), text=row[tcol],
                           audio=lambda b=a["bytes"]: _decode(io.BytesIO(b)))
                i += 1


def _cv(root, corpus):
    root = Path(root)
    with open(root / "validated.tsv", newline="", encoding="utf8") as f:
        for r in csv.DictReader(f, delimiter="\t", quoting=csv.QUOTE_NONE):
            p = root / "clips" / r["path"]
            yield dict(id=Path(r["path"]).stem, text=r["sentence"], speaker=r.get("client_id", "")[:16],
                       audio=lambda p=p: _decode(str(p)))


def _find_audio(manifest_dir: Path, rel: str) -> Path:
    """Golos manifests give paths relative to a split dir, and the opus release may keep the .wav names."""
    for base in (manifest_dir, manifest_dir.parent, manifest_dir.parent.parent):
        for p in (base / rel, (base / rel).with_suffix(".opus")):
            if p.exists():
                return p
    return manifest_dir / rel


def _golos(manifest, corpus):
    base = Path(manifest).parent
    with open(manifest, encoding="utf8") as f:
        for line in f:
            r = json.loads(line)
            rel = r["audio_filepath"]
            yield dict(id=r.get("id") or Path(rel).stem, text=r["text"],
                       audio=lambda rel=rel: _decode(str(_find_audio(base, rel))))


def _jsonl(path, corpus):
    base = Path(path).parent
    with open(path, encoding="utf8") as f:
        for n, line in enumerate(f):
            r = json.loads(line)
            p = base / r["audio"]
            yield dict(id=r.get("id") or str(n), text=r["text"], speaker=r.get("speaker", ""),
                       audio=lambda p=p: _decode(str(p)))


KINDS = {"parquet": _parquet, "cv": _cv, "golos": _golos, "jsonl": _jsonl}


def iter_source(spec: str):
    """Rows with a lazy `audio()` so that skipped rows cost nothing to decode."""
    kind, _, rest = spec.partition(":")
    path, _, corpus = rest.partition("@")
    corpus = corpus or kind
    for r in KINDS[kind](path, corpus):
        r["corpus"] = corpus
        r["license"] = LICENSE.get(corpus, "see data/synth/LICENSES.md")
        yield r
