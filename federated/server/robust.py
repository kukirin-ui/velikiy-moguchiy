"""Робастная агрегация (numpy): клиппинг по норме, взвешенное среднее, взвешенное усечённое среднее, медиана.

Все функции работают по столбцам матрицы X (n клиентов x d координат), поэтому легко режутся на куски по d.
"""
from __future__ import annotations

import numpy as np


def clip_scale(norm: float, c: float) -> float:
    """Множитель, приводящий вектор с нормой `norm` к норме не больше c."""
    if not np.isfinite(norm):
        return 0.0
    return 1.0 if norm <= c else c / norm


def trim_count(n: int, trim_ratio: float) -> int:
    """Сколько клиентов отбрасывать с каждой стороны. Всегда остаётся хотя бы один."""
    k = int(np.floor(trim_ratio * n))
    return max(0, min(k, (n - 1) // 2))


def weighted_mean(X: np.ndarray, w: np.ndarray) -> np.ndarray:
    w = np.asarray(w, np.float64)
    return (w[:, None] * X).sum(0) / w.sum()


def weighted_trimmed_mean(X: np.ndarray, w: np.ndarray, k: int, with_trimmed_mask: bool = False):
    """По каждой координате: отсортировать клиентов по значению, отбросить k наименьших и k наибольших,
    остальных усреднить с весами w. Возвращает (среднее, число отброшенных координат на клиента или None)."""
    n = X.shape[0]
    if k == 0:
        trimmed = np.zeros(n, np.int64) if with_trimmed_mask else None
        return weighted_mean(X, w), trimmed
    order = np.argsort(X, axis=0, kind="stable")                     # (n, d)
    xs = np.take_along_axis(X, order, axis=0).astype(np.float64)
    ws = np.asarray(w, np.float64)[order]
    keep = slice(k, n - k)
    out = (xs[keep] * ws[keep]).sum(0) / ws[keep].sum(0)
    trimmed = None
    if with_trimmed_mask:
        trimmed = np.zeros(n, np.int64)
        for rank in list(range(k)) + list(range(n - k, n)):
            np.add.at(trimmed, order[rank], 1)
    return out, trimmed


def weighted_median(X: np.ndarray, w: np.ndarray) -> np.ndarray:
    """Взвешенная медиана по каждой координате (нижняя при равенстве половинных весов, усреднение с верхней)."""
    n, d = X.shape
    order = np.argsort(X, axis=0, kind="stable")
    xs = np.take_along_axis(X, order, axis=0).astype(np.float64)
    ws = np.asarray(w, np.float64)[order]
    cum = np.cumsum(ws, axis=0)
    half = cum[-1] / 2.0
    idx = (cum < half[None, :]).sum(0)                                # первый индекс, где cum >= half
    idx = np.minimum(idx, n - 1)
    cols = np.arange(d)
    lo = xs[idx, cols]
    exact = np.isclose(cum[idx, cols], half) & (idx < n - 1)          # ровно пополам: среднее с соседом
    hi = xs[np.minimum(idx + 1, n - 1), cols]
    return np.where(exact, (lo + hi) / 2.0, lo)
