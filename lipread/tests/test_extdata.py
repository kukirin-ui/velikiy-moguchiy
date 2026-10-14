"""Stub tests of the external-dataset path: feeder section jobs, selection sections, pod segment filters.

  .venv/bin/python tests/test_extdata.py
No video, network or model is touched: Deps is replaced by StubDeps.
"""
import json
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "extdata"))
sys.path.insert(0, str(ROOT / "harvester"))
sys.path.insert(0, str(ROOT / "newdata"))

import collect  # noqa: E402  newdata/collect.py: the collector's segment checks
import mac_feeder  # noqa: E402
import pod_segments as P  # noqa: E402
import selection as S  # noqa: E402


def test_feeder_parses_section_lines():
    assert mac_feeder.parse_line("https://www.youtube.com/watch?v=abcdefghijk  # chan") == \
        ("abcdefghijk", "abcdefghijk", "chan", None)
    job, vid, ch, sec = mac_feeder.parse_line("https://www.youtube.com/watch?v=abcdefghijk  # muavic:x  @12.5-80")
    assert (job, vid, ch, sec) == ("abcdefghijk@12.50-80.00", "abcdefghijk", "muavic:x", (12.5, 80.0))
    assert mac_feeder.split_job(job) == ("abcdefghijk", (12.5, 80.0))
    assert mac_feeder.job_stem(job) == "yt_abcdefghijk__s00012500"
    assert mac_feeder.job_stem("abcdefghijk") == "abcdefghijk"
    assert mac_feeder.parse_line("# comment") is None
    assert P.parse_name(mac_feeder.job_stem(job)) == ("abcdefghijk", 12.5)
    assert P.parse_name("yt_yt_bcdefgh__s00012500") == ("yt_bcdefgh", 12.5)  # an id may itself start with yt_


def test_scout_plan():
    plan = mac_feeder.plan_sections
    assert plan([], 600) == ("skip", [])
    # stretches 10 s apart merge; 2 sections cover 120 s of 600: fetch only them
    assert plan([[0, 50], [60, 100], [300, 340]], 600) == ("sections", [(0, 100), (300, 340)])
    assert plan([[0, 300], [305, 560]], 600) == ("whole", [])  # 93% of the video
    many = [[i * 40, i * 40 + 10] for i in range(9)]
    assert plan(many, 3600) == ("whole", [])  # more than 8 sections: one request for the whole video is cheaper
    assert mac_feeder.scout_saving(dict(duration=600, bytes720=60_000_000, bytes144=1_000_000), "sections",
                                   [(0, 100), (300, 340)]) == 60_000_000 * 460 // 600 - 1_000_000
    assert mac_feeder.scout_saving(dict(duration=600, bytes720=None, bytes144=1), "skip", []) is None
    info = {"duration": 100, "formats": [
        {"vcodec": "avc1.4d401f", "height": 720, "filesize": 50_000_000},
        {"vcodec": "vp9", "height": 1080, "filesize": 90_000_000},
        {"vcodec": "avc1.4d401e", "height": 360, "filesize": 10_000_000},
        {"vcodec": "none", "acodec": "opus", "abr": 130, "filesize": 2_000_000}]}
    assert mac_feeder.est_720_bytes(info) == 52_000_000


def test_selection_sections_merge_close_segments():
    rows = [dict(start=10, end=14), dict(start=20, end=25), dict(start=200, end=205)]
    assert S.sections(rows) == [[9.5, 25.5], [199.5, 205.5]]
    assert S.overlaps(10, 14, [(11, 30)]) and not S.overlaps(10, 14, [(13.5, 30)])


def rows_of(n, fh=200.0, yaw=0.1, second=0.0, jump_at=(), face=None):
    o = {k: np.zeros(n, np.float32) for k in ("face", "fh", "yaw", "second", "jump", "sharp", "cx", "cy", "fw")}
    o["face"][:] = 1 if face is None else face
    o["fh"][:], o["yaw"][:], o["second"][:], o["sharp"][:] = fh, yaw, second, 100.0
    for i in jump_at:
        o["jump"][i] = 1
    return o


def test_shot_parts_split_at_cuts_and_gaps():
    o = rows_of(300, jump_at=[120])
    assert P.shot_parts(o, 300) == [(0, 120), (120, 300)]
    face = np.ones(300)
    face[140:150] = 0  # 10 missing frames: a gap, not a blink
    assert P.shot_parts(rows_of(300, face=face), 300) == [(0, 140), (150, 300)]
    assert P.shot_parts(rows_of(300, jump_at=[30]), 300) == [(30, 300)]  # a part under 2 s is dropped


def test_close_up_rules():
    # 360p decode of a 720p source: 60 px at 360 = 120 px in the source
    assert P.close_up(rows_of(100, fh=90), 0, 100, 1.0, 2.0, 720, collect) is None
    assert P.close_up(rows_of(100, fh=50), 0, 100, 1.0, 2.0, 720, collect) == "not_close_up"
    assert P.close_up(rows_of(100, fh=90, yaw=0.4), 0, 100, 1.0, 2.0, 720, collect) == "not_frontal"
    assert P.close_up(rows_of(100, fh=90, second=0.9), 0, 100, 1.0, 2.0, 720, collect) == "multi_face"
    face = np.ones(100)
    face[:4] = 0  # 4% of frames without the face fails the 97% rule
    assert P.close_up(rows_of(100, fh=90, face=face), 0, 100, 1.0, 2.0, 720, collect) == "not_close_up"


