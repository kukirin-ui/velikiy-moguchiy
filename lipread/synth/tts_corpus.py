"""Dictation-domain speech with exact transcripts: Qwen writes short Russian phrases in the style of voice dictation
to an assistant (requests, commands, IT terms, names, numbers), qwen3-tts-flash speaks each with a random voice.
The result is a synth/sources.py "jsonl" source (corpus name qwentts) for synth/gen.py.

The owner's own dictations are not sent anywhere: the prompt describes the style only. Phrases that normalise to
a phrase of the owner's tests (clips/*.txt, phrases_*.txt) are dropped (RULES.md R10).

  python synth/tts_corpus.py --n 200 --out data/synth/src/qwentts
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import random
import re
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np
import requests
import soundfile as sf

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "synth"))
from dashscope_gen import API, keys  # noqa: E402
from metrics import normalize  # noqa: E402
import sources  # noqa: E402

VOICES = ["Cherry", "Ethan", "Nofish", "Jennifer", "Ryan", "Katerina", "Elias", "Jada", "Dylan", "Sunny", "li",
          "Marcus", "Roy", "Peter", "Rocky", "Kiki", "Eric"]

TOPICS = ["работа с кодом и репозиторием", "серверы, деплой и базы данных", "покупки и доставка", "переписка с коллегой",
          "планирование дня и встречи", "финансы, цены и счета", "поиск информации в интернете", "умный дом и техника",
          "путешествия и билеты", "здоровье и спорт", "учёба и тексты", "машина и дорога", "еда и рестораны",
          "настройка телефона и приложений", "нейросети и обучение моделей", "документы и договоры", "семья и друзья",
          "погода и одежда", "фильмы, музыка, книги", "бытовые просьбы и напоминания"]

PROMPT = """Напиши {n} разных коротких фраз на русском, какие человек надиктовывает голосом ассистенту или в мессенджер.
Тема: {topic}. Стиль: живая разговорная речь, просьбы, вопросы, команды, уточнения ("слушай", "давай", "короче",
"а можешь"), технические слова, имена, названия, суммы и даты. Длина фразы от 3 до 16 слов.
Правила: все числа и даты словами; никаких латинских букв, названия брендов и программ писать кириллицей
("гитхаб", "докер", "телеграм"); без эмодзи, кавычек и нумерации. Каждая фраза с новой строки, больше ничего."""


def chat(key: str, prompt: str, model: str) -> str:
    r = requests.post(f"{API.rsplit('/api/v1', 1)[0]}/compatible-mode/v1/chat/completions", timeout=120,
                      headers={"Authorization": f"Bearer {key}"},
                      json={"model": model, "messages": [{"role": "user", "content": prompt}], "temperature": 1.0})
    r.raise_for_status()
    return r.json()["choices"][0]["message"]["content"]


def tts(key: str, text: str, voice: str) -> np.ndarray:
    for attempt in range(5):
        r = requests.post(f"{API}/services/aigc/multimodal-generation/generation", timeout=120,
                          headers={"Authorization": f"Bearer {key}"},
                          json={"model": "qwen3-tts-flash",
                                "input": {"text": text, "voice": voice, "language_type": "Russian"}})
        if r.status_code == 429:
            time.sleep(5 * (attempt + 1))
            continue
        r.raise_for_status()
        url = r.json()["output"]["audio"]["url"]
        wav, sr = sf.read(io.BytesIO(requests.get(url, timeout=120).content), dtype="float32")
        return sources._to16k(wav, sr)
    raise RuntimeError("TTS rate limited")


def banned_keys() -> set[str]:
    out = set()
    for p in list((ROOT / "clips").glob("*.txt")) + list(ROOT.glob("phrases_*.txt")):
        for line in p.read_text(encoding="utf8").splitlines():
            if line.strip():
                out.add(normalize(line))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=200, help="phrases to voice")
    ap.add_argument("--out", default=str(ROOT / "data" / "synth" / "src" / "qwentts"))
    ap.add_argument("--llm", default="qwen-plus")
    ap.add_argument("--seed", type=int, default=0)
    a = ap.parse_args()
    out = Path(a.out)
    (out / "wav").mkdir(parents=True, exist_ok=True)
    ks = keys()
    rnd = random.Random(a.seed)
    banned = banned_keys()
    man = out / "manifest.jsonl"
    seen = set()
    if man.exists():
        for line in man.read_text(encoding="utf8").splitlines():
            seen.add(normalize(json.loads(line)["text"]))

    phrases, t0 = [], time.time()
    need = a.n - len(seen)
    while len(phrases) < need:
        topic = rnd.choice(TOPICS)
        txt = chat(ks[len(phrases) % len(ks)], PROMPT.format(n=40, topic=topic), a.llm)
        for line in txt.splitlines():
            p = re.sub(r"^\s*(\d+[.)]|[-*•])\s*", "", line).strip().strip('"«»')
            k = normalize(p)
            if not p or k in seen or k in banned or not sources.clean_text(p) or not 3 <= len(k.split()) <= 20:
                continue
            seen.add(k)
            phrases.append((p, topic))
    print(f"{len(phrases)} new phrases in {time.time() - t0:.0f} s", flush=True)

    lock = threading.Lock()
    done = [0]

    def voice_one(i, p, topic):
        key = ks[i % len(ks)]
        voice = rnd.choice(VOICES)
        uid = "q" + hashlib.sha1(f"{p}|{voice}".encode()).hexdigest()[:12]
        wav = tts(key, p, voice)
        sf.write(out / "wav" / f"{uid}.wav", wav, 16000)
        with lock:
            with open(man, "a", encoding="utf8") as f:
                f.write(json.dumps(dict(id=uid, audio=f"wav/{uid}.wav", text=p, speaker=voice, topic=topic,
                                        sec=round(len(wav) / 16000, 2)), ensure_ascii=False) + "\n")
            done[0] += 1
            if done[0] % 25 == 0:
                print(f"voiced {done[0]}/{len(phrases)}, {time.time() - t0:.0f} s", flush=True)

    with ThreadPoolExecutor(len(ks)) as ex:
        for f in [ex.submit(voice_one, i, p, t) for i, (p, t) in enumerate(phrases)]:
            f.result()
    print(f"done: {done[0]} clips in {time.time() - t0:.0f} s -> {man}", flush=True)


if __name__ == "__main__":
    main()
