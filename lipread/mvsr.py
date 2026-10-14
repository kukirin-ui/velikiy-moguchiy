"""Тонкая обёртка над кодом MultiVSR (multivsr/): загрузка моделей и распознавание одного клипа.

Повторяет логику multivsr/inference.py (чанки по 14 с, луч 20, язык задаётся первым токеном),
но без глобального разбора argv и с замером времени. Устройство: cuda -> mps -> cpu.
"""
from __future__ import annotations

import os
import sys
import time
from pathlib import Path

# Лимиты памяти MPS (watermark 0.35/0.25) и fallback на CPU: всё это должно быть задано до import torch.
import memguard  # noqa: F401, E402
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

import numpy as np  # noqa: E402
import torch  # noqa: E402

ROOT = Path(__file__).resolve().parent
REPO = ROOT / "multivsr"
WEIGHTS = ROOT / "weights"
DEFAULT_CKPT = WEIGHTS / "model.pth"
DEFAULT_VENC = WEIGHTS / "feature_extractor.pth"

_mv = None


def _multivsr():
    """Импорт модулей MultiVSR. Их dataloader.py на импорте вызывает argparse -> прячем наш argv."""
    global _mv
    if _mv is not None:
        return _mv
    if not (REPO / "models.py").exists():
        raise SystemExit("Нет папки multivsr/. Запустите ./setup.sh")
    sys.path.insert(0, str(REPO))
    saved = sys.argv
    sys.argv = [saved[0]]
    try:
        import models  # type: ignore
        import search  # type: ignore
        from dataloader import tokenizer  # type: ignore
        import video_io  # type: ignore
    finally:
        sys.argv = saved
    _mv = dict(models=models, search=search, tokenizer=tokenizer, video_io=video_io)
    return _mv


def pick_device(name: str | None = None) -> str:
    if name and name != "auto":
        return name
    if torch.cuda.is_available():
        return "cuda"
    if torch.backends.mps.is_available():
        return "mps"
    return "cpu"


def _load_ckpt(path, device, authors_model=False):
    # mmap: model.pth from the authors also carries 2.3 GB of optimizer state, which is then never read into RAM.
    # Only tensors: a pickled object in a downloaded checkpoint could run code. The one exception is the
    # authors' model.pth, whose SHA-256 the download pins (download_weights.sh, the Mac app).
    if not authors_model:
        return torch.load(path, map_location=device, weights_only=True, mmap=True)
    try:
        return torch.load(path, map_location=device, weights_only=True, mmap=True)
    except Exception as e:  # чекпойнт с не-тензорными объектами
        print(f"[mvsr] weights_only=True не сработал для {path} ({type(e).__name__}); "
              f"пробую weights_only=False (файл от авторов MultiVSR)", file=sys.stderr)
        return torch.load(path, map_location=device, weights_only=False, mmap=True)


def sync(device: str):
    if device == "mps":
        torch.mps.synchronize()
    elif device == "cuda":
        torch.cuda.synchronize()


def read_faces(path, start=0.0, end=None) -> torch.Tensor:
    """Как multivsr/inference.py:read_video. -> (1, 3, T, 96, 96), 0..1, RGB, без нормализации."""
    video_io = _multivsr()["video_io"]
    s = max(int(start * 25) - 4, 0)
    frames = video_io.read_rgb_frames(str(path), 160, 160)
    e = len(frames) if end is None else min(int(end * 25) + 4, len(frames))
    frames = torch.from_numpy(frames[s:e].astype(np.float32) / 255.0)
    frames = frames.unsqueeze(0).permute(0, 4, 1, 2, 3)  # B C T H W
    cx = (frames.size(3) - 96) // 2
    cy = (frames.size(4) - 96) // 2
    return frames[:, :, :, cx:cx + 96, cy:cy + 96].contiguous()


