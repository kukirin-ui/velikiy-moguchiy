"""Проверка меток клипов звуком: один постоянный процесс с GigaAM v3 RNNT, очередь-спул на диске, батчи.

Запускает fetch/run.py (один процесс на сборщик). Кроп-процессы для каждого принятого клипа кладут в спул
<spool>/<id>.npy (int16, 16 кГц моно) и затем <id>.req (JSON: pub, ref, meta); .req пишется последним.
Сервис забирает .req (rename -> .claimed.<pid>, так что два сервиса не берут один клип), распознаёт батчем,
считает label_cer (посимвольный CER между метками датасета и GigaAM после textnorm.normalize) и сам пишет
итоговый <pub>/<id>.json (атомарно, последним). Клипы не отбрасываются: только asr_text и label_cer в json.
Сбой распознавания клипа -> json без asr-полей. Завершение: EOF на stdin (родитель закрыл или умер) ->
дорабатывает очередь и выходит. Статистика (n, sec) - в <spool>/stats.json.

Бэкенды: PyTorch `gigaam` на CUDA (под) или gigaam_mlx (Mac); нет ни одного -> код выхода 3.
"""
from __future__ import annotations

import argparse, json, os, sys, threading, time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "newdata"))


def cer(ref: str, hyp: str) -> float:
    """Посимвольный CER по нормализованным текстам (знаменатель - длина метки датасета)."""
    from textnorm import edit_distance, normalize
    a, b = normalize(ref), normalize(hyp)
    if not a:
        return 0.0 if not b else 1.0
    return round(min(1.0, edit_distance(list(a), list(b)) / len(a)), 4)


def write_json(pub: str, cid: str, meta: dict, asr_text: str | None = None, ref: str = "") -> None:
    if asr_text is not None:
        meta = {**meta, "asr_text": asr_text, "label_cer": cer(ref, asr_text)}
    p = Path(pub)
    tmp = p / f"{cid}.json.tmp"
    tmp.write_text(json.dumps(meta, ensure_ascii=False))
    os.replace(tmp, p / f"{cid}.json")


class TorchASR:
    name = "torch-cuda"

    def __init__(self):
        import gigaam
        import torch
        if not torch.cuda.is_available():
            raise RuntimeError("нет CUDA")
        self.torch = torch
        self.m = gigaam.load_model("v3_rnnt", fp16_encoder=True, device="cuda")
        self.dev, self.dt = self.m._device, self.m._dtype

    def transcribe(self, arrs):
        torch = self.torch
        lens = [len(a) for a in arrs]
        buf = np.zeros((len(arrs), max(lens)), np.float32)
        for i, a in enumerate(arrs):
            buf[i, :len(a)] = a
        with torch.inference_mode():
            wav = torch.from_numpy(buf).to(self.dev).to(self.dt)
            ln = torch.tensor(lens, device=self.dev)
            enc, el = self.m.forward(wav, ln)
            out = self.m._decode(enc, el, ln, False)
        return [t for t, _ in out]


class MlxASR:
    name = "mlx"

    def __init__(self):
        import mlx.core as mx
        from gigaam_mlx import load_model
        from gigaam_mlx.audio import compute_mel
        self.mx, self.compute_mel = mx, compute_mel
        self.model, self.tok = load_model("rnnt")

    def transcribe(self, arrs):
        out = []
        for a in arrs:
            mel = self.compute_mel(a)
            enc, ln = self.model.encode(self.mx.array(mel[np.newaxis]))
            self.mx.eval(enc)
            out.append(self.tok.decode(self.model.decode(enc, ln)))
        return out


def load_backend():
    errs = []
    for cls in (TorchASR, MlxASR):
        try:
            return cls()
        except Exception as e:  # noqa
            errs.append(f"{cls.name}: {type(e).__name__}: {e}")
    print("нет бэкенда GigaAM: " + " | ".join(errs), file=sys.stderr, flush=True)
    sys.exit(3)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--spool", required=True)
    ap.add_argument("--batch", type=int, default=24)
    a = ap.parse_args()
    spool = Path(a.spool)
    spool.mkdir(parents=True, exist_ok=True)
    closing = threading.Event()

    def watch_stdin():
        sys.stdin.read()  # EOF: родитель закрыл канал или умер
        closing.set()
    threading.Thread(target=watch_stdin, daemon=True).start()

    be = load_backend()
    print(json.dumps({"ready": True, "backend": be.name}), flush=True)
    n_tot, sec_tot, batches = 0, 0.0, 0
    me = os.getpid()
    while True:
        reqs = sorted(spool.glob("*.req"), key=lambda p: p.stat().st_mtime if p.exists() else 0)
        if not reqs:
            if closing.is_set():
                break
            time.sleep(0.15)
            continue
        if len(reqs) < 8 and not closing.is_set() and time.time() - reqs[0].stat().st_mtime < 0.4:
            time.sleep(0.1)  # дать набраться батчу
            continue
        items = []
        for r in reqs[:a.batch]:
            c = r.with_name(f"{r.stem}.claimed.{me}")
            try:
                os.rename(r, c)
                items.append((r.stem, json.loads(c.read_text()), c))
            except Exception:
                continue
        t0 = time.time()
        texts, arrs, idx = {}, [], []
        for k, (cid, req, c) in enumerate(items):
            try:
                x = np.load(spool / f"{cid}.npy").astype(np.float32) / 32768.0
                if len(x) < 1600:
                    texts[k] = ""
                else:
                    arrs.append(x)
                    idx.append(k)
            except Exception as e:  # noqa
                print(f"asr: нет аудио {cid}: {e}", file=sys.stderr, flush=True)
        if arrs:
            order = sorted(range(len(arrs)), key=lambda i: len(arrs[i]))
            try:
                res = be.transcribe([arrs[i] for i in order])
                for i, t in zip(order, res):
                    texts[idx[i]] = t
            except Exception as e:  # noqa
                print(f"asr: сбой батча ({type(e).__name__}: {e}), по одному", file=sys.stderr, flush=True)
                try:
                    import torch
                    torch.cuda.empty_cache()
                except Exception:
                    pass
                for i in order:
                    try:
                        texts[idx[i]] = be.transcribe([arrs[i]])[0]
                    except Exception as e2:  # noqa
                        print(f"asr: клип {items[idx[i]][0]}: {type(e2).__name__}: {e2}", file=sys.stderr, flush=True)
        dt = time.time() - t0
        for k, (cid, req, c) in enumerate(items):
            try:
                write_json(req["pub"], cid, req["meta"], texts[k].strip() if k in texts else None, req.get("ref", ""))
            except Exception as e:  # noqa
                print(f"asr: не записан json {cid}: {type(e).__name__}: {e}", file=sys.stderr, flush=True)
            for f in (c, spool / f"{cid}.npy"):
                f.unlink(missing_ok=True)
        n_tot += len(items)
        sec_tot += dt
        batches += 1
        try:
            tmp = spool / f"stats.{me}.tmp"
            tmp.write_text(json.dumps({"pid": me, "n": n_tot, "sec": round(sec_tot, 3), "batches": batches}))
            os.replace(tmp, spool / "stats.json")
        except Exception:
            pass


if __name__ == "__main__":
    main()
