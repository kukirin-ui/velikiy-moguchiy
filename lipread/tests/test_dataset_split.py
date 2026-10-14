"""Разбиение train/dev детерминировано и по правильному ключу. Без GPU. Запуск: ./run.sh python tests/test_dataset_split.py"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from dataset import bucket, split_for, text_key  # noqa: E402

ph = [l.strip() for l in (ROOT / "phrases_train_ru.txt").read_text(encoding="utf8").splitlines() if l.strip() and not l.startswith("#")]
dev = sum(split_for(text_key(p), 15) == "dev" for p in ph)
print(f"dev из {len(ph)} фраз при 15%: {dev} ({dev / len(ph) * 100:.1f}%)")
assert 0.10 * len(ph) < dev < 0.20 * len(ph)
assert all(split_for(text_key(p), 15) == split_for(text_key(p), 15) for p in ph)
# регистр/пунктуация не меняют сторону (ключ = нормализованный текст)
assert split_for(text_key("Привет, мир!"), 15) == split_for(text_key("привет мир"), 15)
# public: все клипы одного ролика на одной стороне
vids = [f"vid{i:04d}" for i in range(2000)]
sp = {v: split_for("yt:" + v, 3) for v in vids}
assert sp == {v: split_for("yt:" + v, 3) for v in vids}
print(f"public dev роликов при 3%: {sum(s == 'dev' for s in sp.values())} из {len(vids)}")
print("split: ok")