class StubDeps:
    collect = collect
    ky = 1.0

    def __init__(self, rows, lang=("ru", 0.9), sync_conf=6.0, asr="привет как дела у тебя сегодня"):
        self.rows, self.lang, self.sync_conf, self.asr_text = rows, lang, sync_conf, asr
        self.written = []

    def dims(self, path):
        return 1280, 720

    def audio(self, path):
        return np.zeros(P.SR * 40, np.float32)

    def frames(self, path, ss, t, out_h):
        return np.zeros((int(round(t * P.FPS)), 4, 4, 3), np.uint8)

    def features(self, frames):
        return self.rows(len(frames))

    def sxy(self, o, a, b):
        return np.ones((b - a, 3))

    def crop(self, frames_bgr, sxy):
        return np.zeros((len(sxy), 224, 224, 3), np.uint8)

    def write_mp4(self, arr, dst):
        dst.write_bytes(b"mp4")
        self.written.append(dst.name)

    def sync(self, crops, audio):
        return {"conf": self.sync_conf, "offset": 0}

    def sync_ok(self, r):
        return r["conf"] >= 3.0 and abs(r["offset"]) <= 3

    def asr(self, audio):
        return self.asr_text

    def lid(self, audio):
        return self.lang[1], self.lang[0]

    def label_text(self, text):
        return collect.label_text(text)

    def words(self, text):
        import textnorm
        return textnorm.words(text)

    def noise(self, text):
        return False


def sel_row(ds, start, end, transcript=None, lang="ru"):
    return dict(dataset=ds, video_id="abcdefghijk", url="u", license="l", start=start, end=end, speaker=None,
                split="train", transcript=transcript, lang=lang)


def test_process_section_writes_close_up_clips(tmp_path):
    for ds in ("muavic_ru", "avspeech_ru"):
        (tmp_path / ds).mkdir()
    path = tmp_path / "yt_abcdefghijk__s00010000.mp4"
    path.write_bytes(b"")
    path.with_name("yt_abcdefghijk__s00010000.info.json").write_text(json.dumps({"channel_id": "UCx"}))
    rows = [sel_row("muavic_ru", 12.0, 16.0, "Привет, как дела?"),
            sel_row("avspeech_ru", 20.0, 30.0, lang="?"),
            sel_row("avspeech_ru", 60.0, 64.0, lang="?")]  # past the 40 s section: another section's job
    d = StubDeps(lambda n: rows_of(n, fh=90, jump_at=[100] if n == 250 else []))
    res = P.process_section(path, rows, tmp_path, d)
    assert res["kept"] == 3 and not res["rejected"]  # 1 MuAViC + the AVSpeech segment split at its cut
    meta = json.loads((tmp_path / "muavic_ru" / "train" / "yt_abcdefghijk__00012000.json").read_text())
    assert meta["speaker"] == "UCx" and meta["src_height"] == 720 and meta["text_source"] == "human (mTEDx)"
    assert (tmp_path / "muavic_ru" / "train" / "yt_abcdefghijk__00012000.txt").read_text() == "привет как дела\n"
    assert sorted(p.name for p in (tmp_path / "avspeech_ru" / "train").glob("*.json")) == \
        ["yt_abcdefghijk__00020000.json", "yt_abcdefghijk__00024000.json"]


def test_process_section_rejects_with_reasons(tmp_path):
    for ds in ("muavic_ru", "avspeech_ru"):
        (tmp_path / ds).mkdir()
    path = tmp_path / "yt_abcdefghijk__s00000000.mp4"
    rows = [sel_row("avspeech_ru", 1.0, 5.0, lang="?")]
    assert P.process_section(path, rows, tmp_path, StubDeps(lambda n: rows_of(n), lang=("uk", 0.8)))["rejected"] == \
        {"not_russian": 1}
    assert P.process_section(path, rows, tmp_path, StubDeps(lambda n: rows_of(n, fh=40)))["rejected"] == \
        {"not_close_up": 1}
    assert P.process_section(path, rows, tmp_path, StubDeps(lambda n: rows_of(n, fh=90), sync_conf=1.0))["rejected"] \
        == {"sync": 1}
    mu = [sel_row("muavic_ru", 1.0, 5.0, "текст")]
    assert P.process_section(path, mu, tmp_path, StubDeps(lambda n: rows_of(n, fh=90, jump_at=[50])))["rejected"] == \
        {"face_jump": 1}
    reasons = [json.loads(x)["reason"] for x in (tmp_path / "avspeech_ru" / "rejects.jsonl").read_text().splitlines()]
    assert reasons == ["not_russian", "not_close_up", "sync"]


if __name__ == "__main__":
    import tempfile
    for name, fn in sorted(globals().items()):
        if name.startswith("test_"):
            if "tmp_path" in fn.__code__.co_varnames[:fn.__code__.co_argcount]:
                with tempfile.TemporaryDirectory() as t:
                    fn(Path(t))
            else:
                fn()
            print(f"{name}: ok")
