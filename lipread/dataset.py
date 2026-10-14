"""Единый манифест данных и предрасчёт замороженных признаков VTP.

Источники (все пути можно переопределить флагами):
  clips/        50 беззвучных тестовых клипов            -> source=silent, split=test   (НИКОГДА не в обучении)
  data/silent/  новые беззвучные клипы (record.py)       -> source=silent, split=train|dev (85/15 по хэшу текста)
  data/voiced/  клипы приложения диктовки: NAME.mp4 + NAME.txt (распознанный текст) -> source=voiced, train|dev
  data/public/  готовые публичные признаки: NAME.npy (T,512 fp16/fp32) + NAME.txt [+ NAME.json {"video_id": ...}]
                -> source=public, train|dev (по хэшу YouTube-id ролика: один ролик целиком в одной части), не test

Выход:
  data/manifest.jsonl   строка на клип: id, video, text, source, split + hash, frames, feats, face
  work/faces_h/<hash>.avi      кроп лица 224x224 (preprocess.py, как у MultiVSR), кэш по хэшу видео
  work/features/<hash>.npy     признаки VTP (T,512) fp16, кэш по хэшу видео
  work/features/<hash>.skip.json   причина пропуска клипа (чтобы не повторять детекцию каждую ночь)
  work/dataset_skipped.jsonl   полный список пропущенных за этот запуск с причинами

Перезапуск безопасен: всё, что уже посчитано (по хэшу содержимого), берётся из кэша; файлы пишутся через
временное имя + rename, оборванный запуск ничего не портит. Видео без лица пропускаются с записью причины.
Защита от утечки теста: клип, чей хэш или нормализованный текст совпадает с тестовым, в train/dev не попадает.

Запуск: ./guarded.sh dataset.py            (после новых записей / новых файлов в data/)
"""
from __future__ import annotations

import memguard  # noqa: F401  (лимиты памяти MPS до import torch)

import argparse
import hashlib
import json
import multiprocessing as mp
import os
import re
import shutil
import sys
import time
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
from split import SPLIT_SALT, bucket, split_for  # noqa: E402,F401  (re-exported: train_e2e.py, tests)
FEAT_VERSION = "fp16;crop=mvsr-s3fd-v1;chunk=350"
CHUNK_FRAMES = 14 * 25  # как в инференсе MultiVSR


# --- хэши ----------------------------------------------------------------------------------------------
class HashCache:
    """sha1 содержимого файла; кэш по (путь, размер, mtime), чтобы не перечитывать тысячи файлов каждую ночь."""

    def __init__(self, path: Path):
        self.path = path
        self.d: dict = {}
        if path.exists():
            try:
                self.d = json.loads(path.read_text())
            except Exception:
                self.d = {}
        self.dirty = False

    def get(self, p: Path) -> str:
        st = p.stat()
        key = str(p.resolve())
        e = self.d.get(key)
        if e and e[0] == st.st_size and e[1] == st.st_mtime_ns:
            return e[2]
        h = hashlib.sha1()
        with open(p, "rb") as f:
            for blk in iter(lambda: f.read(1 << 20), b""):
                h.update(blk)
        self.d[key] = [st.st_size, st.st_mtime_ns, h.hexdigest()]
        self.dirty = True
        return h.hexdigest()

    def save(self):
        if self.dirty:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_suffix(".tmp")
            tmp.write_text(json.dumps(self.d))
            os.replace(tmp, self.path)
            self.dirty = False


def text_key(text: str) -> str:
    from metrics import normalize
    return normalize(text)


def read_text(p: Path) -> str:
    return " ".join(p.read_text(encoding="utf8").split()).strip()


# --- предобработка лица (в процессах-воркерах, только CPU) --------------------------------------------
def _prep_worker(job):
    h, src, dst, min_track = job
    try:
        os.nice(10)
    except Exception:
        pass
    import torch
    torch.set_num_threads(1)
    from preprocess import preprocess_video
    part = Path(dst).with_name(Path(dst).stem + ".part.avi")
    t0 = time.perf_counter()
    try:
        info = preprocess_video(src, part, min_track=min_track)
        os.replace(part, dst)
        return h, True, info, time.perf_counter() - t0
    except Exception as e:  # лицо не найдено, битое видео и т. п.
        Path(part).unlink(missing_ok=True)
        return h, False, str(e)[:300], time.perf_counter() - t0