def load_venc(device, venc_ckpt=DEFAULT_VENC):
    """Только замороженный извлекатель признаков VTP (13 млн параметров), без трансформера."""
    mv = _multivsr()
    mv["models"].set_amp(device, False)
    venc = mv["models"].build_visual_encoder()
    sd = _load_ckpt(venc_ckpt, "cpu")["state_dict"]
    venc.load_state_dict({k.replace("module.face_encoder.", ""): v for k, v in sd.items() if "face_encoder" in k})
    del sd
    return venc.to(device).eval()


class MultiVSR:
    def __init__(self, device="auto", ckpt=DEFAULT_CKPT, venc_ckpt=DEFAULT_VENC, fp16=None,
                 beam_size=20, max_decode_len=100, chunk_size=14, random_weights=False, lora=None,
                 venc_max_frames=None, last_logits_only=False):
        mv = _multivsr()
        self.device = pick_device(device)
        self.fp16 = (self.device == "cuda") if fp16 is None else fp16
        self.beam_size, self.max_decode_len, self.chunk_size = beam_size, max_decode_len, chunk_size
        self.venc_max_frames = venc_max_frames
        self.models = mv["models"]
        self.tok = mv["tokenizer"]
        self.search = mv["search"]
        self.video_io = mv["video_io"]
        mv["models"].set_amp(self.device, self.fp16)

        self.model = mv["models"].build_model()
        self.venc = mv["models"].build_visual_encoder()
        if not random_weights:
            for p in (ckpt, venc_ckpt):
                if not Path(p).exists():
                    raise SystemExit(f"Нет файла весов {p}. См. README (раздел про скачивание весов).")
            authors_model = Path(ckpt).resolve() == DEFAULT_CKPT.resolve()
            sd = _load_ckpt(ckpt, "cpu", authors_model=authors_model)["state_dict"]
            self.model.load_state_dict({(k[7:] if k.startswith("module.") else k): v for k, v in sd.items()})
            del sd
            sd = _load_ckpt(venc_ckpt, "cpu")["state_dict"]
            self.venc.load_state_dict({k.replace("module.face_encoder.", ""): v
                                       for k, v in sd.items() if "face_encoder" in k})
        self.lora_info = None
        if lora is not None:  # адаптеры LoRA из train.py сливаются в базовые веса (инференс как у обычной модели)
            import lora as _lora
            ck = _load_ckpt(lora, "cpu")
            n = _lora.merge_lora_into_base(self.model, ck)
            self.lora_info = dict(path=str(lora), merged=n, config=ck.get("config", {}), step=ck.get("step"))
        self.model = self.model.to(self.device).eval()
        self.venc = self.venc.to(self.device).eval()
        if last_logits_only:
            # search.beam_search keeps only logits[:, -1] of a full projection onto the 52k vocabulary for every
            # position at every step (gigabytes for 20 beams on long phrases); the last position alone is the same.
            model = self.model

            def decode_last(memory, src_mask, tgt, tgt_mask):
                return model.generator(model.decoder(model.tgt_embed(tgt), memory, src_mask, tgt_mask)[:, -1:])
            model.decode = decode_last

    def encode_visual(self, faces: torch.Tensor) -> torch.Tensor:
        """self.venc(faces) for one clip. With venc_max_frames the per-frame VTP transformer sees at most that many
        frames at a time: its activations grow with the clip (an 8 s clip took over 4 GB on MPS). Frames are
        independent after the 3D CNN, so the features are the same as in VTP_wrapper.forward."""
        if not self.venc_max_frames or faces.size(0) != 1 or faces.size(2) <= self.venc_max_frames:
            return self.venc(faces)
        venc, step = self.venc, self.venc_max_frames

        @self.models.amp
        def run():
            frames = venc.feat_extrator(faces).transpose(1, 2)[0]  # (T, C, H, W)
            pooled = []
            for i in range(0, frames.size(0), step):
                emb = venc.encoder(venc.hwposition(frames[i:i + step]))
                pooled.append((emb * torch.softmax(venc.pooler(emb), dim=1)).sum(1))
            return torch.cat(pooled).unsqueeze(0)  # (1, T, C)
        return run()

    # --- вход: avi/mp4 с готовым кропом лица (выход preprocess.py) ----------------------------
    def load_faces(self, path, start=0.0, end=None) -> torch.Tensor:
        """Как multivsr/inference.py:read_video. -> (1, 3, T, 96, 96), 0..1, RGB, без нормализации."""
        return read_faces(path, start, end)

    @torch.no_grad()
    def transcribe_faces(self, faces: torch.Tensor, lang_id: str | None = "ru") -> tuple[str, str]:
        chunk_frames = self.chunk_size * 25
        preds, lang = [], lang_id
        for i in range(0, faces.size(2), chunk_frames):
            x = faces[:, :, i:i + chunk_frames].to(self.device)
            feats = self.encode_visual(x)
            src_mask = torch.ones(1, 1, feats.shape[1]).long().to(self.device)
            enc, src_mask = self.model.encode(feats, src_mask)
            start = [50258]
            if lang_id is not None:
                start.append(self.tok.encode(f"<|{lang_id}|>")[0])
            with torch.autocast(self.device, enabled=self.fp16 and self.device in ("cuda", "mps")):
                outs, _ = self.search.beam_search(
                    model=self.model, bos_index=start, eos_index=self.tok.eot,
                    max_output_length=self.max_decode_len, pad_index=0,
                    encoder_output=enc, src_mask=src_mask,
                    size=self.beam_size, n_best=self.beam_size)
            if not outs[0]:  # луч не дошёл ни до одной гипотезы
                preds.append("")
                continue
            out = outs[0][0]
            pred = self.tok.decode(out.cpu().numpy().tolist()[:-1]).strip().lower()
            pred = pred.replace("<|transcribe|><|notimestamps|>", " ")
            if i == 0:
                lang = pred[2:4]
            preds.append(pred[7:].strip())
        return " ".join(preds).strip(), lang or ""

    @torch.no_grad()
    def nbest_faces(self, faces: torch.Tensor, lang_id: str | None = "ru") -> list[dict]:
        """n-best первого 14-секундного куска (клипы пользователя короче). Шаг 0 плана: возвращает все
        завершённые гипотезы луча, а не только лучшую. -> [{text, score, logp, ntok}] по убыванию score.
        score = оценка луча как есть (logP / ((5+n)/6), штраф длины alpha=1), logp = восстановленный logP,
        ntok = число сгенерированных токенов с EOS. Дубли текста схлопнуты (остаётся лучший score)."""
        x = faces[:, :, :self.chunk_size * 25].to(self.device)
        feats = self.encode_visual(x)
        src_mask = torch.ones(1, 1, feats.shape[1]).long().to(self.device)
        enc, src_mask = self.model.encode(feats, src_mask)
        start = [50258]
        if lang_id is not None:
            start.append(self.tok.encode(f"<|{lang_id}|>")[0])
        with torch.autocast(self.device, enabled=self.fp16 and self.device in ("cuda", "mps")):
            outs, scores = self.search.beam_search(
                model=self.model, bos_index=start, eos_index=self.tok.eot,
                max_output_length=self.max_decode_len, pad_index=0,
                encoder_output=enc, src_mask=src_mask,
                size=self.beam_size, n_best=self.beam_size)
        res, seen = [], set()
        for out, sc in zip(outs[0], scores[0]):
            pred = self.tok.decode(out.cpu().numpy().tolist()[:-1]).strip().lower()
            pred = pred.replace("<|transcribe|><|notimestamps|>", " ")
            text = pred[7:].strip()  # как в transcribe_faces: срезается "<|ru|> "
            if text in seen:
                continue
            seen.add(text)
            ntok = len(out) - 1
            res.append(dict(text=text, score=float(sc), logp=float(sc) * (5.0 + ntok) / 6.0, ntok=int(ntok)))
        return res

    def transcribe(self, path, lang_id="ru") -> tuple[str, float]:
        """-> (текст, секунды инференса: загрузка кадров + энкодер + луч)."""
        t0 = time.perf_counter()
        faces = self.load_faces(path)
        text, _ = self.transcribe_faces(faces, lang_id)
        sync(self.device)
        return text, time.perf_counter() - t0
