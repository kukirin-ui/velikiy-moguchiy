"""qwen3-vl-plus as the close-up talking-head check: 3 YouTube frames per video vs the collector's s4_face verdict."""
import sqlite3, urllib.request, concurrent.futures as cf, sys, os, random, base64
sys.path.insert(0, os.path.dirname(__file__))
from common import *

c = sqlite3.connect(ROOT / "newdata" / "state.db")
MODE = sys.argv[1] if len(sys.argv) > 1 else "s4"
if MODE == "s4":
    passed = [r[0] for r in c.execute("select video_id from videos where stage in ('s5_speech','s6_sync','s7_video','s8_clips') or (status='done')")]
    failed = [(r[0], r[1]) for r in c.execute("select video_id,reason from videos where stage='s4_face' and status='rej'")]
else:
    passed = [r[0] for r in c.execute("select video_id from events where sieve='s1b_thumb' and passed=1")]
    failed = [(r[0], r[1]) for r in c.execute("select video_id,reason from events where sieve='s1b_thumb' and passed=0")]
rng = random.Random(3)
rng.shuffle(passed); rng.shuffle(failed)
npass = 22 if MODE == "s4" else 25
sel = [(v, True, "pass") for v in passed[:npass]] + [(v, False, rs) for v, rs in failed[: 50 - npass]]
print(len(passed), len(failed), len(sel))

PROMPT = ("Три кадра из одного видео на YouTube. Подходит ли видео для обучения чтению по губам: на всех или почти всех кадрах "
          "ОДИН человек, лицо крупным планом (лицо занимает не меньше ~15% ширины кадра), анфас или почти анфас, лицо не закрыто "
          "и не мелкое, нет нескольких людей, нет слайдов, скринкаста или анимации поверх. Ответь строго JSON: "
          '{"faces_per_frame":[n1,n2,n3],"close_up":true|false,"reason":"кратко"}')


def frame(v, k):
    try:
        return urllib.request.urlopen(urllib.request.Request(f"https://i.ytimg.com/vi/{v}/hq{k}.jpg", headers={"User-Agent": "Mozilla/5.0"}), timeout=20).read()
    except Exception:
        return None


def run(i_s):
    i, (v, truth, why) = i_s
    fr = [frame(v, k) for k in (1, 2, 3)]
    if not all(fr):
        return {"video": v, "truth": truth, "why": why, "err": "no_frames"}
    content = [{"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," + base64.b64encode(b).decode()}} for b in fr]
    content.append({"type": "text", "text": PROMPT})
    t = time.time()
    r = chat("qwen3-vl-plus", content, key_i=i)
    txt = r["choices"][0]["message"]["content"] if "choices" in r else ""
    try:
        j = json.loads(txt[txt.index("{"): txt.rindex("}") + 1])
    except Exception:
        j = {}
    return {"video": v, "truth": truth, "why": why, "pred": j.get("close_up"), "faces": j.get("faces_per_frame"), "reason": j.get("reason"),
            "sec": round(time.time() - t, 1), "usage": r.get("usage"), "raw": txt if not j else None}


with cf.ThreadPoolExecutor(6) as ex:
    res = list(ex.map(run, enumerate(sel)))
ok = [r for r in res if r.get("pred") is not None]
tp = sum(r["truth"] and r["pred"] for r in ok); fp = sum((not r["truth"]) and r["pred"] for r in ok)
fn = sum(r["truth"] and not r["pred"] for r in ok); tn = sum((not r["truth"]) and not r["pred"] for r in ok)
summ = {"n": len(res), "answered": len(ok), "tp": tp, "fp": fp, "fn": fn, "tn": tn, "accuracy": round((tp + tn) / max(1, len(ok)), 3),
        "mean_sec": round(sum(r.get("sec", 0) for r in ok) / max(1, len(ok)), 1),
        "mean_tokens": round(sum((r["usage"] or {}).get("total_tokens", 0) for r in ok) / max(1, len(ok)))}
(OUT / f"frames_check_{MODE}.json").write_text(json.dumps({"summary": summ, "rows": res}, ensure_ascii=False, indent=1))
print(summ)
