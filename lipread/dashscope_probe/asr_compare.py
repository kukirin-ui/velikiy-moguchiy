"""Compare Alibaba-side ASR (fun-asr-flash, qwen-audio-3.0-asr-flash) with the GigaAM labels of 50 clips."""
from pathlib import Path
import concurrent.futures as cf, sys, os
sys.path.insert(0, os.path.dirname(__file__)); sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from common import *
from metrics import corpus_rates, normalize, normalize_loose

D = ROOT / "work" / "dashscope_asr"
clips = [c for c in json.load(open(OUT / "clips_pool100.json"))[:50] if (D / f"{c['id']}.wav").exists()]
MODELS = sys.argv[1:] or ["fun-asr-flash-2026-06-15", "qwen-audio-3.0-asr-flash"]


def asr(model, wav, ki):
    body = {"model": model, "input": {"messages": [{"role": "user", "content": [{"type": "input_audio", "input_audio": {"data": data_uri(wav, "audio/wav")}}]}]},
            "parameters": {"format": "wav", "sample_rate": "16000", "language_hints": ["ru"]}}
    for k in range(3):
        r = requests.post(BASE + "/api/v1/services/aigc/multimodal-generation/generation",
                          headers={**hdr(ki + k), "Content-Type": "application/json", "X-DashScope-SSE": "disable"}, json=body, timeout=120)
        if r.status_code == 200:
            j = r.json()
            return j["output"].get("text") or "", j.get("usage"), None
        if r.status_code not in (429, 500, 503):
            return "", None, (r.status_code, r.text[:300])
        time.sleep(2 + 3 * k)
    return "", None, (r.status_code, r.text[:300])


res = {}
for m in MODELS:
    def one(ic):
        i, c = ic
        t = time.time()
        txt, usage, err = asr(m, D / f"{c['id']}.wav", i)
        return {"id": c["id"], "ref": c["ref"], "hyp": txt, "sec": round(time.time() - t, 2), "usage": usage, "err": err}
    with cf.ThreadPoolExecutor(4) as ex:
        rows = list(ex.map(one, enumerate(clips)))
    ok = [r for r in rows if not r["err"]]
    w, c_ = corpus_rates([(r["ref"], r["hyp"]) for r in ok])
    wl, cl = corpus_rates([(r["ref"], r["hyp"]) for r in ok], norm=normalize_loose)
    exact = sum(normalize(r["ref"]) == normalize(r["hyp"]) for r in ok)
    res[m] = {"n": len(rows), "errors": len(rows) - len(ok), "wer_vs_gigaam": round(100 * w, 1), "cer": round(100 * c_, 1),
              "wer_loose": round(100 * wl, 1), "exact_match": exact, "mean_sec": round(sum(r["sec"] for r in ok) / max(1, len(ok)), 2), "rows": rows}
    print(m, {k: v for k, v in res[m].items() if k != "rows"}, flush=True)
(OUT / "asr_compare.json").write_text(json.dumps(res, ensure_ascii=False, indent=1))
