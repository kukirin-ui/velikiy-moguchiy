"""Нормализация русского текста и WER (без внешних зависимостей)."""
from __future__ import annotations

import re

TAG_RE = re.compile(r"[\[\(\{][^\]\)\}]{0,60}[\]\)\}]")
NOISE_TAG_RE = re.compile(
    r"[\[\(♪♫]\s*(музык|аплодисмент|смех|шум|песн|пение|звук|овации|тишина|music|applause|laughter|noise|singing|"
    r"inaudible|неразборчиво|кашель|вздох|звонок|гудок|выстрел|—?\s*музыка)", re.I)
NOTE_RE = re.compile(r"[♪♫♬]")


def has_noise_tag(text: str) -> bool:
    return bool(NOISE_TAG_RE.search(text) or NOTE_RE.search(text))


def normalize(text: str) -> str:
    """нижний регистр, без пунктуации и тегов, ё->е, числа остаются как есть."""
    t = TAG_RE.sub(" ", text.lower())
    t = t.replace("ё", "е")
    t = re.sub(r"[^0-9a-zа-я\s]", " ", t)
    return re.sub(r"\s+", " ", t).strip()


def words(text: str) -> list[str]:
    n = normalize(text)
    return n.split() if n else []


def edit_distance(a: list[str], b: list[str]) -> int:
    if not a:
        return len(b)
    if not b:
        return len(a)
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i] + [0] * len(b)
        for j, y in enumerate(b, 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x != y))
        prev = cur
    return prev[-1]


def wer(ref: list[str], hyp: list[str]) -> float:
    if not ref:
        return 0.0 if not hyp else 1.0
    return edit_distance(ref, hyp) / len(ref)


def wer_substring(ctx: list[str], hyp: list[str]) -> float:
    """WER гипотезы относительно лучшей подстроки контекста субтитров (края контекста не штрафуются).

    ctx - слова субтитров с запасом по краям; hyp - слова распознавания. Полуглобальное выравнивание:
    свободный пропуск слов контекста в начале и в конце. Знаменатель - длина гипотезы.
    """
    if not hyp:
        return 1.0 if ctx else 0.0
    n, m = len(ctx), len(hyp)
    # D[i][j]: стоимость выравнивания hyp[:j] с окончанием в ctx[:i]; D[i][0]=0 (свободный старт)
    prev = [j for j in range(m + 1)]  # i=0: удалить j слов гипотезы
    best = prev[m]
    for i in range(1, n + 1):
        cur = [0] * (m + 1)
        for j in range(1, m + 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ctx[i - 1] != hyp[j - 1]))
        best = min(best, cur[m])
        prev = cur
    return best / m
