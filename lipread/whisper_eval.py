"""Lips + audio: whisper/voice ASR, lip reading and their LLM fusion, clean and in noise.

  harvester/lipsasr_pod.sh <pod name>          # voiced set: model stages on a CUDA pod, Qwen and reports on the Mac
  ./run.sh whisper_eval.py --set voiced all     # every stage in order, each model in its own process
  python3 whisper_eval.py --set voiced gpu      # only the model stages (gigaam, lips): what the pod runs
  ./run.sh whisper_eval.py --set voiced prep    # wav per condition (noise mixes, pseudo-whisper) -> work/lipsasr/<set>/<cond>/
  ~/.venvs/gigaam/bin/python whisper_eval.py --set voiced gigaam   # GigaAM v3 RNNT (MLX)  -> gigaam.jsonl
  ./run.sh whisper_eval.py --set voiced lips    # face crops + MultiVSR 20-best per lip model -> lips_<model>.jsonl
  ./run.sh whisper_eval.py --set voiced qwen    # Qwen ASR and the fusion prompts           -> qwen.jsonl
  ./run.sh whisper_eval.py --set voiced report --ref gigaam  # tables  -> results/lipsasr/<set>_ref-<ref>.md

Sets: `whisper` is data/whisper from record.py --whisper (video with its own whisper track; lips by me1). `voiced` is the
owner's real dictations: webcam video data/voiced/<id>.mp4 without sound, paired with the dictation audio
~/.koe/recordings/*/<id'>.m4a by the nearest id within 2 s; the reference is the dictation's own ASR text <id>.txt (taken
from the clean audio, so the clean row measures agreement with that ASR, not truth), or a checked text from
results/lipsasr/<set>_ref.tsv (id<TAB>text) where present. Lips there are read by the base MultiVSR and by me1; me1 was
fine-tuned on the first 92 of these clips (those up to 8 s), so its numbers are also given on the clips it never saw.

Conditions: clean audio and the same audio with café or street noise at fixed SNR; `pw` is a pseudo-whisper made from
the voice (LPC envelope over a noise excitation, no voicing). Both noise beds are synthetic and local: café is
8 overlapping Russian TTS voices (macOS `say`, pitch-shifted) with a pink-noise floor, street is synthetic traffic that
sounds more like wind (broadband noise with slow swells). The video is the same in every condition, so lips are read once.

Systems: gigaam, qwen (audio only); merge (LLM over both audio transcripts, no lips: the control); per lip model M:
lips_M (top-1), lips_llm_M (LLM over the lip n-best), fuse_M (both transcripts + lip n-best), omni_M (the audio itself +
lip n-best).
Reference texts never reach the models. WHISPER_CLIPS / WHISPER_WORK / WHISPER_RES override the folders (tests).
"""
from __future__ import annotations

import argparse
import base64
import concurrent.futures as cf
import json
import os
import subprocess
import sys
import threading
import wave
import zlib
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent
KOE_REC = Path.home() / ".koe" / "recordings"
GIGAAM_PY = Path.home() / ".venvs" / "gigaam" / "bin" / "python"
MEM_GUARD = ROOT.parent / "tools" / "mem_guard.py"
ME1 = ROOT / "results" / "pod_runs" / "t1" / "checkpoints" / "me1"
RATE = 16000
MODEL = "qwen3.8-omni-flash"
LIP_CHUNK_S = 14  # MultiVSR decodes at most 14 s at once
ME1_SEEN_VOICED, ME1_MAX_S = 92, 8.0  # me1's personal fine-tune: the first 92 data/voiced clips, those of <= 8 s
SETS = {
    "whisper": dict(clips=ROOT / "data" / "whisper", lips=["me1"], conds={
        "clean": ("orig", None, 0), "cafe10": ("orig", "cafe", 10), "cafe5": ("orig", "cafe", 5),
        "cafe0": ("orig", "cafe", 0), "street5": ("orig", "street", 5), "street0": ("orig", "street", 0)}),
    "voiced": dict(clips=ROOT / "data" / "voiced", lips=["base", "me1"], conds={
        "clean": ("orig", None, 0), "cafe10": ("orig", "cafe", 10), "cafe5": ("orig", "cafe", 5),
        "cafe0": ("orig", "cafe", 0), "cafe-5": ("orig", "cafe", -5), "street5": ("orig", "street", 5),
        "street0": ("orig", "street", 0), "street-5": ("orig", "street", -5),
        "pw": ("pw", None, 0), "pw_cafe5": ("pw", "cafe", 5), "pw_cafe0": ("pw", "cafe", 0)}),
}
SET = CLIPS = WORK = RES = CONDS = LIPS = None

