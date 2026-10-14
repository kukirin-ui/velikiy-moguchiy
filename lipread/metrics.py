"""WER / CER и нормализация русского текста (без внешних зависимостей).

normalize():  нижний регистр, ё -> е, вся пунктуация и символы вместо пробелов (остаются буквы,
              цифры и пробелы), схлопнутые пробелы. Это "строгая" нормализация: цифры и латиница
              остаются как есть.
normalize_loose(): то же + цифры -> слова (именительный падеж) и несколько типичных латинских
              названий -> кириллическое написание. Нужна, потому что MultiVSR обучен на разметке
              Whisper и может написать "гитхаб" там, где в эталоне "GitHub", или "15" вместо
              "пятнадцать". Применяется к обеим сторонам, это вспомогательная метрика.
"""
from __future__ import annotations

import re

# --------------------------------------------------------------------------------------------
# строгая нормализация


def normalize(text: str) -> str:
    t = text.lower().replace("ё", "е")
    t = re.sub(r"[^\w\s]|_", " ", t, flags=re.UNICODE)  # пунктуация и символы -> пробел
    return re.sub(r"\s+", " ", t).strip()


# --------------------------------------------------------------------------------------------
# мягкая нормализация: числа и названия

_ONES = ["ноль", "один", "два", "три", "четыре", "пять", "шесть", "семь", "восемь", "девять", "десять",
         "одиннадцать", "двенадцать", "тринадцать", "четырнадцать", "пятнадцать", "шестнадцать",
         "семнадцать", "восемнадцать", "девятнадцать"]
_TENS = ["", "", "двадцать", "тридцать", "сорок", "пятьдесят", "шестьдесят", "семьдесят", "восемьдесят",
         "девяносто"]
_HUND = ["", "сто", "двести", "триста", "четыреста", "пятьсот", "шестьсот", "семьсот", "восемьсот",
         "девятьсот"]


def _below_1000(n: int, fem: bool = False) -> list[str]:
    w = []
    if n >= 100:
        w.append(_HUND[n // 100])
        n %= 100
    if n >= 20:
        w.append(_TENS[n // 10])
        n %= 10
        if n:
            w.append(_ONES[n])
    elif n > 0:
        w.append(_ONES[n])
    if fem and w:
        if w[-1] == "один":
            w[-1] = "одна"
        elif w[-1] == "два":
            w[-1] = "две"
    return w


def number_to_words(n: int) -> str:
    """Целое 0..999 999 999 в именительном падеже."""
    if n == 0:
        return "ноль"
    parts: list[str] = []
    for div, forms, fem in ((1_000_000, ("миллион", "миллиона", "миллионов"), False),
                            (1_000, ("тысяча", "тысячи", "тысяч"), True)):
        q, n = divmod(n, div)
        if q:
            parts += _below_1000(q, fem)
            last2, last1 = q % 100, q % 10
            if 11 <= last2 <= 14 or last1 in (0, 5, 6, 7, 8, 9):
                parts.append(forms[2])
            elif last1 == 1:
                parts.append(forms[0])
            else:
                parts.append(forms[1])
    parts += _below_1000(n)
    return " ".join(parts)


_BRANDS = {
    "github": "гитхаб", "telegram": "телеграм", "slack": "слэк", "zoom": "зум", "jira": "джира",
    "whatsapp": "вотсап", "google": "гугл", "docker": "докер", "python": "пайтон", "excel": "эксель",
    "notion": "ношн", "figma": "фигма", "email": "имейл", "wifi": "вайфай", "pdf": "пдф", "api": "апи",
    "iphone": "айфон", "youtube": "ютуб", "gmail": "джимейл", "linkedin": "линкедин", "ok": "окей",
}


def normalize_loose(text: str) -> str:
    t = normalize(text)
    t = re.sub(r"(\d+)", lambda m: " " + (number_to_words(int(m.group(1))) if len(m.group(1)) <= 9
                                           else m.group(1)) + " ", t)
    words = [_BRANDS.get(w, w) for w in t.split()]
    return " ".join(words)


# --------------------------------------------------------------------------------------------
# расстояние Левенштейна


def edit_distance(a, b) -> int:
    """Классический Левенштейн по последовательностям (слов или символов), O(len(a)*len(b))."""
    if len(a) < len(b):
        a, b = b, a
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i]
        for j, y in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x != y)))
        prev = cur
    return prev[-1]


def wer_counts(ref: str, hyp: str) -> tuple[int, int]:
    """(ошибок, слов в эталоне). Вход уже нормализован."""
    r, h = ref.split(), hyp.split()
    return edit_distance(r, h), len(r)


def cer_counts(ref: str, hyp: str) -> tuple[int, int]:
    """(ошибок, символов в эталоне); пробелы считаются символами."""
    return edit_distance(ref, hyp), len(ref)


def corpus_rates(pairs, norm=normalize) -> tuple[float, float]:
    """Сводные WER и CER по корпусу (сумма ошибок / сумма длин эталонов), в долях от 1."""
    we = wn = ce = cn = 0
    for ref, hyp in pairs:
        r, h = norm(ref), norm(hyp)
        e, n = wer_counts(r, h)
        we, wn = we + e, wn + n
        e, n = cer_counts(r, h)
        ce, cn = ce + e, cn + n
    return (we / wn if wn else 0.0), (ce / cn if cn else 0.0)


if __name__ == "__main__":  # быстрые самопроверки: uv run python metrics.py
    assert normalize("Ёжик, в тумане!  Привет-мир.") == "ежик в тумане привет мир"
    assert edit_distance("kitten", "sitting") == 3
    assert wer_counts("а б в г", "а х в") == (2, 4)
    assert cer_counts("кот", "кит") == (1, 3)
    assert corpus_rates([("раз два", "раз два")]) == (0.0, 0.0)
    assert corpus_rates([("раз два", "")]) == (1.0, 1.0)
    assert number_to_words(15) == "пятнадцать"
    assert number_to_words(2024) == "две тысячи двадцать четыре"
    assert number_to_words(21000) == "двадцать одна тысяча"
    assert number_to_words(115) == "сто пятнадцать"
    assert normalize_loose("Отправь в GitHub 15 файлов") == "отправь в гитхаб пятнадцать файлов"
    print("metrics: ok")
