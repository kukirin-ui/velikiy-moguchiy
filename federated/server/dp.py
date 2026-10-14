"""Центральный дифференциальный приватность (необязательная, по умолчанию выключена).

Механизм: к агрегированной дельте добавляется гауссов шум sigma = z * S на каждую координату, где
S = C * w_max / W (чувствительность взвешенного среднего к одному клиенту при норме обновления <= C).
Учёт: RDP гауссова механизма, alpha/(2 z^2) за раунд, суммируется по раундам; перевод в (eps, delta):
eps = min_alpha [alpha*S_sum/2 + ln(1/delta)/(alpha-1)] = S_sum/2 + sqrt(2 S_sum ln(1/delta)),  S_sum = sum 1/z_r^2.
Это консервативно: предполагается, что один и тот же клиент участвует во ВСЕХ раундах, усиления от подвыборки нет.

Оговорка: формальная гарантия верна для aggregation.method="mean" с ФИКСИРОВАННЫМ C. Для усечённого среднего и медианы
чувствительность другая, и ε ниже это номинальная оценка по тому же шуму, а не доказанная гарантия.
"""
from __future__ import annotations

import math

import numpy as np


def sensitivity(clip_norm: float, weights: np.ndarray) -> float:
    w = np.asarray(weights, np.float64)
    return float(clip_norm * w.max() / w.sum())


def gaussian_sigma(noise_multiplier: float, clip_norm: float, weights: np.ndarray) -> float:
    return noise_multiplier * sensitivity(clip_norm, weights)


def epsilon_from_rdp_sum(s_sum: float, delta: float) -> float:
    """s_sum = sum_r 1/z_r^2."""
    if s_sum <= 0:
        return 0.0
    return s_sum / 2.0 + math.sqrt(2.0 * s_sum * math.log(1.0 / delta))


def add_noise(agg: np.ndarray, sigma: float, rng: np.random.Generator) -> np.ndarray:
    return agg + rng.normal(0.0, sigma, size=agg.shape)