ASR_PROMPT = ("Распознай русскую речь в записи. Речь может быть шёпотом, возможен фоновый шум. Выведи только "
              "услышанный текст дословно, одной строкой, без пояснений. Если речи не слышно совсем, выведи прочерк.")
FUSE_SYSTEM = (
    "Ты восстанавливаешь фразу, которую человек продиктовал компьютеру (голосом или шёпотом). Есть два независимых "
    "источника. 1) Распознавание звука: в шуме и на шёпоте оно пропускает и искажает слова, может подхватить слова из "
    "фонового разговора. 2) Чтение по губам по видео: модель не слышит звук, поэтому путает слова, которые выглядят "
    "одинаково на губах (м/б/п, ф/в, т/д/н, с/з, к/г/х), но не зависит от шума. Сопоставь источники и ответь одной "
    "строкой: самая правдоподобная фраза на русском. Без кавычек и пояснений.")
MERGE_SYSTEM = (
    "Ты восстанавливаешь фразу, которую человек продиктовал компьютеру (голосом или шёпотом). Есть распознавания звука "
    "двумя системами: в шуме и на шёпоте они пропускают и искажают слова, могут подхватить слова из фонового разговора. "
    "Ответь одной строкой: самая правдоподобная фраза на русском. Без кавычек и пояснений.")
LIPS_SYSTEM = (
    "Ты восстанавливаешь фразу по результатам чтения по губам. Модель видела только губы говорящего и не слышала звук, "
    "поэтому она путает слова, которые выглядят одинаково на губах (м/б/п, ф/в, т/д/н, с/з, к/г/х), и иногда "
    "повторяет слова. Ответь одной строкой: самая правдоподобная фраза на русском. Без кавычек и пояснений.")


def configure(name: str):
    global SET, CLIPS, WORK, RES, CONDS, LIPS
    cfg = SETS[name]
    SET, CONDS, LIPS = name, cfg["conds"], cfg["lips"]
    CLIPS = Path(os.environ.get("WHISPER_CLIPS", cfg["clips"]))
    WORK = Path(os.environ.get("WHISPER_WORK", ROOT / "work" / "lipsasr" / name))
    RES = Path(os.environ.get("WHISPER_RES", ROOT / "results" / "lipsasr"))
    WORK.mkdir(parents=True, exist_ok=True)


def has_audio(mp4: Path) -> bool:
    return bool(subprocess.run(["ffprobe", "-v", "error", "-select_streams", "a", "-show_entries", "stream=index",
                                "-of", "csv=p=0", str(mp4)], capture_output=True, text=True).stdout.strip())


def audio_sources() -> dict[str, str]:
    """clip id -> audio file: the clip's own track, else the dictation recording whose id (ms) is nearest within 2 s."""
    cache = WORK / "pairs.json"
    if cache.exists():
        return json.loads(cache.read_text())
    rec = {int(p.stem): p for p in KOE_REC.glob("*/*.m4a") if p.stem.isdigit()}
    out = {}
    for mp4 in sorted(CLIPS.glob("*.mp4")):
        if not mp4.with_suffix(".txt").exists() or not mp4.with_suffix(".txt").read_text(encoding="utf8").strip():
            continue
        if has_audio(mp4):
            out[mp4.stem] = str(mp4)
        elif mp4.stem.isdigit() and rec:
            near = min(rec, key=lambda k: abs(k - int(mp4.stem)))
            if abs(near - int(mp4.stem)) <= 2000:
                out[mp4.stem] = str(rec[near])
    cache.write_text(json.dumps(out, indent=1))
    return out


def clip_ids() -> list[str]:
    return sorted(audio_sources())


def ref(cid: str) -> str:
    fixed = RES / f"{SET}_ref.tsv"
    if fixed.exists():
        for line in fixed.read_text(encoding="utf8").splitlines():
            k, _, text = line.partition("\t")
            if k == cid:
                return text.strip()
    return (CLIPS / f"{cid}.txt").read_text(encoding="utf8").strip()


