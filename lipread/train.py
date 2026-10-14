"""Обучение LoRA для MultiVSR на заранее посчитанных признаках VTP (VTP заморожен и в обучении не участвует).

Что обучается: адаптеры LoRA (ранг 16 по умолчанию) на проекциях q и v во всех вниманиях энкодера и декодера
(36 вниманий, 1,77 млн параметров). Потеря: teacher-forced кросс-энтропия по токенам Whisper-токенизатора,
цель `<|startoftranscript|><|ru|><|transcribe|><|notimestamps|>{текст}<|endoftext|>` (как у авторов, dataloader.py).

Данные: data/manifest.jsonl (его строит dataset.py). Источники: silent (беззвучные клипы), voiced (клипы
приложения диктовки), public (готовые признаки публичного набора). Смешивание весами:
    --mix public=0.5,silent=0.3,voiced=0.2      веса нормируются по источникам, у которых есть train-данные
    --early-steps N --early-mix public=0.8,silent=0.1,voiced=0.1   учебный план: первые N шагов другая смесь
Тест (clips/, split=test) в обучение и dev попасть не может: проверка по хэшу содержимого видео, по пути и по
нормализованному тексту (см. guard_no_test_leak). Для дымового теста есть --smoke-allow-test (только work/smoke/).

Контрольные точки: checkpoints/<run>/last.pt (всё для продолжения), step-NNNNNN.pt (раз в --ckpt-every шагов,
хранятся 2 последних), best.pt (лучший по dev, только адаптеры; его берёт evaluate.py --lora).
Продолжение: --resume. Остановка: --max-minutes (активное время, паузы mem_guard не считаются), --max-steps/--epochs, ранняя остановка по dev (--patience),
Ctrl-C/SIGTERM (чистая остановка с сохранением), свободная память < --min-free (сохранение и выход с кодом 3).

Запуск: ./guarded.sh train.py --run my1 [--resume] [--max-minutes 240]   (под охранником памяти tools/mem_guard.py)
"""
from __future__ import annotations

import memguard  # noqa: F401  (лимиты MPS до import torch)

import argparse
import json
import math
import os
import random
import signal
import sys
import time
from dataclasses import dataclass
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent
PREFIX = "<|startoftranscript|><|ru|><|transcribe|><|notimestamps|>"
TARGET_FORMATS = ("raw", "raw_sp", "lower", "lower_sp", "norm", "norm_sp")
SOURCES = ("public", "silent", "voiced")


# --- данные ----------------------------------------------------------------------------------------------
@dataclass
class Clip:
    id: str
    source: str
    split: str
    text: str
    feats: str
    frames: int
    hash: str
    video: str | None = None
    tokens: list | None = None


def load_manifest(path: Path) -> list[dict]:
    if not path.exists():
        raise SystemExit(f"Нет манифеста {path}. Сначала: ./run.sh dataset.py")
    return [json.loads(l) for l in path.read_text(encoding="utf8").splitlines() if l.strip()]


def guard_no_test_leak(rows: list[dict], clips_dir: Path, smoke_ok: bool = False) -> list[dict]:
    """Защита от утечки теста. Жёстко (SystemExit): хэш видео train/dev-строки совпал с хэшем тестового клипа,
    хэш в манифесте не совпал с реальным хэшем файла, видео лежит внутри clips/. Мягко (строка отбрасывается
    с предупреждением): нормализованный текст совпал с тестовой фразой. Возвращает разрешённые строки."""
    from dataset import HashCache, text_key
    hc = HashCache(ROOT / "work" / "hash_cache.json")
    test_hashes, test_texts = {}, set()
    for p in sorted(clips_dir.glob("*.mp4")):
        test_hashes[hc.get(p)] = p.stem
        if p.with_suffix(".txt").exists():
            test_texts.add(text_key(p.with_suffix(".txt").read_text(encoding="utf8")))
    for r in rows:
        if r["split"] == "test":
            test_hashes.setdefault(r["hash"], r["id"])
            test_texts.add(text_key(r["text"]))
    clips_real = clips_dir.resolve()
    bad, out = [], []
    for r in rows:
        if r["split"] == "test":
            continue
        reason = None
        if r["hash"] in test_hashes:
            reason = f"хэш совпадает с тестовым {test_hashes[r['hash']]}"
        elif r.get("video"):
            vp = Path(r["video"])
            if clips_real in vp.resolve().parents:
                reason = "видео лежит внутри clips/"
            elif vp.exists():
                real = hc.get(vp)
                if real != r["hash"]:
                    reason = "хэш в манифесте не совпал с файлом (пересоберите манифест)"
                elif real in test_hashes:
                    reason = f"хэш файла совпадает с тестовым {test_hashes[real]}"
        if reason:
            bad.append(f"{r['id']}: {reason}")
            continue
        if text_key(r["text"]) in test_texts:
            print(f"[guard] {r['id']}: текст совпал с тестовой фразой, строка исключена", file=sys.stderr)
            continue
        out.append(r)
    hc.save()
    if bad:
        if smoke_ok:
            print(f"[guard] ДЫМОВОЙ ТЕСТ: утечка теста разрешена для {len(bad)} клипов (--smoke-allow-test). "
                  f"Результаты ничего не значат.", file=sys.stderr)
            return [r for r in rows if r["split"] != "test"]
        raise SystemExit("ОТКАЗ: тестовые данные в обучении/dev:\n  " + "\n  ".join(bad[:10]) +
                         (f"\n  ... и ещё {len(bad) - 10}" if len(bad) > 10 else ""))
    return out


