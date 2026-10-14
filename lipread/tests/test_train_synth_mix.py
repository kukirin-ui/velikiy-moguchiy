"""train_e2e.py --synth-dir/--synth-frac on stub clips (empty mp4 files, no GPU, no weights):
synthetic rows only reach train (R2), do not change the R1 verdict, drop test phrases (R10), keep their share per epoch
in the sampler, and change the smoke-run key (R4).

Run: ./run.sh python tests/test_train_synth_mix.py
"""
import argparse
import json
import shutil
import sys
import tempfile
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
import train_e2e as E  # noqa: E402
from split import split_for  # noqa: E402

TEST_PHRASE = "эта фраза есть только в тесте владельца"


def clip(d: Path, stem: str, text: str, meta: dict):
    (d / f"{stem}.mp4").write_bytes(b"")
    (d / f"{stem}.txt").write_text(text, encoding="utf8")
    (d / f"{stem}.json").write_text(json.dumps(meta, ensure_ascii=False))


tmp = Path(tempfile.mkdtemp(prefix="synthmix_"))
try:
    clips, real, syn = tmp / "clips", tmp / "real", tmp / "syn"
    for d in (clips, real, syn):
        d.mkdir()
    (clips / "001.txt").write_text(TEST_PHRASE, encoding="utf8")

    chans = [f"chan{i:02d}" for i in range(12)]
    dev_pct = 30
    held = [c for c in chans if split_for(f"ch:{c}", dev_pct) == "dev"]
    assert held and len(held) < len(chans) - 5, held
    lines = []
    for ci, c in enumerate(chans):
        for v in range(2):
            vid = f"v{ci:02d}{v}"
            lines.append(f"{vid}\t{c}")
            for k in range(5):
                clip(real, f"yt_{vid}__{k}", f"реальная фраза {ci} {v} {k}", dict(video_id=f"yt_{vid}", frames=75))
    (tmp / "channels.tsv").write_text("\n".join(lines) + "\n")

    for i in range(40):
        clip(syn, f"synth_golos_{i:012d}", f"синтетическая фраза {i}",
             dict(video_id="synth_face", source="synth", speaker=f"face{i % 4}", frames=60))
    clip(syn, "synth_golos_leak00000000", TEST_PHRASE, dict(source="synth", speaker="face0", frames=60))
    clip(syn, "synth_golos_notsynth0000", "чужой клип", dict(source="public", frames=60))

    def args(**kw):
        base = dict(clips_dir=str(clips), channel_map=str(tmp / "channels.tsv"), from_videos=str(real),
                    video_dir=str(real), manifest=None, dev_pct=dev_pct, personal_dir=None, public_limit=0,
                    max_per_channel=0, synth_dir=str(syn), synth_frac=0.3, seed=0, dev_n=150,
                    batch=4, accum=8, chunk_batch=8, max_seconds=8.0)
        return argparse.Namespace(**dict(base, **kw))

    # --- R2: synthetic rows never reach dev; dev is identical with and without them
    train0, dev0 = E.load_rows(args(synth_frac=0.0), 200)
    train1, dev1 = E.load_rows(args(), 200)
    assert not any(r["source"] == "synth" for r in train0 + dev0)
    assert not any(r["source"] == "synth" for r in dev1), "synthetic clip in dev"
    assert [r["id"] for r in dev0] == [r["id"] for r in dev1]
    assert {r["channel"] for r in dev1} == set(held)
    syn_train = [r for r in train1 if r["source"] == "synth"]
    assert len(syn_train) == 40, len(syn_train)
    assert [r for r in train1 if r["source"] != "synth"] == train0
    print(f"ok: {len(syn_train)} synthetic rows all in train, dev = {len(dev1)} clips of held-out channels {held}")

    # --- R10: the test phrase and non-synth json are dropped from the synthetic folder
    texts = {r["text"] for r in syn_train}
    assert TEST_PHRASE not in texts and "чужой клип" not in texts
    print("ok: synthetic clip with a test phrase excluded")

    # --- R1: synthetic rows (no channel) neither break the 95% known-channel rule nor change the verdict
    real_rows = E.rows_from_videos(args())
    synth_rows = E.rows_synth(args())
    out = E.check_speakers(args(), real_rows + synth_rows * 3)
    assert Counter(r["source"] for r in out) == Counter(public=len(real_rows), synth=3 * len(synth_rows))

    def verdict(rows):
        try:
            E.check_speakers(args(), rows)
            return "pass"
        except SystemExit as e:
            return str(e)

    lopsided = real_rows + [dict(r, hash=f"{r['hash']}_dup{k}") for r in real_rows if r["channel"] == "chan00"
                            and r["split"] == "train" for k in range(12)]
    few = [r for r in real_rows if r["channel"] in chans[:3]]
    for rows in (real_rows, lopsided, few):
        assert verdict(rows) == verdict(rows + synth_rows * 5), verdict(rows)
    assert verdict(lopsided).startswith("[R1]") and verdict(few).startswith("[R1]")
    print("ok: R1 verdict unchanged by synthetic rows (pass, one channel too large, too few channels)")

    # --- the mix is enforced by the sampler per epoch, and the whole pool is used across epochs
    rows = [dict(source="public")] * 70 + [dict(source="synth")] * 40
    s = E.MixSampler(rows, 0.3, seed=1)
    seen = set()
    for _ in range(3):
        ep = list(s)
        assert len(ep) == len(s) == 100
        n_syn = sum(rows[i]["source"] == "synth" for i in ep)
        assert n_syn == 30 and len(set(ep) & set(s.real)) == 70, n_syn
        seen |= {i for i in ep if rows[i]["source"] == "synth"}
    assert len(seen) == 40
    small = E.MixSampler([dict(source="public")] * 90 + [dict(source="synth")] * 5, 0.5, seed=2)
    assert sum(i >= 90 for i in small) == 90
    print("ok: sampler keeps 30% synthetic per epoch and cycles the whole pool")

    # --- R4: a smoke run without the same mix does not unlock a long run
    k0 = E.smoke_key(args(synth_frac=0.0), "cpu")[1]
    k1 = E.smoke_key(args(), "cpu")[1]
    assert k0 != k1 and k1 == E.smoke_key(args(), "cpu")[1]
    assert k1 != E.smoke_key(args(synth_frac=0.5), "cpu")[1]
    assert k1 != E.smoke_key(args(synth_dir=str(tmp / "other")), "cpu")[1]
    print("ok: smoke key includes the synthetic mix")
    print("synth mix: ok")
finally:
    shutil.rmtree(tmp, ignore_errors=True)
