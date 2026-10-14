"""synth/sources.py on stub corpora in the release layouts the pod downloads: Golos opus (split dir with
manifest.jsonl and files/*.opus), Common Voice (validated.tsv + clips/*.mp3), HF parquet; plus label cleaning.

Run: work/synth/.venv/bin/python tests/test_synth_sources.py
"""
import io
import json
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
import soundfile as sf

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "synth"))
import sources  # noqa: E402


def tone(sec=1.5, sr=16000):
    t = np.arange(int(sec * sr)) / sr
    return (0.2 * np.sin(2 * np.pi * 220 * t)).astype(np.float32)


def encode(wav, dst: Path, sr=16000):
    src = dst.with_suffix(".src.wav")
    sf.write(src, wav, sr)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(src), str(dst)], check=True)
    src.unlink()


def main():
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        split = d / "golos_opus" / "train"
        (split / "files").mkdir(parents=True)
        encode(tone(), split / "files" / "a1.opus")
        (split / "manifest.jsonl").write_text(json.dumps(
            {"id": "a1", "audio_filepath": "files/a1.wav", "text": "салют включи музыку", "duration": 1.5}) + "\n")
        rows = list(sources.iter_source(f"golos:{split / 'manifest.jsonl'}@golos"))
        assert len(rows) == 1 and rows[0]["corpus"] == "golos" and "Golos" in rows[0]["license"]
        a = rows[0]["audio"]()
        assert abs(len(a) / 16000 - 1.5) < 0.05, len(a)

        cv = d / "cv-ru"
        (cv / "clips").mkdir(parents=True)
        encode(tone(2.0, 48000), cv / "clips" / "c1.mp3", sr=48000)
        (cv / "validated.tsv").write_text("client_id\tpath\tsentence\nabc\tc1.mp3\tПривет, мир! 2 раза\n")
        rows = list(sources.iter_source(f"cv:{cv}@cv"))
        assert rows[0]["id"] == "c1" and rows[0]["license"].startswith("Common Voice")
        a = rows[0]["audio"]()
        assert abs(len(a) / 16000 - 2.0) < 0.1, len(a)
        assert sources.clean_text(rows[0]["text"]) == "привет мир два раза"

        import pyarrow as pa
        import pyarrow.parquet as pq
        buf = io.BytesIO()
        sf.write(buf, tone(1.0), 16000, format="WAV")
        t = pa.table({"audio": [{"bytes": buf.getvalue(), "path": "x.wav"}], "transcription": ["Там чудеса:"]})
        pq.write_table(t, d / "validation-00000-of-00001-abc.parquet")
        rows = list(sources.iter_source(f"parquet:{d}/*.parquet@ruls"))
        assert rows[0]["id"] == "validation-00000:0" and "public domain" in rows[0]["license"]
        assert len(rows[0]["audio"]()) == 16000
        assert sources.clean_text(rows[0]["text"]) == "там чудеса"

    assert sources.clean_text("включи Apple Music") is None
    print("ok")


if __name__ == "__main__":
    main()
