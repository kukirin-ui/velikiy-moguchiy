"""Zero-shot lip reading through the DashScope chat API. Usage: zeroshot.py MODEL TAG [--prompt N] [--novideo] [--fps F] [-n 50]"""
from pathlib import Path
import argparse, concurrent.futures as cf, sys, os
sys.path.insert(0, os.path.dirname(__file__)); sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from common import *
from metrics import corpus_rates, wer_counts, normalize

PROMPTS = [
    "Это беззвучное видео: человек говорит по-русски, звука нет. Прочитай по губам и напиши, что он говорит, одной фразой по-русски, без пояснений.",
    "Ты эксперт по чтению по губам. На видео крупным планом лицо говорящего человека, звуковой дорожки нет. Дословно запиши по-русски, "
    "что он произносит (3-12 слов). Если не уверен, всё равно дай лучшую догадку. Ответ: только сама фраза.",
]

ap = argparse.ArgumentParser()
ap.add_argument("model"); ap.add_argument("tag")
ap.add_argument("--prompt", type=int, default=0); ap.add_argument("--novideo", action="store_true")
ap.add_argument("--fps", type=float, default=None); ap.add_argument("-n", type=int, default=50)
ap.add_argument("--slow", action="store_true", help="448px clips retimed to 10 fps (all 25 fps frames kept), fps=10")
ap.add_argument("--thinking", action="store_true"); ap.add_argument("--workers", type=int, default=6)
a = ap.parse_args()
SRC = ROOT / "work" / "dashscope_slow" if a.slow else PUB
if a.slow:
    a.fps = 10
clips = json.load(open(OUT / "clips_pool100.json"))[: a.n]
kw = {"enable_thinking": a.thinking}
if a.model.startswith("qwen3-vl") and a.thinking:
    kw["thinking_budget"] = 2000


def run(i_c):
    i, c = i_c
    content = [{"type": "text", "text": PROMPTS[a.prompt]}]
    if not a.novideo:
        v = {"type": "video_url", "video_url": {"url": data_uri(SRC / f"{c['id']}.mp4")}}
        if a.fps:
            v["fps"] = a.fps
        content = [v] + content
    t = time.time()
    r = chat(a.model, content, key_i=i, **kw)
    hyp = r["choices"][0]["message"]["content"].strip() if "choices" in r else ""
    return {**c, "hyp": hyp, "sec": round(time.time() - t, 1), "usage": r.get("usage"), "err": r.get("error") and r}

with cf.ThreadPoolExecutor(a.workers) as ex:
    res = list(ex.map(run, enumerate(clips)))
w, cc = corpus_rates([(r["ref"], r["hyp"]) for r in res])
per = [wer_counts(normalize(r["ref"]), normalize(r["hyp"])) for r in res]
errs = sum(1 for r in res if r["err"])
summ = {"model": a.model, "tag": a.tag, "n": len(res), "wer": round(100 * w, 1), "cer": round(100 * cc, 1), "api_errors": errs,
        "mean_sec": round(sum(r["sec"] for r in res) / len(res), 1), "prompt": a.prompt, "novideo": a.novideo, "slow": a.slow, "thinking": a.thinking,
        "distinct_hyps": len({normalize(r["hyp"]) for r in res})}
(OUT / f"zs_{a.tag}.json").write_text(json.dumps({"summary": summ, "rows": res}, ensure_ascii=False, indent=1))
print(json.dumps(summ, ensure_ascii=False))
for r in res[:6]:
    print(" REF:", r["ref"], "\n HYP:", r["hyp"])