# --- основная логика ---------------------------------------------------------------------------------
def scan_videos(folder: Path) -> list[Path]:
    if not folder.exists():
        return []
    return sorted(p for p in folder.glob("*.mp4") if not p.name.startswith(".") and p.with_suffix(".txt").exists())


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--clips-dir", default=str(ROOT / "clips"), help="тест (50 клипов)")
    ap.add_argument("--silent-dir", default=str(ROOT / "data" / "silent"))
    ap.add_argument("--voiced-dir", default=str(ROOT / "data" / "voiced"))
    ap.add_argument("--public-dir", default=str(ROOT / "data" / "public"))
    ap.add_argument("--manifest", default=str(ROOT / "data" / "manifest.jsonl"))
    ap.add_argument("--work-dir", default=str(ROOT / "work"))
    ap.add_argument("--device", default="auto", help="устройство для VTP: auto (mps/cpu) | mps | cpu")
    ap.add_argument("--workers", type=int, default=3, help="процессов предобработки лица (CPU, nice 10)")
    ap.add_argument("--dev-pct", type=int, default=15, help="доля dev для silent/voiced, %%")
    ap.add_argument("--public-dev-pct", type=int, default=3, help="доля dev для public (по YouTube-id ролика), %%")
    ap.add_argument("--min-track", type=int, default=10, help="минимум кадров в треке лица")
    ap.add_argument("--min-coverage", type=float, default=0.6,
                    help="доля кадров клипа в треке лица; меньше -> пропуск (не для теста)")
    ap.add_argument("--max-seconds", type=float, default=30.0, help="длиннее -> пропуск (silent/voiced)")
    ap.add_argument("--limit-new", type=int, default=0, help="обработать не больше N новых клипов за запуск (0 = все)")
    ap.add_argument("--delete-public-video", action="store_true",
                    help="после успешного расчёта признаков удалить data/public/*.mp4 (остаются только .npy/.txt/.json)")
    ap.add_argument("--no-features", action="store_true", help="только кроп лица и манифест, без VTP")
    ap.add_argument("--retry-skipped", action="store_true", help="повторить клипы, ранее пропущенные без лица")
    ap.add_argument("--rebuild-features", action="store_true", help="удалить кэш признаков при смене версии")
    ap.add_argument("--min-free", type=int, default=memguard.MIN_FREE_DEFAULT)
    a = ap.parse_args()

    work = Path(a.work_dir)
    faces_h, feats_dir = work / "faces_h", work / "features"
    for d in (faces_h, feats_dir):
        d.mkdir(parents=True, exist_ok=True)
    memguard.require_free(a.min_free, "старт dataset.py")

    # версия кэша признаков
    ver_file = feats_dir / "VERSION"
    venc_path = ROOT / "weights" / "feature_extractor.pth"
    ver = FEAT_VERSION + f";vtp_bytes={venc_path.stat().st_size if venc_path.exists() else 'none'}"
    if ver_file.exists() and ver_file.read_text().strip() != ver:
        if not a.rebuild_features:
            sys.exit(f"Кэш признаков {feats_dir} другой версии ({ver_file.read_text().strip()} != {ver}). "
                     f"Запустите с --rebuild-features")
        for f in feats_dir.glob("*.npy"):
            f.unlink()
    ver_file.write_text(ver + "\n")

    hc = HashCache(work / "hash_cache.json")
    skipped: list[dict] = []

    def skip(row_id, reason, path=None):
        skipped.append(dict(id=row_id, reason=reason, path=str(path) if path else None))
        print(f"  пропуск {row_id}: {reason}")

    # 1. кандидаты -------------------------------------------------------------------------------------
    test_texts, cands = set(), []
    test_hashes: dict[str, str] = {}
    for p in scan_videos(Path(a.clips_dir)):
        h = hc.get(p)
        test_hashes[h] = p.stem
        t = read_text(p.with_suffix(".txt"))
        test_texts.add(text_key(t))
        cands.append(dict(id=f"test/{p.stem}", video=p, text=t, source="silent", split="test", hash=h,
                          legacy_face=work / "faces" / f"{p.stem}.avi"))
    if not cands:
        print(f"ВНИМАНИЕ: в {a.clips_dir} нет тестовых клипов")

    seen_hash = dict(test_hashes)
    for source, folder in (("silent", Path(a.silent_dir)), ("voiced", Path(a.voiced_dir))):
        for p in scan_videos(folder):
            rid = f"{source}/{p.stem}"
            t = read_text(p.with_suffix(".txt"))
            if not t:
                skip(rid, "пустой текст", p)
                continue
            h = hc.get(p)
            if h in test_hashes:
                skip(rid, f"хэш видео совпадает с тестовым клипом {test_hashes[h]}: в обучение нельзя", p)
                continue
            if text_key(t) in test_texts:
                skip(rid, "нормализованный текст совпадает с тестовой фразой", p)
                continue
            if h in seen_hash:
                skip(rid, f"дубль видео ({seen_hash[h]})", p)
                continue
            seen_hash[h] = rid
            cands.append(dict(id=rid, video=p, text=t, source=source,
                              split=split_for(text_key(t), a.dev_pct), hash=h))

    # 2. предобработка лица ------------------------------------------------------------------------------
    todo = []
    for c in cands:
        h = c["hash"]
        face = faces_h / f"{h}.avi"
        c["face"] = face
        skipf = feats_dir / f"{h}.skip.json"
        if c["source"] == "silent" and c["split"] == "test" and not face.exists() and c["legacy_face"].exists():
            shutil.copyfile(c["legacy_face"], face)  # тот же препроцессинг, уже посчитан для evaluate.py
        if face.exists():
            continue
        if skipf.exists() and not a.retry_skipped:
            continue
        todo.append(c)
    if a.limit_new:
        todo = todo[:a.limit_new]
    if todo:
        print(f"Предобработка лица: {len(todo)} клипов, процессов {a.workers}")
        ctx = mp.get_context("spawn")
        jobs = [(c["hash"], str(c["video"]), str(c["face"]), a.min_track) for c in todo]
        by_hash = {c["hash"]: c for c in todo}
        t0 = time.perf_counter()
        with ctx.Pool(max(1, a.workers)) as pool:
            for k, (h, ok, info, sec) in enumerate(pool.imap_unordered(_prep_worker, jobs), 1):
                c = by_hash[h]
                if ok:
                    print(f"  [{k}/{len(jobs)}] {c['id']}: ok, кадров в треке {info['track_frames']}/{info['frames']} ({sec:.1f} с)")
                else:
                    (feats_dir / f"{h}.skip.json").write_text(json.dumps(dict(id=c["id"], reason="нет лица: " + info)))
                    print(f"  [{k}/{len(jobs)}] {c['id']}: НЕТ ЛИЦА ({info})")
        print(f"  предобработка заняла {time.perf_counter() - t0:.0f} с")
        memguard.require_free(a.min_free, "после предобработки лица")

    # 3. признаки VTP ------------------------------------------------------------------------------------
    need = [dict(c, out=feats_dir / f"{c['hash']}.npy") for c in cands
            if c["face"].exists() and not (feats_dir / f"{c['hash']}.npy").exists()]
    # публичные клипы от фетчера в виде уже обрезанного лица (data/public/NAME.mp4 224x224 + .txt + .json): S3FD не нужен,
    # только признаки VTP -> data/public/NAME.npy
    pub_dir0 = Path(a.public_dir)
    if pub_dir0.exists():
        for mp4 in sorted(pub_dir0.glob("*.mp4")):
            if mp4.name.startswith(".") or not mp4.with_suffix(".txt").exists() or mp4.with_suffix(".npy").exists():
                continue
            if not mp4.with_suffix(".json").exists():
                continue  # фетчер пишет .json последним: клип ещё не готов
            need.append(dict(id=f"public/{mp4.stem}", face=mp4, out=mp4.with_suffix(".npy"), hash=mp4.stem,
                             public_video=True))
    if a.limit_new:
        need = need[:a.limit_new]
    if need and not a.no_features:
        import numpy as np
        import torch
        import mvsr
        device = mvsr.pick_device(a.device)
        print(f"Признаки VTP: {len(need)} клипов, устройство {device}")
        venc = mvsr.load_venc(device)
        t0, peak = time.perf_counter(), 0.0
        for k, c in enumerate(need, 1):
            f = memguard.free_pct()
            if f < a.min_free:
                print(f"СТОП: свободной памяти {f}% < {a.min_free}%; прогресс сохранён, перезапустите позже")
                break
            faces = mvsr.read_faces(c["face"])
            outs = []
            with torch.no_grad():
                for i in range(0, faces.size(2), CHUNK_FRAMES):
                    outs.append(venc(faces[:, :, i:i + CHUNK_FRAMES].to(device))[0].float().cpu())
            feats = torch.cat(outs, 0).numpy().astype(np.float16)
            assert feats.ndim == 2 and feats.shape[1] == 512 and feats.shape[0] == faces.size(2), feats.shape
            tmp = c["out"].with_name(c["out"].stem + ".tmp.npy")
            np.save(tmp, feats)
            os.replace(tmp, c["out"])
            if c.get("public_video") and a.delete_public_video:
                Path(c["face"]).unlink(missing_ok=True)
            del faces, outs
            memguard.mps_cleanup()
            if device == "mps":
                peak = max(peak, torch.mps.driver_allocated_memory() / 2**30)
            if k % 10 == 0 or k == len(need):
                print(f"  [{k}/{len(need)}] {c['id']}: {feats.shape[0]} кадров, {time.perf_counter() - t0:.0f} с, "
                      f"драйвер MPS пик {peak:.2f} ГБ, свободно {f}%")
        del venc
        memguard.mps_cleanup()

    # 4. строки манифеста --------------------------------------------------------------------------------
    rows = []
    import numpy as np
    for c in cands:
        h = c["hash"]
        fe = feats_dir / f"{h}.npy"
        if not c["face"].exists():
            sk = feats_dir / f"{h}.skip.json"
            skip(c["id"], json.loads(sk.read_text())["reason"] if sk.exists() else "предобработка не выполнена (--limit-new?)")
            continue
        if not fe.exists():
            if not a.no_features:
                skip(c["id"], "признаки не посчитаны")
            continue
        frames = int(np.load(fe, mmap_mode="r").shape[0])
        sec = frames / 25
        if c["split"] != "test":
            if sec > a.max_seconds:
                skip(c["id"], f"длина {sec:.1f} с > {a.max_seconds} с")
                continue
        rows.append(dict(id=c["id"], video=str(c["video"]), text=c["text"], source=c["source"], split=c["split"],
                         hash=h, frames=frames, feats=str(fe), face=str(c["face"])))

    # 5. публичные признаки (без видео; только признаки + текст) -------------------------------------------
    pub_dir = Path(a.public_dir)
    n_pub_seen = 0
    if pub_dir.exists():
        for npy in sorted(pub_dir.glob("*.npy")):
            n_pub_seen += 1
            rid = f"public/{npy.stem}"
            txt = npy.with_suffix(".txt")
            if not txt.exists():
                skip(rid, "нет .txt", npy)
                continue
            t = read_text(txt)
            if not t:
                skip(rid, "пустой текст", npy)
                continue
            try:
                arr = np.load(npy, mmap_mode="r")
                if arr.ndim != 2 or arr.shape[1] != 512 or arr.dtype not in (np.float16, np.float32) or arr.shape[0] < 10:
                    raise ValueError(f"форма/тип {arr.shape} {arr.dtype}, нужно (T>=10, 512) float16/32")
            except Exception as e:
                skip(rid, f"плохой .npy: {e}", npy)
                continue
            vid = None
            js = npy.with_suffix(".json")
            if js.exists():
                try:
                    vid = str(json.loads(js.read_text()).get("video_id") or "") or None
                except Exception:
                    vid = None
            if vid is None:
                vid = npy.stem.rsplit("__", 1)[0] if "__" in npy.stem else npy.stem
            h = hc.get(npy)
            if h in seen_hash:
                skip(rid, f"дубль ({seen_hash[h]})", npy)
                continue
            if text_key(t) in test_texts:
                skip(rid, "нормализованный текст совпадает с тестовой фразой", npy)
                continue
            seen_hash[h] = rid
            rows.append(dict(id=rid, video=None, text=t, source="public", split=split_for("yt:" + vid, a.public_dev_pct),
                             hash=h, frames=int(arr.shape[0]), feats=str(npy.resolve()), face=None, video_id=vid))

    hc.save()

    # 6. запись манифеста + проверка утечки ---------------------------------------------------------------
    leaks = [r["id"] for r in rows if r["split"] != "test" and r["hash"] in test_hashes]
    assert not leaks, f"УТЕЧКА ТЕСТА в манифесте: {leaks}"
    rows.sort(key=lambda r: (r["source"], r["split"], r["id"]))
    mpath = Path(a.manifest)
    mpath.parent.mkdir(parents=True, exist_ok=True)
    tmp = mpath.with_suffix(".tmp")
    with tmp.open("w", encoding="utf8") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    os.replace(tmp, mpath)
    (work / "dataset_skipped.jsonl").write_text("".join(json.dumps(s, ensure_ascii=False) + "\n" for s in skipped),
                                               encoding="utf8")

    cnt, hrs = Counter(), defaultdict(float)
    for r in rows:
        cnt[(r["source"], r["split"])] += 1
        hrs[(r["source"], r["split"])] += r["frames"] / 25 / 3600
    print(f"\nМанифест: {mpath}  ({len(rows)} клипов, пропущено {len(skipped)}, см. work/dataset_skipped.jsonl)")
    print(f"{'source':8s} {'split':6s} {'клипов':>8s} {'часов':>8s}")
    for k in sorted(cnt):
        print(f"{k[0]:8s} {k[1]:6s} {cnt[k]:8d} {hrs[k]:8.2f}")
    reasons = Counter(re.sub(r"\d+", "N", s["reason"])[:60] for s in skipped)
    for r_, n in reasons.most_common(8):
        print(f"  пропущено {n}: {r_}")


if __name__ == "__main__":
    main()
