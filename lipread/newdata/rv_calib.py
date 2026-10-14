"""Калибровка порогов SyncNet на известных образцах (work/cal: g_* хорошие, b_* плохие: озвучка/дубляж/закадровый голос).
Запуск на поде: venv/bin/python rv_calib.py cal/*.mkv  (нужен работающий gpu_server.py).
Для каждого образца: уверенность/сдвиг на всей пробе 30 с, на сегментах 4 с, и для той же картинки с подменой звука
(кольцевой сдвиг на 7-13 с) - нулевое распределение."""
import json
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import gpu_server as G  # noqa: E402
import vision as V  # noqa: E402


def crops_for(path):
    frames = V.decode_frames(path, None, 30, out_h=360)
    o = V.analyze_frames(frames)
    face = o["face"] > 0
    if face.mean() < 0.5:
        return None, None, face.mean()
    sxy = V.s3fd_like_track(o)
    arr = V.crop_clip(frames[..., ::-1].copy(), sxy)
    audio = V.decode_audio(path, None, 30)
    return arr, audio, face.mean()


def main():
    cl = G.Client()
    rows = []
    for p in sys.argv[1:]:
        p = Path(p)
        arr, audio, ff = crops_for(p)
        if arr is None:
            print(f"{p.name}: лицо в {ff:.2f} кадров, пропуск")
            continue
        n = len(arr)
        audio = audio[: int(n / 25 * 16000)]
        r = cl.sync(arr, G.mfcc_of(audio))
        nulls = []
        for sh in (7, 9, 11, 13):
            a2 = np.roll(audio, int(sh * 16000))
            nulls.append(cl.sync(arr, G.mfcc_of(a2)))
        seg = []
        for a in range(0, n - 100 + 1, 100):  # сегменты 4 с
            ra = cl.sync(arr[a:a + 100], G.mfcc_of(audio[a * 640:(a + 100) * 640]))
            rn = cl.sync(arr[a:a + 100], G.mfcc_of(np.roll(audio, 9 * 16000)[a * 640:(a + 100) * 640]))
            seg.append((ra["conf"], ra["offset"], rn["conf"], rn["offset"]))
        row = {"name": p.name, "face": round(float(ff), 2), "conf": round(r["conf"], 2), "offset": r["offset"],
               "null_conf": [round(x["conf"], 2) for x in nulls], "null_off": [x["offset"] for x in nulls],
               "seg": [[round(c, 2), o, round(nc, 2), no] for c, o, nc, no in seg]}
        rows.append(row)
        print(json.dumps(row, ensure_ascii=False), flush=True)
    Path(HERE / "calib_syncnet.json").write_text(json.dumps(rows, ensure_ascii=False))


if __name__ == "__main__":
    main()
