"""Оценка MultiVSR (русский, только видео) на ваших клипах из clips/.

Для каждого clips/NNN.mp4 + NNN.txt: предобработка как у авторов (preprocess.py, кэш в work/faces/),
распознавание с --lang_id ru, сравнение с эталоном. В конце WER, CER, средняя задержка на клип,
таблица в results/baseline.md.

WER/CER считаются по нормализованному тексту: нижний регистр, ё -> е, без пунктуации. Отдельной строкой
дан "мягкий" вариант (цифры -> слова, GitHub -> гитхаб и т. п.), см. metrics.py.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import platform
import statistics
import subprocess
import sys
import time
from pathlib import Path

import memguard  # noqa: E402,F401  лимиты памяти MPS (watermark 0.35/0.25) до import torch
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")  # до import torch (его тянет mvsr)

ROOT = Path(__file__).resolve().parent


def md_escape(s: str) -> str:
    return s.replace("|", "\\|").replace("\n", " ")


def multivsr_commit() -> str:
    try:
        return subprocess.run(["git", "-C", str(ROOT / "multivsr"), "rev-parse", "--short", "HEAD"],
                              capture_output=True, text=True, check=True).stdout.strip()
    except Exception:
        return "?"


def compare_section(a, rows, wer, cer, wer_l, cer_l, lat_mean, exact, m) -> list[str]:
    """Блок отчёта: что за адаптеры, таблица метрик против baseline, парный бутстреп по клипам."""
    import numpy as np
    from metrics import corpus_rates, normalize, normalize_loose, wer_counts
    out = []
    info = m.lora_info or {}
    cfg = info.get("config", {})
    out.append("## Дообученная модель против исходной")
    out.append("")
    out.append(f"- Адаптеры: `{info.get('path')}`, шаг {info.get('step')}, ранг {cfg.get('r')}, alpha {cfg.get('alpha')}, "
               f"цели {cfg.get('targets')}, формат цели `{cfg.get('target_format')}`, слито {info.get('merged')} адаптеров в веса")
    summ = Path(info.get("path", "")).with_name("summary.json")
    if summ.exists():
        sj = json.loads(summ.read_text(encoding="utf8"))
        out.append(f"- Обучение: {sj['steps']} шагов (остановка: {sj['stop_reason']}), клипов train {sj['train_clips']}, "
                   f"dev-потеря {sj['dev_start']:.3f} -> {sj['best_dev']:.3f} ({sj['dev_name']}), "
                   f"{sj['sec_per_step']:.2f} с/шаг, пик MPS-драйвера {sj['peak_driver_gb']:.1f} ГБ")
    bj = Path(a.baseline_json)
    if not bj.exists():
        out.append(f"- Сравнение с baseline невозможно: нет {bj}. Запустите `./run.sh evaluate.py` без --lora.")
        out.append("")
        return out
    base = {r["id"]: r for r in json.loads(bj.read_text(encoding="utf8"))}
    ids = [r["id"] for r in rows if r["id"] in base]
    ref = {r["id"]: r["ref"] for r in rows}
    hyp_ft = {r["id"]: r["hyp"] for r in rows}
    hyp_b = {i: base[i].get("hyp", "") for i in ids}
    pairs_b = [(ref[i], hyp_b[i]) for i in ids]
    pairs_f = [(ref[i], hyp_ft[i]) for i in ids]
    wb, cb = corpus_rates(pairs_b, normalize)
    wbl, cbl = corpus_rates(pairs_b, normalize_loose)
    wf, cf = corpus_rates(pairs_f, normalize)
    wfl, cfl = corpus_rates(pairs_f, normalize_loose)
    exact_b = sum(1 for r_, h_ in pairs_b if normalize(r_) == normalize(h_))
    exact_f = sum(1 for r_, h_ in pairs_f if normalize(r_) == normalize(h_))
    lat_b = [base[i]["sec"] for i in ids if base[i].get("sec") is not None]
    # парный бутстреп: перевыборка клипов, разность корпусного WER (дообученная минус исходная)
    eb = np.array([wer_counts(normalize(r_), normalize(h_)) for r_, h_ in pairs_b], dtype=float)
    ef = np.array([wer_counts(normalize(r_), normalize(h_)) for r_, h_ in pairs_f], dtype=float)
    rng = np.random.RandomState(0)
    n = len(ids)
    diffs = []
    for _ in range(5000):
        k = rng.randint(0, n, n)
        diffs.append(ef[k, 0].sum() / ef[k, 1].sum() - eb[k, 0].sum() / eb[k, 1].sum())
    lo, hi = np.percentile(diffs, [2.5, 97.5])
    d = (ef[:, 0].sum() / ef[:, 1].sum() - eb[:, 0].sum() / eb[:, 1].sum()) * 100
    out.append("")
    out.append(f"Клипов в сравнении: {n}. Строгая нормализация: нижний регистр, ё=е, без пунктуации; мягкая: цифры в слова, названия кириллицей.")
    out.append("")
    out.append("| Метрика | Исходная модель | + LoRA | Разность |")
    out.append("|---|---:|---:|---:|")
    for name, x, y in (("WER строгий", wb, wf), ("CER строгий", cb, cf), ("WER мягкий", wbl, wfl), ("CER мягкий", cbl, cfl)):
        out.append(f"| {name} | {x * 100:.1f}% | {y * 100:.1f}% | {(y - x) * 100:+.1f} п.п. |")
    out.append(f"| Точных совпадений | {exact_b} | {exact_f} | {exact_f - exact_b:+d} |")
    if lat_b:
        out.append(f"| Задержка на клип, с | {sum(lat_b) / len(lat_b):.2f} | {lat_mean:.2f} | |")
    out.append("")
    verdict = ("разность значима (интервал не содержит 0)" if (lo > 0 or hi < 0) else
               "разность в пределах шума (интервал содержит 0)")
    out.append(f"**Парный бутстреп по клипам (5000 перевыборок): изменение WER {d:+.1f} п.п., 95% интервал "
               f"[{lo * 100:+.1f}; {hi * 100:+.1f}] п.п., {verdict}.** Отрицательное значение = стало лучше.")
    out.append("")
    out.append("Пороги из плана: WER < 55% продолжаем масштабировать, < 40% можно встраивать в Lipflow, >= 70% дообучение не помогает.")
    out.append("")
    out.append("| # | Эталон | Исходная | + LoRA | WER было | WER стало |")
    out.append("|---|---|---|---|---:|---:|")
    for i in ids:
        eb_, nb_ = wer_counts(normalize(ref[i]), normalize(hyp_b[i]))
        ef_, nf_ = wer_counts(normalize(ref[i]), normalize(hyp_ft[i]))
        out.append(f"| {i} | {md_escape(ref[i])} | {md_escape(hyp_b[i])} | {md_escape(hyp_ft[i])} | "
                   f"{(eb_ / nb_ * 100 if nb_ else 0):.0f}% | {(ef_ / nf_ * 100 if nf_ else 0):.0f}% |")
    out.append("")
    out.append("## Полная таблица (только дообученная модель)")
    out.append("")
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--clips", default=str(ROOT / "clips"), help="папка с NNN.mp4 и NNN.txt")
    ap.add_argument("--faces", default=str(ROOT / "work" / "faces"), help="кэш предобработанных треков лица")
    ap.add_argument("--out", default=None, help="markdown-отчёт (по умолчанию results/baseline.md)")
    ap.add_argument("--lang", default="ru", help="язык (--lang_id MultiVSR); 'auto' = пусть определяет модель")
    ap.add_argument("--device", default="auto", help="auto (mps, иначе cpu) | mps | cpu | cuda")
    ap.add_argument("--ckpt", default=str(ROOT / "weights" / "model.pth"), help="lip-reading transformer")
    ap.add_argument("--venc-ckpt", default=str(ROOT / "weights" / "feature_extractor.pth"), help="VTP feature extractor")
    ap.add_argument("--beam", type=int, default=20, help="ширина луча (у авторов 20)")
    ap.add_argument("--max-decode-len", type=int, default=100, help="максимум токенов на 14-секундный кусок (у авторов 100)")
    ap.add_argument("--fp16", default=None, choices=["true", "false"], help="autocast fp16 (по умолчанию: только cuda)")
    ap.add_argument("--limit", type=int, default=0, help="взять только первые N клипов")
    ap.add_argument("--min-track", type=int, default=10, help="минимум кадров лица в треке (у авторов 100)")
    ap.add_argument("--force-preprocess", action="store_true", help="пересчитать кэш work/faces")
    ap.add_argument("--no-warmup", action="store_true", help="не делать прогревочный прогон перед замером")
    ap.add_argument("--lora", default=None, help="адаптеры LoRA из train.py (checkpoints/<run>/best.pt): оценка base+LoRA, "
                    "отчёт results/finetune-<дата>.md со сравнением с baseline")
    ap.add_argument("--baseline-json", default=str(ROOT / "results" / "baseline.json"), help="результаты исходной модели для сравнения")
    ap.add_argument("--note", default="", help="строка-предупреждение в начало отчёта")
    ap.add_argument("--min-free", type=int, default=memguard.MIN_FREE_DEFAULT, help="стоп, если свободной памяти меньше N%%")
    ap.add_argument("--random-weights", action="store_true",
                    help="ТЕСТ ПАЙПЛАЙНА: случайные веса вместо чекпойнтов; результат бессмысленный, отчёт в results/dryrun.md")
    a = ap.parse_args()

    clips_dir = Path(a.clips)
    clips = sorted(p for p in clips_dir.glob("*.mp4") if (p.with_suffix(".txt")).exists())
    if a.limit:
        clips = clips[:a.limit]
    if not clips:
        sys.exit(f"В {clips_dir} нет пар NNN.mp4 + NNN.txt. Сначала: uv run record.py")

    if not a.random_weights:
        missing = [p for p in (a.ckpt, a.venc_ckpt) if not Path(p).exists()]
        if missing:
            sys.exit("Нет файлов весов:\n  " + "\n  ".join(missing) +
                     "\nСкачайте их: ./download_weights.sh (около 4,5 ГБ), см. README.")

    from metrics import corpus_rates, normalize, normalize_loose, wer_counts
    from mvsr import MultiVSR
    from preprocess import preprocess_video

    default_name = "dryrun.md" if a.random_weights else (f"finetune-{dt.date.today().isoformat()}.md" if a.lora else "baseline.md")
    out_md = Path(a.out) if a.out else ROOT / "results" / default_name
    memguard.require_free(a.min_free, "старт evaluate.py")
    out_md.parent.mkdir(parents=True, exist_ok=True)
    faces_dir = Path(a.faces)
    faces_dir.mkdir(parents=True, exist_ok=True)

    # 1. предобработка ---------------------------------------------------------------------------
    print(f"Клипов: {len(clips)}. Предобработка (S3FD + кроп лица как у MultiVSR)...")
    rows = []
    for c in clips:
        ref = c.with_suffix(".txt").read_text(encoding="utf8").strip()
        face = faces_dir / (c.stem + ".avi")
        t0 = time.perf_counter()
        err = None
        if a.force_preprocess or not face.exists():
            try:
                info = preprocess_video(c, face, min_track=a.min_track)
            except Exception as e:  # лицо не найдено и т. п.
                err, info = str(e), {}
        else:
            info = {"cached": True}
        rows.append(dict(id=c.stem, clip=str(c), face=str(face), ref=ref, hyp="", err=err,
                         t_pre=time.perf_counter() - t0, pre=info))
        print(f"  {c.name}: {'ОШИБКА ' + err if err else 'ok ' + str(info)}")

    # 2. модель ----------------------------------------------------------------------------------
    print("\nЗагрузка модели...")
    t0 = time.perf_counter()
    m = MultiVSR(device=a.device, ckpt=a.ckpt, venc_ckpt=a.venc_ckpt, beam_size=a.beam, max_decode_len=a.max_decode_len,
                 fp16=None if a.fp16 is None else a.fp16 == "true", random_weights=a.random_weights, lora=a.lora)
    if m.lora_info:
        print(f"LoRA: {m.lora_info['path']} (шаг {m.lora_info['step']}, слито адаптеров {m.lora_info['merged']})")
    t_load = time.perf_counter() - t0
    print(f"Устройство: {m.device}, fp16={m.fp16}, загрузка {t_load:.1f} с")
    lang = None if a.lang == "auto" else a.lang

    ok_rows = [r for r in rows if not r["err"]]
    if ok_rows and not a.no_warmup:
        print("Прогрев (не входит в замер)...")
        m.transcribe(ok_rows[0]["face"], lang)

    # 3. распознавание ---------------------------------------------------------------------------
    print("\n#    сек  WER   эталон -> гипотеза")
    for r in rows:
        if r["err"]:
            r["sec"] = None
            print(f"{r['id']}  --   --    {r['ref']}\n                 НЕТ ЛИЦА: {r['err']}")
            continue
        memguard.require_free(a.min_free, f"клип {r['id']}")
        r["hyp"], r["sec"] = m.transcribe(r["face"], lang)
        memguard.mps_cleanup()
        e, n = wer_counts(normalize(r["ref"]), normalize(r["hyp"]))
        r["wer"] = e / n if n else 0.0
        print(f"{r['id']} {r['sec']:5.2f} {r['wer'] * 100:4.0f}%  {r['ref']}\n                 -> {r['hyp']}")

    # 4. метрики ---------------------------------------------------------------------------------
    pairs = [(r["ref"], r["hyp"]) for r in rows]  # клипы без лица считаются полностью пропущенными
    wer, cer = corpus_rates(pairs, normalize)
    wer_l, cer_l = corpus_rates(pairs, normalize_loose)
    secs = [r["sec"] for r in rows if r["sec"] is not None]
    lat_mean = statistics.mean(secs) if secs else float("nan")
    lat_med = statistics.median(secs) if secs else float("nan")
    pre_mean = statistics.mean(r["t_pre"] for r in rows if not r["err"] and not r["pre"].get("cached")) \
        if any(not r["err"] and not r["pre"].get("cached") for r in rows) else float("nan")
    n_fail = sum(1 for r in rows if r["err"])
    exact = sum(1 for r in rows if normalize(r["ref"]) == normalize(r["hyp"]))

    print("\n" + "=" * 70)
    print(f"Клипов: {len(rows)} (без лица: {n_fail}), точных совпадений: {exact}")
    print(f"WER: {wer * 100:.1f}%   CER: {cer * 100:.1f}%   (строгая нормализация)")
    print(f"WER: {wer_l * 100:.1f}%   CER: {cer_l * 100:.1f}%   (мягкая: цифры -> слова, названия -> кириллица)")
    print(f"Задержка инференса на клип: среднее {lat_mean:.2f} с, медиана {lat_med:.2f} с "
          f"(устройство {m.device}, без предобработки)")

    # 5. отчёт -----------------------------------------------------------------------------------
    import torch
    L = []
    title = f"MultiVSR + LoRA, русский, оценка на {len(rows)} тестовых клипах" if a.lora else "MultiVSR, русский, базовый замер"
    L.append(f"# {title}" + (" (ТЕСТ ПАЙПЛАЙНА, случайные веса: цифры бессмысленны)" if a.random_weights else ""))
    L.append("")
    if a.note:
        L.append(f"> **{a.note}**")
        L.append("")
    L.append(f"- Дата: {dt.datetime.now().strftime('%Y-%m-%d %H:%M')}")
    L.append(f"- Клипов: {len(rows)}, без найденного лица: {n_fail}, точных совпадений: {exact}")
    L.append(f"- **WER: {wer * 100:.1f}%**, **CER: {cer * 100:.1f}%** (нижний регистр, ё=е, без пунктуации)")
    L.append(f"- Мягкая нормализация (цифры в слова, GitHub=гитхаб): WER {wer_l * 100:.1f}%, CER {cer_l * 100:.1f}%")
    L.append(f"- Средняя задержка инференса на клип: **{lat_mean:.2f} с** (медиана {lat_med:.2f} с; кадры + энкодер + луч {a.beam}; "
             f"без предобработки; прогрев {'нет' if a.no_warmup else 'был'})")
    if pre_mean == pre_mean:
        L.append(f"- Предобработка (ffmpeg + S3FD на CPU + кроп): в среднем {pre_mean:.2f} с на клип")
    L.append(f"- Язык: `{a.lang}`, устройство: `{m.device}`, fp16: {m.fp16}, загрузка моделей {t_load:.1f} с")
    L.append(f"- Среда: {platform.platform()}, {platform.processor() or platform.machine()}, torch {torch.__version__}, "
             f"MultiVSR commit {multivsr_commit()} (+ наши патчи под Apple Silicon)")
    L.append("")
    if a.lora:
        L.extend(compare_section(a, rows, wer, cer, wer_l, cer_l, lat_mean, exact, m))
    L.append("| # | Эталон | Гипотеза | WER | сек |")
    L.append("|---|---|---|---:|---:|")
    for r in rows:
        if r["err"]:
            L.append(f"| {r['id']} | {md_escape(r['ref'])} | _нет лица_ | 100% | |")
        else:
            L.append(f"| {r['id']} | {md_escape(r['ref'])} | {md_escape(r['hyp'])} | {r['wer'] * 100:.0f}% | {r['sec']:.2f} |")
    L.append("")
    a_, d_, rss_ = memguard.mps_stats()
    print(f"Память: пик драйвера MPS {d_:.2f} ГБ, RSS {rss_:.2f} ГБ")
    if a.lora:
        print(f"SUMMARY {dt.date.today().isoformat()} lora={a.lora} WER={wer * 100:.1f} CER={cer * 100:.1f} "
              f"WERsoft={wer_l * 100:.1f} CERsoft={cer_l * 100:.1f}")
    out_md.write_text("\n".join(L) + "\n", encoding="utf8")
    (out_md.with_suffix(".json")).write_text(
        json.dumps([{k: v for k, v in r.items() if k != "pre"} for r in rows], ensure_ascii=False, indent=1), encoding="utf8")
    print(f"\nОтчёт: {out_md}")


if __name__ == "__main__":
    main()
