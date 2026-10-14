"""Сервер распознавания GigaAM v3 (RNNT, MLX). Запускать интерпретатором ~/.venvs/gigaam.
stdin: строки JSON {"id":..,"wav":путь} (16 кГц моно s16/f32 wav-файл) -> stdout: {"id":..,"text":..}.
Модель грузится один раз. Без аргументов читает stdin до EOF."""
import json
import sys

import numpy as np


def main():
    import mlx.core as mx
    from gigaam_mlx import load_model
    from gigaam_mlx.audio import compute_mel, load_audio
    model, tok = load_model("rnnt")
    print(json.dumps({"ready": True}), flush=True)
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        req = json.loads(line)
        try:
            a = load_audio(req["wav"])
            if len(a) < 1600:
                text = ""
            else:
                mel = compute_mel(a)
                enc, ln = model.encode(mx.array(mel[np.newaxis]))
                mx.eval(enc)
                text = tok.decode(model.decode(enc, ln))
            print(json.dumps({"id": req["id"], "text": text}, ensure_ascii=False), flush=True)
        except Exception as e:  # noqa
            print(json.dumps({"id": req["id"], "error": f"{type(e).__name__}: {e}"}, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