def me1_unseen(cid: str, ids: list[str]) -> bool:
    """Not in me1's training even at worst: recorded after the crops it was trained on, or longer than its 8 s cap
    (with a margin: crop and dictation lengths differ slightly). Clips of its 15% dev split count as seen."""
    meta = CLIPS / f"{cid}.json"
    dur = json.loads(meta.read_text()).get("duration_s", 0) if meta.exists() else 0
    return ids.index(cid) >= ME1_SEEN_VOICED or dur > ME1_MAX_S + 0.3


def video_lag_ms(cid: str) -> int:
    meta = CLIPS / f"{cid}.json"
    return int(json.loads(meta.read_text()).get("first_frame_lag_ms") or 0) if meta.exists() else 0


def read_jsonl(p: Path) -> list[dict]:
    return [json.loads(line) for line in p.open(encoding="utf8")] if p.exists() else []


def append_jsonl(p: Path, row: dict, lock=threading.Lock()):
    with lock, p.open("a", encoding="utf8") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")


def read_wav(p: Path) -> np.ndarray:
    with wave.open(str(p)) as w:
        assert w.getframerate() == RATE and w.getnchannels() == 1, p
        return np.frombuffer(w.readframes(w.getnframes()), np.int16).astype(np.float32) / 32768


def write_wav(p: Path, x: np.ndarray):
    p.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(p), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes((np.clip(x, -1, 1) * 32767).astype(np.int16).tobytes())


def ffmpeg_wav(args: list[str], dst: Path):
    dst.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["ffmpeg", "-v", "error", "-y", *args, "-ac", "1", "-ar", str(RATE), "-c:a", "pcm_s16le", str(dst)],
                   check=True)


# --- prep ------------------------------------------------------------------------------------------------------
def make_cafe(dst: Path, seconds=150):
    texts = [l.strip() for l in (ROOT / "phrases_train_ru.txt").read_text(encoding="utf8").splitlines()
             if l.strip() and not l.startswith("#")]
    rng = np.random.default_rng(7)
    tmp = WORK.parent / "noise" / "tts"
    tmp.mkdir(parents=True, exist_ok=True)
    voices = []
    for v in range(8):
        aiff = tmp / f"v{v}.aiff"
        if not aiff.exists():
            words = " ".join(rng.choice(texts, 40))
            subprocess.run(["say", "-v", "Milena", "-r", str(int(rng.integers(150, 210))), "-o", str(aiff), words],
                           check=True)
        wav = tmp / f"v{v}.wav"
        pitch = float(rng.uniform(0.8, 1.25))  # asetrate shifts pitch and tempo together: different "speakers"
        ffmpeg_wav(["-i", str(aiff), "-af", f"asetrate=22050*{pitch:.3f},aresample={RATE}"], wav)
        x = read_wav(wav)
        x = np.tile(x, int(np.ceil(seconds * RATE / len(x))))
        x = np.roll(x, int(rng.integers(0, len(x))))[:seconds * RATE]
        voices.append(x / (np.sqrt(np.mean(x ** 2)) + 1e-9) * rng.uniform(0.5, 1.0))
    babble = np.sum(voices, axis=0)
    pink = tmp / "pink.wav"
    ffmpeg_wav(["-f", "lavfi", "-i", f"anoisesrc=color=pink:amplitude=0.3:duration={seconds}:seed=3"], pink)
    p = read_wav(pink)[:len(babble)]
    babble = babble / np.sqrt(np.mean(babble ** 2)) + 0.3 * p / np.sqrt(np.mean(p ** 2))
    room = tmp / "dry.wav"
    write_wav(room, 0.1 * babble)
    ffmpeg_wav(["-i", str(room), "-af", "aecho=0.8:0.7:40|70|110:0.3|0.2|0.15"], dst)


def band(x: np.ndarray, lo: float, hi: float) -> np.ndarray:
    f = np.fft.rfftfreq(len(x), 1 / RATE)
    X = np.fft.rfft(x)
    X[(f < lo) | (f > hi)] = 0
    return np.fft.irfft(X, len(x))


