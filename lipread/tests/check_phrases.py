"""Проверка phrases_train_ru.txt: 5-12 слов, без дублей, без пересечения с тестовыми phrases_ru.txt
(совпадение нормализованных предложений и общих 4-грамм слов).
Запуск: uv run python tests/check_phrases.py [файл]   (по умолчанию phrases_train_ru.txt; код возврата 1 при нарушениях)"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from metrics import normalize  # noqa: E402


def load(p):
    return [l.strip() for l in Path(p).read_text(encoding="utf8").splitlines() if l.strip() and not l.startswith("#")]


def grams(words, n=4):
    return {tuple(words[i:i + n]) for i in range(len(words) - n + 1)}


def check(path, test_path=ROOT / "phrases_ru.txt", verbose=True):
    train, test = load(path), load(test_path)
    test_norm = {normalize(t) for t in test}
    test_grams = set().union(*(grams(normalize(t).split()) for t in test))
    bad, seen = [], set()
    for ph in train:
        n = normalize(ph)
        w = n.split()
        if not 5 <= len(ph.split()) <= 12:
            bad.append((ph, f"{len(ph.split())} слов"))
        elif n in test_norm:
            bad.append((ph, "совпадает с тестовой фразой"))
        elif grams(w) & test_grams:
            bad.append((ph, f"общая 4-грамма с тестом: {sorted(grams(w) & test_grams)[0]}"))
        elif n in seen:
            bad.append((ph, "дубль"))
        seen.add(n)
    if verbose:
        print(f"{path}: {len(train)} фраз, нарушений {len(bad)}")
        for ph, why in bad:
            print(f"  {why}: {ph}")
    return train, bad


if __name__ == "__main__":
    p = sys.argv[1] if len(sys.argv) > 1 else ROOT / "phrases_train_ru.txt"
    train, bad = check(p)
    sys.exit(1 if bad else 0)
