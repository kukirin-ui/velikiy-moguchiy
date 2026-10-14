"""LLM correction of the lip-reading n-best list (no training).

  python3 llm_rescore.py [--nbest results/nbest.jsonl] [--variants A,B,C] [--model qwen3.8-omni-flash]

A: pick or merge from the top-20 hypotheses; B: A plus a dictation context and the IT dictionary as hints;
C: rewrite the top-1 hypothesis only (control). Reference texts and the phrase list the test was recorded from are
never shown to the model. Writes results/llm_rescore.md and results/llm_rescore.jsonl.
"""
import argparse
import json
import random
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
import metrics  # noqa: E402

URL = "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
DICT = ROOT.parent / "mac" / "velikiy-moguchiy-core" / "resources" / "dictionary-it-ru.txt"

SYSTEM = ("Ты восстанавливаешь фразу по результатам чтения по губам. Модель видела только губы говорящего, звука не было, "
          "поэтому она путает слова, которые выглядят одинаково на губах (м/б/п, ф/в, т/д/н, с/з, к/г/х), и иногда "
          "повторяет слова. Ответь одной строкой: самая правдоподобная фраза на русском. Без кавычек и пояснений.")


def app_config_path() -> Path:
    """config.yaml of the app: ~/.velikiy-moguchiy, or ~/.koe from before the rename while only that one exists
    (the same rule as the app itself)."""
    new, old = Path.home() / ".velikiy-moguchiy", Path.home() / ".koe"
    return (old if not new.exists() and old.is_dir() else new) / "config.yaml"


def api_key():
    import yaml  # noqa: PLC0415
    cfg = yaml.safe_load(app_config_path().read_text())
    q = (cfg.get("asr") or {}).get("qwen") or {}
    keys = q.get("api_keys") or ([q["api_key"]] if q.get("api_key") else [])
    if not keys:
        sys.exit(f"no DashScope key in {app_config_path()}")
    return keys


def chat(keys, model, user, system=SYSTEM):
    body = {"model": model, "stream": True, "enable_thinking": False, "temperature": 0.2,
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}]}
    for attempt in range(6):
        key = keys[attempt % len(keys)]
        req = urllib.request.Request(URL, data=json.dumps(body).encode(), headers={
            "Authorization": "Bearer " + key, "Content-Type": "application/json"})
        try:
            out = []
            with urllib.request.urlopen(req, timeout=120) as r:
                for raw in r:
                    line = raw.decode().strip()
                    if not line.startswith("data:") or line.endswith("[DONE]"):
                        continue
                    for ch in json.loads(line[5:]).get("choices", []):
                        out.append((ch.get("delta") or {}).get("content") or "")
            return "".join(out).strip().splitlines()[0].strip(" «»\"") if "".join(out).strip() else ""
        except urllib.error.HTTPError as e:
            msg = e.read().decode()[:300]
            if e.code in (429, 500, 502, 503):
                time.sleep(2 + attempt * 3)
                continue
            sys.exit(f"API {e.code}: {msg}")
        except (urllib.error.URLError, TimeoutError):
            time.sleep(2 + attempt * 3)
    return ""


def prompt(row, variant, terms):
    hyps = row["hyps"][:20]
    if variant == "C":
        return f"Гипотеза чтения по губам: {hyps[0]['text']}"
    lines = [f"{i + 1}. {h['text']}  (оценка {h['score']:.2f})" for i, h in enumerate(hyps)]
    text = "Варианты модели, от более вероятного к менее:\n" + "\n".join(lines)
    text += "\nМожно выбрать вариант или собрать фразу из слов разных вариантов; не добавляй смысла, которого нет ни в одном."
    if variant == "B":
        text = ("Контекст: человек диктует на компьютере короткие сообщения, рабочие заметки, вопросы; темы бытовые, "
                "работа, программирование. Возможные термины: " + ", ".join(terms) + ".\n\n" + text)
    return text


def bootstrap(base, new, n=5000, seed=1):
    rnd = random.Random(seed)
    idx = list(range(len(base)))
    diffs = []
    for _ in range(n):
        s = [rnd.choice(idx) for _ in idx]
        e0 = sum(base[i][0] for i in s) / max(1, sum(base[i][1] for i in s))
        e1 = sum(new[i][0] for i in s) / max(1, sum(new[i][1] for i in s))
        diffs.append(100 * (e1 - e0))
    diffs.sort()
    return diffs[int(0.025 * n)], diffs[int(0.975 * n)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--nbest", default=str(ROOT / "results" / "nbest.jsonl"))
    ap.add_argument("--variants", default="A,B,C")
    ap.add_argument("--model", default="qwen3.8-omni-flash")
    a = ap.parse_args()
    keys = api_key()
    rows = [json.loads(line) for line in open(a.nbest)]
    terms = []
    if DICT.exists():
        terms = [t.split("|")[0].strip() for t in DICT.read_text().splitlines() if t.strip() and not t.startswith("#")][:150]
    out = {v: [] for v in a.variants.split(",")}
    for row in rows:
        for v in out:
            out[v].append(chat(keys, a.model, prompt(row, v, terms)))
    base = [row["hyps"][0]["text"] for row in rows]
    refs = [row["ref"] for row in rows]
    oracle = [min(row["hyps"], key=lambda h: metrics.wer_counts(metrics.normalize(row["ref"]),
                                                               metrics.normalize(h["text"]))[0])["text"] for row in rows]

    def counts(hyps, fn):
        return [fn(metrics.normalize(r), metrics.normalize(h)) for r, h in zip(refs, hyps)]

    res = {}
    for name, hyps in [("base", base)] + [(v, out[v]) for v in out] + [("oracle", oracle)]:
        w, c = metrics.corpus_rates(list(zip(refs, hyps)))
        res[name] = (w, c, counts(hyps, metrics.wer_counts))
    with open(ROOT / "results" / "llm_rescore.jsonl", "w") as f:
        for i, row in enumerate(rows):
            f.write(json.dumps({"id": row["id"], "ref": row["ref"], "base": base[i],
                                **{v: out[v][i] for v in out}}, ensure_ascii=False) + "\n")
    md = [f"# LLM-пересчёт n-best ({a.model})", "", "| вариант | WER | CER | ΔWER к базе, 95% ДИ |", "|---|---:|---:|---|"]
    for name, (w, c, cnt) in res.items():
        ci = "" if name == "base" else "[%.1f; %.1f]" % bootstrap(res["base"][2], cnt)
        md.append(f"| {name} | {100 * w:.1f}% | {100 * c:.1f}% | {ci} |")
    best = min(out, key=lambda v: res[v][0])
    # per-phrase examples come from personal test clips and stay out of the tracked report
    ex = [f"Примеры (эталон / база / {best}):", ""]
    for i in range(0, len(rows), max(1, len(rows) // 6))[:6]:
        ex.append(f"- {refs[i]} / {base[i]} / {out[best][i]}")
    (ROOT / "results" / "llm_rescore.md").write_text("\n".join(md) + "\n")
    (ROOT / "results" / "llm_rescore_examples.md").write_text("\n".join(ex) + "\n")
    print("\n".join(md + [""] + ex))


if __name__ == "__main__":
    main()