def make_street(dst: Path, seconds=150):
    """Rumble plus passing cars (tyre noise and an engine tone under a ~3 s envelope) and an occasional horn. To a
    listener it reads more as wind or a waterfall than a street: a broadband, slowly swelling noise."""
    rng = np.random.default_rng(5)
    n = seconds * RATE
    t = np.arange(n) / RATE
    out = 0.5 * band(rng.standard_normal(n), 30, 250)
    out /= np.sqrt(np.mean(out ** 2))
    tyre = band(rng.standard_normal(n), 300, 3000)
    tyre /= np.sqrt(np.mean(tyre ** 2))
    tc = 0.0
    while tc < seconds:
        tc += rng.uniform(1.5, 6)
        env = np.exp(-0.5 * ((t - tc) / rng.uniform(0.8, 1.8)) ** 2) * rng.uniform(0.4, 1.5)
        f0 = rng.uniform(70, 140) * (1 + 0.06 * np.tanh(-(t - tc) * 2))
        engine = np.sign(np.sin(2 * np.pi * np.cumsum(f0) / RATE)) * 0.3
        out += env * (tyre * rng.uniform(0.8, 1.6) + engine)
    for th in rng.uniform(5, seconds - 5, 4):
        m = (t > th) & (t < th + 0.4)
        out[m] += 0.6 * (np.sin(2 * np.pi * 420 * t[m]) + np.sin(2 * np.pi * 530 * t[m]))
    write_wav(dst, 0.1 * out / np.sqrt(np.mean(out ** 2)))


