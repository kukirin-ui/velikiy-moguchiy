"""Признаки скрытого экзамена из исходных клипов (запускается в задании оценки, в окружении с torch, без секретов):

  python exam_features.py --raw DIR --venc VENC.pth --lipread ../lipread --out EXAM_DIR [--limit 120]

DIR — копия raw/ закрытого датасета экзамена: exam_raw.jsonl ({"id", "file", "text", "speaker", "raw"} на строку) и
сами клипы. Только публичные клипы (MuAViC-ru); записей автора проекта в экзамене нет. Клип с "raw": false — уже
кроп лица 224x224 (так нарезан MuAViC-ru) и идёт прямо в визуальную часть; исходное видео ("raw": true или поля нет)
сначала режется по лицу, как у участников (lipread/preprocess.py, детектор на каждом 5-м кадре). Признаки —
визуальной частью lips-0.1 (VENC, загрузка только weights_only=True). Выбор клипов поровну по говорящим, всегда
один и тот же. Пишет exam.jsonl и feats/ в формате aggregator/exam.py; в журнал попадают только числа и причины
отказа без текстов.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
from collections import defaultdict
from pathlib import Path

CHUNK_FRAMES = 14 * 25
DET_EVERY = 5


def balanced(rows: list[dict], limit: int) -> list[dict]:
    by: dict[str, list[dict]] = defaultdict(list)
    for r in sorted(rows, key=lambda r: r["id"]):
        by[r.get("speaker", "")].append(r)
    out, i = [], 0
    while len(out) < limit and any(i < len(v) for v in by.values()):
        for sp in sorted(by):
            if i < len(by[sp]) and len(out) < limit:
                out.append(by[sp][i])
        i += 1
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", required=True)
    ap.add_argument("--venc", required=True)
    ap.add_argument("--lipread", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--limit", type=int, default=120)
    a = ap.parse_args()

    sys.path.insert(0, str(Path(a.lipread).resolve()))
    import numpy as np
    import torch

    import mvsr
    from preprocess import preprocess_video

    torch.set_num_threads(os.cpu_count() or 2)
    raw = Path(a.raw)
    rows = [json.loads(ln) for ln in (raw / "exam_raw.jsonl").read_text(encoding="utf8").splitlines() if ln.strip()]
    rows = balanced(rows, a.limit)

    m = mvsr._multivsr()
    m["models"].set_amp("cpu", False)
    venc = m["models"].build_visual_encoder()
    sd = torch.load(a.venc, map_location="cpu", weights_only=True)["state_dict"]
    venc.load_state_dict({k.replace("module.face_encoder.", ""): v for k, v in sd.items() if "face_encoder" in k})
    venc.eval()

    out = Path(a.out)
    (out / "feats").mkdir(parents=True, exist_ok=True)
    lines, skipped, reasons = [], 0, []
    with tempfile.TemporaryDirectory() as td:
        for k, r in enumerate(rows, 1):
            face = raw / r["file"]
            if r.get("raw", True):
                face = Path(td) / f"{k}.avi"
                try:
                    preprocess_video(str(raw / r["file"]), str(face), det_every=DET_EVERY)
                except Exception as e:  # noqa: BLE001  (no face found: the clip is left out)
                    skipped += 1
                    if len(reasons) < 3:
                        reasons.append(f"{type(e).__name__}: {str(e)[:160]}")
                    continue
            faces = mvsr.read_faces(face)
            with torch.inference_mode():
                parts = [venc(faces[:, :, i:i + CHUNK_FRAMES])[0].float() for i in range(0, faces.size(2), CHUNK_FRAMES)]
            feats = torch.cat(parts, 0).numpy().astype(np.float16)
            np.save(out / "feats" / f"{r['id']}.npy", feats)
            lines.append(json.dumps({"id": r["id"], "text": r["text"], "feats": f"feats/{r['id']}.npy"}, ensure_ascii=False))
            if r.get("raw", True):
                face.unlink(missing_ok=True)
            if k % 20 == 0:
                print(f"признаки: {k}/{len(rows)}", flush=True)
    (out / "exam.jsonl").write_text("\n".join(lines) + "\n", encoding="utf8")
    print(f"экзамен: {len(lines)} клипов, без лица {skipped}", flush=True)
    for why in reasons:
        print(f"  причина: {why}", flush=True)
    return 0 if lines else 1


if __name__ == "__main__":
    sys.exit(main())
