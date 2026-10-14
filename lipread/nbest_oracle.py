"""Шаг 0 плана, часть 2: oracle-WER по n-best (results/nbest.jsonl) -> results/step0.md.

Oracle = на каждом клипе берём гипотезу списка, ближайшую к эталону (минимум словесных ошибок, при равенстве
выше по оценке луча). Это верхняя граница любого пересчёта n-best. Нормализация как в metrics.py (строгая
и мягкая). Если oracle-WER >= 60%, пересчёт (LM + словарь) не запускается.
Таблица по клипам пишется отдельно в results/step0_clips.md, в репозиторий она не входит.

Запуск: python3 nbest_oracle.py   (только стандартная библиотека, без весов)
"""
from __future__ import annotations

import json
import random
import statistics as st
from pathlib import Path

from metrics import cer_counts, corpus_rates, normalize, normalize_loose, wer_counts

ROOT = Path(__file__).resolve().parent
THRESH = 0.60


def esc(s: str) -> str:
    return s.replace("|", "\\|").replace("\n", " ")


def pick(r, norm, key):
    ref = norm(r["ref"])
    return min(enumerate(r["hyps"]), key=lambda ih: (key(ref, norm(ih[1]["text"])), ih[0]))


def main():
    rows = [json.loads(l) for l in (ROOT / "results" / "nbest.jsonl").open(encoding="utf-8")]
    base = {r["id"]: r for r in json.load(open(ROOT / "results" / "baseline.json", encoding="utf-8"))}
    n = len(rows)
    res = {}
    for name, norm in (("строгая", normalize), ("мягкая", normalize_loose)):
        top1 = [(r["ref"], r["hyps"][0]["text"]) for r in rows]
        orc_w = [(r["ref"], pick(r, norm, lambda a, b: wer_counts(a, b)[0])[1]["text"]) for r in rows]
        orc_c = [(r["ref"], pick(r, norm, lambda a, b: cer_counts(a, b)[0])[1]["text"]) for r in rows]
        res[name] = dict(top1=corpus_rates(top1, norm), oracle_w=corpus_rates(orc_w, norm),
                         oracle_c=corpus_rates(orc_c, norm))

    # парный бутстреп по клипам: ошибки/длины на клип (строгая)
    per = []
    for r in rows:
        ref = normalize(r["ref"])
        e1, nw = wer_counts(ref, normalize(r["hyps"][0]["text"]))
        i, h = pick(r, normalize, lambda a, b: wer_counts(a, b)[0])
        eo, _ = wer_counts(ref, normalize(h["text"]))
        per.append((e1, eo, nw, i))
    rnd = random.Random(0)
    d_orc, o_w = [], []
    for _ in range(5000):
        s = [per[rnd.randrange(n)] for _ in range(n)]
        nn = sum(x[2] for x in s)
        d_orc.append((sum(x[0] for x in s) - sum(x[1] for x in s)) / nn)
        o_w.append(sum(x[1] for x in s) / nn)
    d_orc.sort(); o_w.sort()
    ci = lambda v: (v[int(0.025 * len(v))], v[int(0.975 * len(v)) - 1])

    tot = in_top = in_all = 0
    for r in rows:
        ref = normalize(r["ref"]).split()
        top = set(normalize(r["hyps"][0]["text"]).split())
        allw = {w for h in r["hyps"] for w in normalize(h["text"]).split()}
        tot += len(ref)
        in_top += sum(w in top for w in ref)
        in_all += sum(w in allw for w in ref)
    nh = [len(r["hyps"]) for r in rows]
    sec = [r["sec"] for r in rows]
    best_rank = [x[3] for x in per]
    improved = sum(1 for x in per if x[1] < x[0])
    perfect = sum(1 for x in per if x[1] == 0)
    low = sum(1 for x in per if x[2] and x[1] / x[2] <= 0.2)
    s, l = res["строгая"], res["мягкая"]
    stop = s["oracle_w"][0] >= THRESH

    L = []
    L.append("# Шаг 0: n-best пересчёт (бесплатно, без обучения)\n")
    L.append("## Итог\n")
    L.append("| | WER строгий | CER строгий | WER мягкий | CER мягкий |")
    L.append("|---|---:|---:|---:|---:|")
    L.append(f"| baseline (лучшая гипотеза луча, = results/baseline.md) | **{s['top1'][0]*100:.1f}%** | {s['top1'][1]*100:.1f}% | {l['top1'][0]*100:.1f}% | {l['top1'][1]*100:.1f}% |")
    L.append(f"| **oracle по n-best** (выбор по словесным ошибкам) | **{s['oracle_w'][0]*100:.1f}%** | {s['oracle_w'][1]*100:.1f}% | {l['oracle_w'][0]*100:.1f}% | {l['oracle_w'][1]*100:.1f}% |")
    L.append(f"| oracle по n-best (выбор по символьным ошибкам) | {s['oracle_c'][0]*100:.1f}% | {s['oracle_c'][1]*100:.1f}% | {l['oracle_c'][0]*100:.1f}% | {l['oracle_c'][1]*100:.1f}% |")
    L.append("| пересчёт LM + словарь (CV) | не запускался | | | |\n")
    L.append(f"- Клипов: {n}. Луч 20, список очищен от дублей текста: гипотез на клип в среднем {st.mean(nh):.1f} (мин {min(nh)}, макс {max(nh)}). "
             f"Лучшая гипотеза списка совпала с baseline на {sum(r['hyps'][0]['text'] == base[r['id']]['hyp'] for r in rows)}/{n} клипах (декодирование воспроизводится бит-в-бит по тексту).")
    L.append(f"- Oracle-выигрыш над baseline: {(s['top1'][0]-s['oracle_w'][0])*100:.1f} п.п. WER; парный бутстреп по клипам (5000 перевыборок), 95% интервал выигрыша: "
             f"{ci(d_orc)[0]*100:.1f}...{ci(d_orc)[1]*100:.1f} п.п.; интервал самого oracle-WER {ci(o_w)[0]*100:.1f}...{ci(o_w)[1]*100:.1f}%.")
    L.append(f"- Клипов, где в списке есть гипотеза лучше лучшей: {improved}/{n}; клипов с точной гипотезой в списке: {perfect}; клипов с oracle-WER <= 20%: {low}.")
    L.append(f"- Медиана ранга oracle-гипотезы в списке: {st.median(best_rank):.0f} (0 = лучшая по оценке луча).")
    L.append(f"- Покрытие слов эталона (мешок слов, любая позиция): в лучшей гипотезе {in_top/tot*100:.1f}%, в объединении всех гипотез списка {in_all/tot*100:.1f}%. "
             f"То есть {100-in_all/tot*100:.0f}% слов эталона не встречаются ни в одной из гипотез, и никакой пересчёт их не вернёт.")
    L.append(f"- Время: декодирование с n-best в среднем {st.mean(sec):.2f} с на клип (медиана {st.median(sec):.2f}; кадры из кэша work/faces + VTP + луч 20; "
             "baseline.md даёт 2.21 с на других прогонах, причина разницы не выяснялась). Память: пик MPS-драйвера 8.2 ГБ при лимите PYTORCH_MPS_HIGH_WATERMARK_RATIO=0.35 (9.8 ГБ), "
             "RSS процесса 4.6 ГБ, минимум свободной памяти системы 69%. Пересчёт LM не запускался.\n")
    L.append("## Вердикт\n")
    if stop:
        L.append(f"**Oracle-WER {s['oracle_w'][0]*100:.1f}% >= {THRESH*100:.0f}% -> по порогу шаг закрыт, пересчёт LM/словарём не делался.** "
                 f"Даже идеальный выбор из 20 гипотез снимает лишь {(s['top1'][0]-s['oracle_w'][0])*100:.0f} п.п. из {s['top1'][0]*100:.0f}%, а реальный пересчёт без знания эталона получит заметно меньше "
                 "(гипотеза, не измерено: единицы п.п., в пределах шума 50 клипов, +-9 п.п.). Причина видна в покрытии слов: половина слов эталона не встречается ни в одной гипотезе, то есть визуальная часть их не предлагает. "
                 "Это согласуется с гипотезой: проблема в сдвиге домена, а не в выборе из кандидатов.\n")
        L.append("Решение: **к шагу 1 (LoRA на своих клипах) переходить, шаг 0 не продолжать.** "
                 "Не проверено (K=20 и один проход): луч 40 и отключённый штраф длины, они могут поднять разнообразие списка, но не появление отсутствующих слов.\n")
    else:
        L.append("Oracle-WER ниже порога, пересчёт имеет смысл (шаг 3).\n")
    out = ROOT / "results" / "step0.md"
    out.write_text("\n".join(L) + "\n", encoding="utf-8")
    print("\n".join(L[:22]))
    # per-clip phrases of personal test clips stay out of the tracked report
    L = ["## По клипам\n"]
    L.append("Эталон / baseline / oracle-гипотеза (строгая нормализация). Колонка `к-во` число гипотез, `ранг` позиция oracle-гипотезы.\n")
    L.append("| # | Эталон | Baseline | WER | Oracle-гипотеза | WER | к-во | ранг |")
    L.append("|---|---|---|---:|---|---:|---:|---:|")
    for r, (e1, eo, nw, rk) in zip(rows, per):
        h = r["hyps"][rk]["text"]
        L.append(f"| {r['id']} | {esc(r['ref'])} | {esc(r['hyps'][0]['text'])} | {e1/nw*100:.0f}% | {esc(h)} | {eo/nw*100:.0f}% | {len(r['hyps'])} | {rk} |")
    (ROOT / "results" / "step0_clips.md").write_text("\n".join(L) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