def parse_mix(s: str | None) -> dict[str, float]:
    if not s:
        return {}
    out = {}
    for part in s.split(","):
        k, v = part.split("=")
        k = k.strip()
        if k not in SOURCES:
            raise SystemExit(f"--mix: неизвестный источник {k!r}, допустимы {SOURCES}")
        out[k] = float(v)
    return out


def target_text(text: str, fmt: str) -> str:
    from metrics import normalize
    t = " ".join(text.split())
    if fmt in ("raw", "raw_sp"):
        base = t
    elif fmt in ("lower", "lower_sp"):
        base = t.lower()
    elif fmt in ("norm", "norm_sp"):
        base = normalize(t)
    else:
        raise ValueError(fmt)
    return (" " + base) if fmt.endswith("_sp") else base


def encode_target(tok, text: str, fmt: str) -> list[int]:
    return list(tok.encode(f"{PREFIX}{target_text(text, fmt)}<|endoftext|>"))


class FeatStore:
    """Признаки fp16 (T,512). silent/voiced держим в ОЗУ (мало), public читаем с диска по требованию."""

    def __init__(self):
        self.cache: dict[str, np.ndarray] = {}

    def get(self, c: Clip) -> np.ndarray:
        if c.source != "public":
            a = self.cache.get(c.id)
            if a is None:
                a = np.load(c.feats)
                self.cache[c.id] = a
            return a
        a = np.load(c.feats, mmap_mode="r")
        return np.asarray(a)


class MixSampler:
    """Бесконечный поток клипов: источник выбирается по весам, внутри источника перемешанный круг по клипам.
    Состояние сохраняется в контрольной точке (продолжение с того же места)."""

    def __init__(self, pools: dict[str, list[Clip]], seed: int):
        self.pools = {k: sorted(v, key=lambda c: c.id) for k, v in pools.items() if v}
        self.rng = random.Random(seed)
        self.order: dict[str, list[int]] = {}
        self.pos: dict[str, int] = {}
        self.epochs: dict[str, int] = {k: 0 for k in self.pools}
        for k in self.pools:
            self._reshuffle(k)

    def _reshuffle(self, k):
        idx = list(range(len(self.pools[k])))
        self.rng.shuffle(idx)
        self.order[k], self.pos[k] = idx, 0

    def sources(self):
        return list(self.pools)

    def next(self, weights: dict[str, float]) -> Clip:
        ks = [k for k in self.pools if weights.get(k, 0) > 0]
        k = self.rng.choices(ks, weights=[weights[k] for k in ks])[0]
        if self.pos[k] >= len(self.order[k]):
            self.epochs[k] += 1
            self._reshuffle(k)
        c = self.pools[k][self.order[k][self.pos[k]]]
        self.pos[k] += 1
        return c

    def state(self) -> dict:
        return dict(rng=self.rng.getstate(), order=self.order, pos=self.pos, epochs=self.epochs,
                    sizes={k: len(v) for k, v in self.pools.items()})

    def load(self, st: dict) -> bool:
        if st.get("sizes") != {k: len(v) for k, v in self.pools.items()}:
            return False  # данные изменились: начинаем с новой перестановки
        self.rng.setstate(st["rng"])
        self.order, self.pos, self.epochs = st["order"], st["pos"], st["epochs"]
        return True