def speech_power(x: np.ndarray) -> float:
    """Mean power of frames within 30 dB of the loudest one: pauses around the whisper do not dilute the SNR."""
    n = 320
    fr = x[:len(x) // n * n].reshape(-1, n)
    e = np.mean(fr ** 2, axis=1) + 1e-12
    return float(np.mean(e[e >= e.max() * 1e-3]))


def mix(clean: np.ndarray, noise: np.ndarray, snr_db: float, seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    if len(noise) <= len(clean):
        noise = np.tile(noise, len(clean) // len(noise) + 2)
    start = int(rng.integers(0, len(noise) - len(clean)))
    n = noise[start:start + len(clean)]
    n = n * np.sqrt(speech_power(clean) / (np.mean(n ** 2) * 10 ** (snr_db / 10)))
    y = clean + n
    peak = np.abs(y).max()
    return y / peak * 0.95 if peak > 0.95 else y


def pseudo_whisper(x: np.ndarray, seed: int) -> np.ndarray:
    """Whisper-like speech from voiced speech: per 25 ms frame the LPC spectral envelope (formants) is kept and the
    excitation is replaced by white noise of the same energy, so pitch and voicing are gone. Level is kept."""
    from scipy.linalg import solve_toeplitz
    from scipy.signal import lfilter
    n, hop, order = 400, 160, 18
    win = np.hanning(n)
    pre = lfilter([1, -0.97], 1, x)
    rng = np.random.default_rng(seed)
    y = np.zeros(len(x) + n)
    norm = np.zeros(len(x) + n)
    for s in range(0, max(1, len(x) - n), hop):
        fr = pre[s:s + n] * win
        r = np.correlate(fr, fr, "full")[n - 1:n + order]
        if r[0] < 1e-10:
            continue
        r[0] *= 1.0001
        lpc = np.concatenate([[1.0], -solve_toeplitz(r[:order], r[1:order + 1])])
        g = np.sqrt(np.mean(lfilter(lpc, 1, fr) ** 2))
        y[s:s + n] += lfilter([1.0], lpc, rng.standard_normal(n) * g) * win
        norm[s:s + n] += win ** 2
    y = lfilter([1.0], [1, -0.97], y[:len(x)] / np.maximum(norm[:len(x)], 1e-3))
    y *= np.sqrt(speech_power(x) / max(speech_power(y), 1e-12))
    peak = np.abs(y).max()
    return y / peak * 0.95 if peak > 0.95 else y


def stage_prep():
    src = audio_sources()
    if not src:
        sys.exit(f"no clips with audio in {CLIPS}")
    beds = {"cafe": WORK.parent / "noise" / "cafe.wav", "street": WORK.parent / "noise" / "street.wav"}
    if not beds["cafe"].exists():
        make_cafe(beds["cafe"])
    if not beds["street"].exists():
        make_street(beds["street"])
    noise = {k: read_wav(p) for k, p in beds.items()}
    for cid, audio in src.items():
        voices = {"orig": WORK / "src" / f"{cid}.wav", "pw": WORK / "src_pw" / f"{cid}.wav"}
        if not voices["orig"].exists():
            ffmpeg_wav(["-i", audio, "-vn"], voices["orig"])
        if any(v == "pw" for v, _, _ in CONDS.values()) and not voices["pw"].exists():
            write_wav(voices["pw"], pseudo_whisper(read_wav(voices["orig"]), zlib.crc32(cid.encode())))
        for cond, (voice, bed, snr) in CONDS.items():
            dst = WORK / cond / f"{cid}.wav"
            if dst.exists():
                continue
            x = read_wav(voices[voice])
            write_wav(dst, x if bed is None else mix(x, noise[bed], snr, zlib.crc32(f"{cond}/{cid}".encode())))
    print(f"prep: {len(src)} clips x {len(CONDS)} conditions in {WORK}")


# --- gigaam (runs under ~/.venvs/gigaam/bin/python) -------------------------------------------------------------
def split_audio(x: np.ndarray, max_s=20.0) -> list[np.ndarray]:
    """Pieces of at most max_s, cut at the quietest 0.3 s in the second half of each window: GigaAM degrades on
    long inputs (same rule as gigaam_mlx.audio.split_audio)."""
    size, quiet = int(max_s * RATE), int(0.3 * RATE)
    out, start = [], 0
    while start < len(x):
        end = min(start + size, len(x))
        if end < len(x):
            lo = start + size // 2
            energy = np.convolve(np.abs(x[lo:end]), np.ones(quiet) / quiet, mode="valid")
            end = lo + int(np.argmin(energy)) + quiet // 2
        out.append(x[start:end])
        start = end
    return out


class GigaMLX:
    def __init__(self):
        import mlx.core as mx
        from gigaam_mlx import load_model
        from gigaam_mlx.audio import compute_mel
        self.mx, self.compute_mel = mx, compute_mel
        self.model, self.tok = load_model("rnnt")

    def __call__(self, x: np.ndarray) -> str:
        enc, ln = self.model.encode(self.mx.array(self.compute_mel(x)[np.newaxis]))
        self.mx.eval(enc)
        return self.tok.decode(self.model.decode(enc, ln))


class GigaTorch:
    def __init__(self):
        import gigaam
        import torch
        self.torch = torch
        self.m = gigaam.load_model("v3_rnnt", fp16_encoder=True, device="cuda" if torch.cuda.is_available() else "cpu")

    def __call__(self, x: np.ndarray) -> str:
        torch = self.torch
        with torch.inference_mode():
            wav = torch.from_numpy(x[np.newaxis].astype(np.float32)).to(self.m._device).to(self.m._dtype)
            ln = torch.tensor([len(x)], device=self.m._device)
            enc, el = self.m.forward(wav, ln)
            return self.m._decode(enc, el, ln, False)[0][0]


def stage_gigaam():
    """GigaAM v3 RNNT: PyTorch `gigaam` on a CUDA pod, gigaam_mlx (~/.venvs/gigaam) on a Mac."""
    out = WORK / "gigaam.jsonl"
    done = {(r["cond"], r["id"]) for r in read_jsonl(out)}
    todo = [(c, cid) for c in CONDS for cid in clip_ids() if (c, cid) not in done]
    if not todo:
        return
    asr = GigaMLX() if sys.platform == "darwin" else GigaTorch()
    for cond, cid in todo:
        parts = [asr(piece) for piece in split_audio(read_wav(WORK / cond / f"{cid}.wav"))]
        append_jsonl(out, {"cond": cond, "id": cid, "text": " ".join(t for t in parts if t)})
    print(f"gigaam: {len(todo)} transcripts -> {out}")


# --- lips (runs in the project env, under mem_guard) -------------------------------------------------------------
def stage_lips():
    import memguard  # noqa: F401  (MPS limits before import torch)
    import preprocess
    ids = clip_ids()
    for cid in ids:  # the face detector and MultiVSR are never in memory together
        crop = WORK.parent / "faces" / SET / f"{cid}.avi"
        if not crop.exists():
            preprocess.preprocess_video(str(CLIPS / f"{cid}.mp4"), str(crop))
    preprocess._DET = None
    import gc
    import mvsr
    for name in LIPS:
        out = WORK / f"lips_{name}.jsonl"
        done = {r["id"] for r in read_jsonl(out)}
        todo = [cid for cid in ids if cid not in done]
        if not todo:
            continue
        gc.collect()
        kw = dict(lora=str(ME1 / "best.pt"), venc_ckpt=str(ME1 / "best_venc.pth")) if name == "me1" else {}
        m = mvsr.MultiVSR(device="auto", beam_size=20, **kw)
        for cid in todo:
            faces = m.load_faces(WORK.parent / "faces" / SET / f"{cid}.avi")
            t = faces.shape[2]
            k = -(-t // (LIP_CHUNK_S * 25))
            bounds = [round(i * t / k) for i in range(k + 1)]
            chunks = [m.nbest_faces(faces[:, :, bounds[i]:bounds[i + 1]]) for i in range(k)]
            append_jsonl(out, {"id": cid, "model": name, "chunks": chunks})
        del m
        print(f"lips {name}: {len(todo)} clips -> {out}", flush=True)


# --- qwen ----------------------------------------------------------------------------------------------------
def chat(keys, content, system=None) -> str:
    import llm_rescore
    import time
    import urllib.error
    import urllib.request
    msgs = ([{"role": "system", "content": system}] if system else []) + [{"role": "user", "content": content}]
    body = json.dumps({"model": MODEL, "stream": True, "modalities": ["text"], "enable_thinking": False,
                       "temperature": 0.2, "messages": msgs}).encode()
    for attempt in range(8):
        req = urllib.request.Request(llm_rescore.URL, data=body, headers={
            "Authorization": "Bearer " + keys[attempt % len(keys)], "Content-Type": "application/json"})
        try:
            out = []
            with urllib.request.urlopen(req, timeout=120) as r:
                for raw in r:
                    line = raw.decode().strip()
                    if line.startswith("data:") and not line.endswith("[DONE]"):
                        for ch in json.loads(line[5:]).get("choices", []):
                            out.append((ch.get("delta") or {}).get("content") or "")
            text = "".join(out).strip()
            return text.splitlines()[0].strip(" «»\"") if text else ""
        except urllib.error.HTTPError as e:
            if e.code not in (429, 500, 502, 503):
                raise RuntimeError(f"API {e.code}: {e.read().decode()[:300]}") from e
        except (urllib.error.URLError, TimeoutError):
            pass
        time.sleep(2 + attempt * 3)
    raise RuntimeError("API: no answer after retries")


def audio_part(cond, cid):
    b64 = base64.b64encode((WORK / cond / f"{cid}.wav").read_bytes()).decode()
    return {"type": "input_audio", "input_audio": {"data": "data:;base64," + b64, "format": "wav"}}


def lips_block(chunks, lag_ms=0) -> str:
    head = "Чтение по губам (видео)"
    if lag_ms > 500:
        head += f"; видео начинается примерно на {lag_ms / 1000:.1f} с позже звука, первые слова губы могли не увидеть"
    if len(chunks) == 1:
        return head + ", варианты от более вероятного к менее:\n" + "\n".join(
            f"{i + 1}. {h['text']}" for i, h in enumerate(chunks[0][:20]))
    per = 20 if len(chunks) <= 2 else 10
    lines = [head + f". Запись длинная, губы читались {len(chunks)} кусками подряд; для каждого куска варианты от более "
                    "вероятного к менее:"]
    for k, hyps in enumerate(chunks):
        lines.append(f"Кусок {k + 1}:")
        lines += [f"  {i + 1}. {h['text']}" for i, h in enumerate(hyps[:per])]
    return "\n".join(lines)


def asr_block(g, q) -> str:
    return f"Распознавание звука, система A: {g or '—'}\nРаспознавание звука, система B: {q or '—'}"


def stage_qwen(workers=6):
    import llm_rescore
    keys = llm_rescore.api_key()
    out = WORK / "qwen.jsonl"
    have = {(r["cond"], r["id"], r["sys"]): r["text"] for r in read_jsonl(out)}
    lips = {(m, r["id"]): r["chunks"] for m in LIPS for r in read_jsonl(WORK / f"lips_{m}.jsonl")}
    giga = {(r["cond"], r["id"]): r["text"] for r in read_jsonl(WORK / "gigaam.jsonl")}
    ids = clip_ids()
    missing = [f"{m}/{cid}" for m in LIPS for cid in ids if (m, cid) not in lips] + \
        [f"{c}/{cid}" for c in CONDS for cid in ids if (c, cid) not in giga]
    if missing:
        sys.exit(f"run the lips and gigaam stages first; missing {missing[:5]}")

    def job(cond, cid, name):
        kind, _, model = name.partition("@")
        lb = lips_block(lips[model, cid], video_lag_ms(cid)) if model else ""
        if kind == "qwen":
            text = chat(keys, [audio_part(cond, cid), {"type": "text", "text": ASR_PROMPT}])
            text = "" if text.strip("—-– ") == "" else text
        elif kind == "lips_llm":
            text = chat(keys, lb + "\nМожно выбрать вариант или собрать фразу из слов разных вариантов; не добавляй "
                        "смысла, которого нет ни в одном.", LIPS_SYSTEM)
        elif kind == "merge":
            text = chat(keys, asr_block(giga[cond, cid], have[cond, cid, "qwen"]), MERGE_SYSTEM)
        elif kind == "fuse":
            text = chat(keys, asr_block(giga[cond, cid], have[cond, cid, "qwen"]) + "\n\n" + lb, FUSE_SYSTEM)
        else:  # omni
            text = chat(keys, [audio_part(cond, cid), {"type": "text", "text": "Запись звука приложена.\n\n" + lb +
                                                       "\n\nКакая фраза произнесена?"}], FUSE_SYSTEM)
        have[cond, cid, name] = text
        append_jsonl(out, {"cond": cond, "id": cid, "sys": name, "text": text})

    rounds = [[("clean", cid, f"lips_llm@{m}") for m in LIPS for cid in ids] +
              [(c, cid, s) for c in CONDS for cid in ids for s in ["qwen"] + [f"omni@{m}" for m in LIPS]],
              [(c, cid, s) for c in CONDS for cid in ids for s in ["merge"] + [f"fuse@{m}" for m in LIPS]]]
    for jobs in rounds:  # merge and fuse read the qwen transcript of the first round
        jobs = [j for j in jobs if j not in have]
        with cf.ThreadPoolExecutor(workers) as ex:
            for f in cf.as_completed([ex.submit(job, *j) for j in jobs]):
                f.result()
        print(f"qwen: {len(jobs)} calls", flush=True)


# --- report --------------------------------------------------------------------------------------------------
def systems() -> list[tuple[str, str]]:
    out = [("gigaam", "звук → GigaAM"), ("qwen", "звук → Qwen"), ("merge", "GigaAM + Qwen → LLM (без губ)")]
    for m in LIPS:
        out += [(f"lips@{m}", f"губы {m}, топ-1"), (f"lips_llm@{m}", f"губы {m} → LLM"),
                (f"fuse@{m}", f"GigaAM + Qwen + губы {m} → LLM"), (f"omni@{m}", f"звук + губы {m} → Qwen-Omni")]
    return out


FILLERS = {"э", "ээ", "эээ", "эм", "м", "мм", "ммм", "хм"}


def stage_report(ref_src="txt"):
    """ref_src: txt (the clip's text file) or gigaam / qwen (that system's transcript of the clean audio: the dictation
    text is edited by an LLM, not verbatim). Clips whose reference is empty are left out."""
    import llm_rescore
    import metrics

    def norm(t):
        return " ".join(w for w in metrics.normalize_loose(t).split() if w not in FILLERS)

    ids = clip_ids()
    hyp: dict = {}
    for r in read_jsonl(WORK / "gigaam.jsonl"):
        hyp[r["cond"], r["id"], "gigaam"] = r["text"]
    for r in read_jsonl(WORK / "qwen.jsonl"):
        hyp[r["cond"], r["id"], r["sys"]] = r["text"]
    for m in LIPS:
        for r in read_jsonl(WORK / f"lips_{m}.jsonl"):
            for c in CONDS:
                hyp[c, r["id"], f"lips@{m}"] = " ".join(ch[0]["text"] for ch in r["chunks"] if ch)
                hyp[c, r["id"], f"lips_llm@{m}"] = hyp.get(("clean", r["id"], f"lips_llm@{m}"), "")
    refs = {cid: ref(cid) if ref_src == "txt" else hyp.get(("clean", cid, ref_src), "") for cid in ids}
    ids = [cid for cid in ids if norm(refs[cid])]
    sysl = systems()

    def counts(sub, cond, s):
        return [metrics.wer_counts(norm(refs[cid]), norm(hyp.get((cond, cid, s), ""))) for cid in sub]

    def rate(cnt):
        return 100 * sum(e for e, _ in cnt) / max(1, sum(n for _, n in cnt))

    def tables(sub, title, models):
        cols = [s for s in sysl if "@" not in s[0] or s[0].split("@")[1] in models]
        md = [f"## {title}: {len(sub)} клипов", "", "WER / CER, %", "",
              "| условие | " + " | ".join(n for _, n in cols) + " |", "|---" * (len(cols) + 1) + "|"]
        for cond in CONDS:
            cells = []
            for s, _ in cols:
                w, c = metrics.corpus_rates([(refs[cid], hyp.get((cond, cid, s), "")) for cid in sub], norm)
                cells.append(f"{100 * w:.1f} / {100 * c:.1f}")
            md.append(f"| {cond} | " + " | ".join(cells) + " |")
        md += ["", "ΔWER от губ, пункты, 95% бутстреп-интервал по клипам (минус = губы помогли)", "",
               "| условие | " + " | ".join(f"fuse {m} − merge | fuse {m} − лучшее аудио | omni {m} − qwen"
                                          for m in models) + " |", "|---" * (3 * len(models) + 1) + "|"]
        for cond in CONDS:
            best = min(("gigaam", "qwen", "merge"), key=lambda s: rate(counts(sub, cond, s)))
            cells = []
            for m in models:
                for k, (a, b) in enumerate((("merge", f"fuse@{m}"), (best, f"fuse@{m}"), ("qwen", f"omni@{m}"))):
                    ca, cb = counts(sub, cond, a), counts(sub, cond, b)
                    lo, hi = llm_rescore.bootstrap(ca, cb)
                    cells.append(f"{rate(cb) - rate(ca):+.1f} [{lo:+.1f}; {hi:+.1f}]" + (f" ({a})" if k == 1 else ""))
            md.append(f"| {cond} | " + " | ".join(cells) + " |")
        return md + [""]

    md = [f"# Губы + звук, набор {SET}: данные замера ({MODEL}; эталон: {ref_src}; нормализация "
          "metrics.normalize_loose без междометий э/эм/мм)", ""]
    md += tables(ids, "Все клипы", LIPS)
    if "me1" in LIPS and SET == "voiced":
        unseen = [cid for cid in ids if me1_unseen(cid, ids)]
        md += tables(unseen, "Клипы, которых me1 не видел при обучении", LIPS)
    md += ["## Все гипотезы", ""]
    for cid in ids:
        md.append(f"**{cid}** {refs[cid]}")
        for cond in CONDS:
            md.append(f"- {cond}: " + " · ".join(f"{s}: {hyp.get((cond, cid, s), '')}" for s, _ in sysl
                                                 if cond == "clean" or not s.startswith("lips")))
        md.append("")
    RES.mkdir(parents=True, exist_ok=True)
    (RES / f"{SET}_ref-{ref_src}.md").write_text("\n".join(md) + "\n", encoding="utf8")
    print("\n".join(md[:md.index("## Все гипотезы")]))


def run_model_stage(stage: str):
    """A model stage in its own process: under mem_guard on a Mac (which refuses ML there, RULES.md R11), plain on a pod."""
    me = str(ROOT / "whisper_eval.py")
    if sys.platform == "darwin":
        cmd = [str(GIGAAM_PY), me] if stage == "gigaam" else [str(ROOT / "run.sh"), "whisper_eval.py"]
        cmd = [sys.executable, str(MEM_GUARD), "--", *cmd]
    else:
        cmd = [sys.executable, me]
    subprocess.run(cmd + ["--set", SET, stage], cwd=ROOT, check=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("stage", choices=["all", "gpu", "prep", "gigaam", "lips", "qwen", "report"])
    ap.add_argument("--set", default="whisper", choices=list(SETS))
    ap.add_argument("--ref", default="txt", choices=["txt", "gigaam", "qwen"], help="reference for the report stage")
    a = ap.parse_args()
    sys.path.insert(0, str(ROOT))
    configure(a.set)
    if a.stage in ("all", "gpu"):
        if a.stage == "all":
            stage_prep()
        run_model_stage("gigaam")
        run_model_stage("lips")
        if a.stage == "all":
            stage_qwen()
            stage_report(a.ref)
    elif a.stage == "report":
        stage_report(a.ref)
    else:
        globals()["stage_" + a.stage]()


if __name__ == "__main__":
    main()