def collate(clips: list[Clip], store: FeatStore, tgt_fmt: str, device, dtype, aug: dict | None, rng: np.random.RandomState):
    import torch
    feats = []
    for c in clips:
        f = store.get(c).astype(np.float32)
        if aug:
            if aug["crop"] and f.shape[0] > 40 and rng.rand() < 0.5:
                a, b = rng.randint(0, 4), rng.randint(0, 4)
                f = f[a:f.shape[0] - b]
            if aug["tmask"] > 0 and rng.rand() < 0.5:
                T = f.shape[0]
                budget = int(T * aug["tmask"])
                mean = f.mean(0, keepdims=True)
                for _ in range(2):
                    w = rng.randint(1, max(2, budget // 2 + 1))
                    s = rng.randint(0, max(1, T - w))
                    f[s:s + w] = mean
            if aug["noise"] > 0:
                f = f + rng.randn(*f.shape).astype(np.float32) * (aug["noise"] * float(f.std()))
        feats.append(f)
    B = len(clips)
    T = max(f.shape[0] for f in feats)
    x = np.zeros((B, T, 512), np.float32)
    mask = np.zeros((B, 1, T), np.int64)
    for i, f in enumerate(feats):
        x[i, :f.shape[0]] = f
        mask[i, 0, :f.shape[0]] = 1
    toks = [c.tokens for c in clips]
    L = max(len(t) for t in toks) - 1
    tin = np.zeros((B, L), np.int64)
    tout = np.full((B, L), -100, np.int64)
    for i, t in enumerate(toks):
        tin[i, :len(t) - 1] = t[:-1]
        tout[i, :len(t) - 1] = t[1:]
    tmask = torch.tril(torch.ones(1, L, L)) > 0
    return (torch.from_numpy(x).to(device=device, dtype=dtype), torch.from_numpy(mask).to(device),
            torch.from_numpy(tin).to(device), torch.from_numpy(tout).to(device), tmask.to(device))


# --- модель ----------------------------------------------------------------------------------------------
def build_base_model(device, dtype):
    import torch
    import mvsr
    mv = mvsr._multivsr()
    mv["models"].set_amp(device, False)
    model = mv["models"].build_model()
    ck = torch.load(mvsr.DEFAULT_CKPT, map_location="cpu", weights_only=False, mmap=True)["state_dict"]
    model.load_state_dict({(k[7:] if k.startswith("module.") else k): v for k, v in ck.items()})
    del ck
    if dtype != torch.float32:
        model = model.to(dtype)
    return model, mv


def seq_loss(model, batch, label_smoothing=0.0, reduction="mean"):
    import torch.nn.functional as F
    import torch
    x, smask, tin, tout, tmask = batch
    # CUDA: bf16 autocast над fp32-весами (код MultiVSR рассчитан на autocast, а не на чистые bf16-веса); MPS/CPU без изменений
    with torch.autocast("cuda", dtype=torch.bfloat16, enabled=x.device.type == "cuda"):
        logits = model(x, tin, smask, tmask)  # (B*L, V)
    return F.cross_entropy(logits.float(), tout.reshape(-1), ignore_index=-100, label_smoothing=label_smoothing,
                           reduction=reduction)


def eval_loss(model, clips, store, fmt, device, dtype, bs=8) -> tuple[float, int]:
    """Средняя потеря на токен по клипам (режим eval, без аугментации)."""
    import torch
    model.eval()
    tot, n = 0.0, 0
    rng = np.random.RandomState(0)
    with torch.no_grad():
        for i in range(0, len(clips), bs):
            ch = clips[i:i + bs]
            b = collate(ch, store, fmt, device, dtype, None, rng)
            s = seq_loss(model, b, reduction="sum").item()
            tot += s
            n += int((b[3] != -100).sum().item())
            del b
    model.train()
    return (tot / max(n, 1)), n


def save_atomic(obj, path: Path):
    import torch
    tmp = path.with_suffix(path.suffix + ".tmp")
    torch.save(obj, tmp)
    os.replace(tmp, path)


def probe_format(a, rows):
    """Какой формат целевого текста естественнее для исходной модели: NLL на слово при teacher forcing, базовая
    модель без LoRA. Выбор формата (6 вариантов), а не обучение."""
    import torch
    import mvsr
    device = mvsr.pick_device(a.device)
    model, mv = build_base_model(device, torch.float32)
    model = model.to(device).eval()
    tok = mv["tokenizer"]
    sel = [r for r in rows if r["split"] == a.probe_split]
    if a.probe_limit:
        sel = sel[:a.probe_limit]
    print(f"Проба формата на {len(sel)} клипах split={a.probe_split} (только прямой проход, базовая модель)")
    store, rng = FeatStore(), np.random.RandomState(0)
    res = {}
    for fmt in TARGET_FORMATS:
        nll, nw, nt = 0.0, 0, 0
        with torch.no_grad():
            for r in sel:
                c = Clip(r["id"], r["source"], r["split"], r["text"], r["feats"], r["frames"], r["hash"])
                c.tokens = encode_target(tok, c.text, fmt)
                b = collate([c], store, fmt, device, torch.float32, None, rng)
                # потеря только по токенам текста и EOS (без префикса <|ru|><|transcribe|><|notimestamps|>)
                import torch.nn.functional as F
                logits = model(b[0], b[2], b[1], b[4])
                l = F.cross_entropy(logits.float(), b[3].reshape(-1), ignore_index=-100, reduction="none")
                nll += float(l[3:].sum())
                nw += len(c.text.split())
                nt += len(c.tokens) - 4
        res[fmt] = (nll / nw, nll / nt)
        print(f"  {fmt:9s} NLL на слово {nll / nw:6.3f}   на токен {nll / nt:6.3f}   токенов на слово {nt / nw:4.2f}", flush=True)
        memguard.mps_cleanup()
    best = min(res, key=lambda k: res[k][0])
    print(f"Лучший формат по NLL на слово: {best}")


# --- основной цикл -------------------------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--run", default="run", help="имя запуска -> checkpoints/<run>/")
    ap.add_argument("--manifest", default=str(ROOT / "data" / "manifest.jsonl"))
    ap.add_argument("--clips-dir", default=str(ROOT / "clips"), help="тестовые клипы (для защиты от утечки)")
    ap.add_argument("--ckpt-dir", default=str(ROOT / "checkpoints"))
    ap.add_argument("--device", default="auto")
    ap.add_argument("--dtype", default="fp32", choices=["fp32", "bf16"], help="база; адаптеры всегда fp32")
    ap.add_argument("--target-format", default="norm", choices=TARGET_FORMATS,
                    help="вид целевого текста (см. --probe-format и README)")
    # LoRA
    ap.add_argument("--rank", type=int, default=16)
    ap.add_argument("--alpha", type=float, default=32.0)
    ap.add_argument("--lora-dropout", type=float, default=0.0)
    ap.add_argument("--init-lora", default=None, help="начать с адаптеров из этого .pt (дообучение)")
    # оптимизация
    ap.add_argument("--lr", type=float, default=1e-4)
    ap.add_argument("--warmup", type=int, default=100, help="шагов прогрева (оптимизатора)")
    ap.add_argument("--min-lr-ratio", type=float, default=0.1)
    ap.add_argument("--weight-decay", type=float, default=0.01)
    ap.add_argument("--batch", type=int, default=4, help="клипов в микробатче")
    ap.add_argument("--accum", type=int, default=4, help="накопление градиента (эффективный батч = batch*accum)")
    ap.add_argument("--max-seconds", type=float, default=8.0, help="клипы длиннее в обучение не берутся")
    ap.add_argument("--label-smoothing", type=float, default=0.0)
    ap.add_argument("--clip-norm", type=float, default=1.0)
    ap.add_argument("--time-mask", type=float, default=0.1, help="доля кадров под маскирование (0 = выкл)")
    ap.add_argument("--noise", type=float, default=0.02, help="гауссов шум, доля от std признаков клипа")
    ap.add_argument("--no-crop-aug", action="store_true")
    # длительность
    ap.add_argument("--epochs", type=float, default=20, help="проходов по ЛИЧНЫМ данным (silent+voiced) при текущей смеси")
    ap.add_argument("--max-steps", type=int, default=0, help="шагов оптимизатора (переопределяет --epochs)")
    ap.add_argument("--max-minutes", type=float, default=0, help="остановка по времени (0 = без лимита)")
    ap.add_argument("--eval-every", type=int, default=25, help="dev-потеря раз в N шагов")
    ap.add_argument("--ckpt-every", type=int, default=25, help="контрольная точка раз в N шагов")
    ap.add_argument("--patience", type=int, default=8, help="ранняя остановка: оценок подряд без улучшения dev")
    ap.add_argument("--min-delta", type=float, default=0.002)
    ap.add_argument("--early-stop-on", default="auto", help="auto | silent | voiced | public | all (какая dev-потеря решает)")
    ap.add_argument("--dev-max-public", type=int, default=300, help="сколько public-dev клипов считать")
    ap.add_argument("--min-train", type=int, default=20, help="меньше train-клипов -> отказ")
    # смесь
    ap.add_argument("--mix", default="public=0.5,silent=0.3,voiced=0.2",
                    help="веса источников; нормируются по источникам, у которых есть данные")
    ap.add_argument("--early-mix", default=None, help="смесь первых --early-steps шагов (учебный план)")
    ap.add_argument("--early-steps", type=int, default=0)
    # прочее
    ap.add_argument("--resume", action="store_true")
    ap.add_argument("--fresh", action="store_true", help="если запуск уже есть: удалить и начать заново")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--log-every", type=int, default=5)
    ap.add_argument("--min-free", type=int, default=memguard.MIN_FREE_DEFAULT,
                    help="аварийный выход при свободной памяти < N%% (основной ограничитель: tools/mem_guard.py, пауза на 15%%)")
    ap.add_argument("--clean-every", type=int, default=10, help="empty_cache и проверка памяти раз в N микробатчей")
    ap.add_argument("--smoke-allow-test", action="store_true",
                    help="ТОЛЬКО дымовой тест: разрешить тестовые клипы в train (манифест и --ckpt-dir внутри work/smoke/)")
    ap.add_argument("--probe-format", action="store_true", help="не обучать: сравнить форматы целевого текста")
    ap.add_argument("--probe-split", default="dev")
    ap.add_argument("--probe-limit", type=int, default=0)
    a = ap.parse_args()

    memguard.require_free(a.min_free, "старт train.py")
    rows = load_manifest(Path(a.manifest))

    if a.probe_format:
        probe_format(a, rows)
        return

    smoke = False
    if a.smoke_allow_test:
        smoke_root = (ROOT / "work" / "smoke").resolve()
        if smoke_root not in Path(a.manifest).resolve().parents or smoke_root not in Path(a.ckpt_dir).resolve().parents:
            raise SystemExit("--smoke-allow-test допустим только если и --manifest, и --ckpt-dir внутри work/smoke/")
        smoke = True
    rows = guard_no_test_leak(rows, Path(a.clips_dir), smoke_ok=smoke)

    import torch
    import torch.nn.functional as F  # noqa: F401
    import lora as L
    import mvsr

    device = mvsr.pick_device(a.device)
    dtype = torch.bfloat16 if a.dtype == "bf16" else torch.float32
    torch.manual_seed(a.seed)
    np_rng = np.random.RandomState(a.seed)

    # --- данные
    model, mv = build_base_model(device, dtype)
    tok = mv["tokenizer"]
    max_frames = int(a.max_seconds * 25)
    train, dev, dropped = [], [], 0
    for r in rows:
        if r["split"] not in ("train", "dev"):
            continue
        if r["frames"] > max_frames or r["frames"] < 10:
            dropped += 1
            continue
        c = Clip(r["id"], r["source"], r["split"], r["text"], r["feats"], r["frames"], r["hash"], r.get("video"))
        c.tokens = encode_target(tok, c.text, a.target_format)
        if len(c.tokens) > 120:
            dropped += 1
            continue
        (train if r["split"] == "train" else dev).append(c)
    pools = {s: [c for c in train if c.source == s] for s in SOURCES}
    dev_by = {s: sorted([c for c in dev if c.source == s], key=lambda c: c.hash) for s in SOURCES}
    dev_by["public"] = dev_by["public"][:a.dev_max_public]
    print(f"train: " + ", ".join(f"{s}={len(v)}" for s, v in pools.items()) +
          f" | dev: " + ", ".join(f"{s}={len(v)}" for s, v in dev_by.items()) + f" | отброшено (длина) {dropped}")
    if len(train) < a.min_train:
        raise SystemExit(f"train-клипов {len(train)} < {a.min_train}: нечему учиться (запишите клипы, ./run.sh dataset.py)")
    if not any(dev_by.values()):
        raise SystemExit("нет dev-клипов: ранняя остановка и выбор лучшей точки невозможны")
    for s, v in dev_by.items():
        if 0 < len(v) < 10:
            print(f"[предупреждение] dev {s}: всего {len(v)} клипов, оценка шумная", file=sys.stderr)

    avail = [s for s in SOURCES if pools[s]]
    def norm_mix(m):
        w = {s: m.get(s, 0.0) for s in avail}
        if sum(w.values()) <= 0:
            w = {s: 1.0 for s in avail}  # ни один из перечисленных источников не имеет данных
        t = sum(w.values())
        return {s: v / t for s, v in w.items()}
    main_mix = norm_mix(parse_mix(a.mix))
    early_mix = norm_mix(parse_mix(a.early_mix)) if a.early_mix and a.early_steps > 0 else None
    print("смесь:", {k: round(v, 3) for k, v in main_mix.items()},
          ("| первые %d шагов: %s" % (a.early_steps, {k: round(v, 3) for k, v in early_mix.items()})) if early_mix else "")

    eff = a.batch * a.accum
    personal = sum(len(pools[s]) for s in ("silent", "voiced"))
    pshare = sum(main_mix.get(s, 0) for s in ("silent", "voiced"))
    if a.max_steps:
        total_steps = a.max_steps
    elif personal and pshare > 0:
        total_steps = max(1, int(math.ceil(a.epochs * personal / eff / pshare)))
    else:
        raise SystemExit("нет личных данных: задайте --max-steps")
    print(f"эффективный батч {eff} клипов, всего шагов оптимизатора {total_steps} "
          f"(~{total_steps * a.accum * a.batch / max(len(train), 1):.1f} проходов по всем train)")

    # --- LoRA
    ntr = L.apply_lora(model, a.rank, a.alpha, a.lora_dropout)
    model = model.to(device)
    params = L.lora_params(model)
    print(f"LoRA r={a.rank}: обучаемых параметров {ntr / 1e6:.3f} млн, устройство {device}, база {a.dtype}")
    opt = torch.optim.AdamW(params, lr=a.lr, betas=(0.9, 0.999), weight_decay=a.weight_decay)
    cfg = dict(r=a.rank, alpha=a.alpha, targets="q,v", target_format=a.target_format, dtype=a.dtype)

    def lr_at(step):  # step: уже сделано шагов оптимизатора
        if step < a.warmup:
            return a.lr * (step + 1) / a.warmup
        p = min(1.0, (step - a.warmup) / max(1, total_steps - a.warmup))
        return a.lr * (a.min_lr_ratio + (1 - a.min_lr_ratio) * 0.5 * (1 + math.cos(math.pi * p)))

    run_dir = Path(a.ckpt_dir) / a.run
    last = run_dir / "last.pt"
    if run_dir.exists() and last.exists() and not a.resume:
        if a.fresh:
            import shutil
            shutil.rmtree(run_dir)
        else:
            raise SystemExit(f"{run_dir} уже есть. Добавьте --resume (продолжить) или --fresh (начать заново)")
    run_dir.mkdir(parents=True, exist_ok=True)

    sampler = MixSampler(pools, a.seed)
    store = FeatStore()
    step, best, bad, train_sec = 0, float("inf"), 0, 0.0
    if a.init_lora and not (a.resume and last.exists()):
        ck0 = torch.load(a.init_lora, map_location="cpu", weights_only=False)
        L.load_lora_state_dict(model, ck0["lora"])
        print(f"адаптеры инициализированы из {a.init_lora} (шаг {ck0.get('step')})")
    if a.resume and last.exists():
        ck = torch.load(last, map_location="cpu", weights_only=False)
        if ck["config"]["r"] != a.rank:
            raise SystemExit("ранг LoRA в контрольной точке другой")
        if ck["config"].get("target_format") != a.target_format:
            print(f"[предупреждение] формат цели в точке {ck['config'].get('target_format')} != {a.target_format}", file=sys.stderr)
        L.load_lora_state_dict(model, ck["lora"])
        opt.load_state_dict(ck["optimizer"])
        step, best, bad, train_sec = ck["step"], ck["best_dev"], ck["bad_evals"], ck.get("train_seconds", 0.0)
        ok = sampler.load(ck["sampler"])
        print(f"продолжаю с шага {step}, лучший dev {best:.4f}, сэмплер {'восстановлен' if ok else 'пересоздан (данные изменились)'}")
    elif a.resume:
        print("--resume: контрольной точки нет, начинаю с нуля")

    aug = dict(crop=not a.no_crop_aug, tmask=a.time_mask, noise=a.noise)
    stop = {"flag": None}
    for sg in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sg, lambda *_: stop.update(flag="сигнал остановки"))

    def which_dev():
        if a.early_stop_on == "all":
            return [c for s in SOURCES for c in dev_by[s]], "all"
        if a.early_stop_on != "auto":
            return dev_by[a.early_stop_on], a.early_stop_on
        for s in ("silent", "voiced", "public"):  # целевой домен важнее
            if dev_by[s]:
                return dev_by[s], s
        return [], "none"
    dev_main, dev_name = which_dev()
    print(f"ранняя остановка по dev: {dev_name} ({len(dev_main)} клипов), терпение {a.patience} оценок")

    def lora_ckpt(full: bool):
        d = dict(lora=L.lora_state_dict(model), config=cfg, step=step, best_dev=best)
        if full:
            d.update(optimizer=opt.state_dict(), sampler=sampler.state(), bad_evals=bad, train_seconds=train_sec,
                     args=vars(a))
        return d

    def save_ckpts(tag_step=True):
        save_atomic(lora_ckpt(True), last)
        if tag_step:
            save_atomic(lora_ckpt(False), run_dir / f"step-{step:06d}.pt")
            olds = sorted(run_dir.glob("step-*.pt"))
            for o in olds[:-2]:
                o.unlink()

    log_f = (run_dir / "train_log.jsonl").open("a", encoding="utf8")
    def log(d):
        log_f.write(json.dumps(d, ensure_ascii=False) + "\n")
        log_f.flush()

    # --- обучение
    model.train()
    peak_driver = peak_alloc = 0.0
    min_free_seen, nan_run = 100, 0
    clock = memguard.ActiveClock()  # активное время: паузы SIGSTOP от mem_guard не считаются
    step_times, losses, micro = [], [], 0
    from collections import Counter
    src_win = Counter()  # какие источники попали в батчи с прошлой строки лога
    d0 = eval_loss(model, dev_main, store, a.target_format, device, dtype)[0]
    print(f"dev-потеря на старте ({dev_name}): {d0:.4f}", flush=True)
    if step == 0:
        log(dict(step=0, dev=d0, dev_name=dev_name))
        best = d0 if best == float("inf") else best
        save_atomic(lora_ckpt(False), run_dir / "best.pt")
    stop_reason = None
    while step < total_steps:
        if stop["flag"]:
            stop_reason = stop["flag"]
            break
        if a.max_minutes and clock.active() > a.max_minutes * 60:
            stop_reason = f"лимит активного времени {a.max_minutes} мин (паузы mem_guard не в счёт)"
            break
        t0 = clock.active()
        for g in opt.param_groups:
            g["lr"] = lr_at(step)
        mix = early_mix if (early_mix and step < a.early_steps) else main_mix
        tot_loss, ok_micro = 0.0, 0
        for _ in range(a.accum):
            clips = [sampler.next(mix) for _ in range(a.batch)]
            src_win.update(c.source for c in clips)
            batch = collate(clips, store, a.target_format, device, dtype, aug, np_rng)
            loss = seq_loss(model, batch, a.label_smoothing)
            if not torch.isfinite(loss):
                nan_run += 1
                print(f"[предупреждение] нефинитная потеря на шаге {step}, микробатч пропущен ({nan_run})", file=sys.stderr)
                opt.zero_grad(set_to_none=True)
                if nan_run > 10:
                    save_ckpts(False)
                    raise SystemExit("слишком много NaN подряд; контрольная точка last.pt сохранена, попробуйте --lr вдвое меньше")
                continue
            nan_run = 0
            (loss / a.accum).backward()
            tot_loss += loss.item()
            ok_micro += 1
            micro += 1
            del batch, loss
            if micro % a.clean_every == 0:
                memguard.mps_cleanup()
                f = memguard.free_pct()
                min_free_seen = min(min_free_seen, f)
                if f < a.min_free:
                    stop["flag"] = f"свободной памяти {f}% < {a.min_free}%"
        if device == "mps":
            peak_driver = max(peak_driver, torch.mps.driver_allocated_memory() / 2**30)
            peak_alloc = max(peak_alloc, torch.mps.current_allocated_memory() / 2**30)
        if ok_micro == 0:
            continue
        torch.nn.utils.clip_grad_norm_(params, a.clip_norm)
        opt.step()
        opt.zero_grad(set_to_none=True)
        step += 1
        if device == "mps":
            torch.mps.synchronize()
        dt = clock.active() - t0
        step_times.append(dt)
        train_sec += dt
        losses.append(tot_loss / ok_micro)
        if step % a.log_every == 0 or step == 1:
            m = np.mean(losses[-a.log_every:])
            print(f"шаг {step}/{total_steps}  loss {m:.4f}  lr {lr_at(step - 1):.2e}  {dt:.2f} с/шаг "
                  f"({dt / a.accum:.2f} с/микробатч)  MPS драйвер {peak_driver:.2f} ГБ  "
                  f"источники {dict(src_win)}", flush=True)
            log(dict(step=step, loss=float(m), lr=lr_at(step - 1), sec=dt, driver_gb=peak_driver, sources=dict(src_win)))
            src_win.clear()
        if step % a.eval_every == 0 or step == total_steps:
            dl, _ = eval_loss(model, dev_main, store, a.target_format, device, dtype)
            extra = {}
            for s in SOURCES:
                if dev_by[s] and dev_by[s] is not dev_main:
                    extra[s] = eval_loss(model, dev_by[s], store, a.target_format, device, dtype)[0]
            improved = dl < best - a.min_delta
            print(f"  dev[{dev_name}] {dl:.4f} (лучший {min(best, dl):.4f}){' *' if improved else ''}"
                  + "".join(f"  dev[{s}] {v:.4f}" for s, v in extra.items()), flush=True)
            log(dict(step=step, dev=dl, dev_name=dev_name, extra=extra))
            if improved:
                best, bad = dl, 0
                save_atomic(lora_ckpt(False), run_dir / "best.pt")
            else:
                bad += 1
                if dl < best:
                    best = dl
                    save_atomic(lora_ckpt(False), run_dir / "best.pt")
            if bad >= a.patience:
                stop_reason = f"ранняя остановка: dev не улучшался {bad} оценок подряд"
                save_ckpts()
                break
            memguard.mps_cleanup()
        if step % a.ckpt_every == 0:
            save_ckpts()
    else:
        stop_reason = stop_reason or "все шаги выполнены"

    if stop_reason is None:
        stop_reason = stop["flag"] or "?"
    save_ckpts(tag_step=False)
    st = np.array(step_times[1:] if len(step_times) > 1 else step_times or [0.0])
    summary = dict(run=a.run, steps=step, total_steps=total_steps, stop_reason=stop_reason, best_dev=best,
                   dev_start=d0, dev_name=dev_name, loss_first=float(np.mean(losses[:5])) if losses else None,
                   loss_last=float(np.mean(losses[-5:])) if losses else None,
                   sec_per_step=float(st.mean()), accum=a.accum, batch=a.batch, peak_driver_gb=peak_driver,
                   peak_alloc_gb=peak_alloc, rss_peak_gb=memguard.mps_stats()[2], min_free_pct=min_free_seen,
                   train_clips={s: len(v) for s, v in pools.items()}, mix=main_mix, trainable_params=ntr,
                   active_minutes=clock.active() / 60, paused_minutes=clock.paused / 60)
    (run_dir / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=1), encoding="utf8")
    print("\nИТОГ:", json.dumps(summary, ensure_ascii=False))
    print(f"остановка: {stop_reason}. Лучшие адаптеры: {run_dir / 'best.pt'}")
    if stop_reason.startswith("свободной памяти"):
        sys.exit(3)


if __name__ == "__main__":
    main()
