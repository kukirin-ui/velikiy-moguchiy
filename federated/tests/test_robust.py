import math

import numpy as np

from server import dp, robust
from server.aggregate import aggregate_vectors
from server.config import ServerConfig


def col(*v):
    return np.array(v, np.float64).reshape(-1, 1)


def test_clip_scale():
    assert robust.clip_scale(0.5, 1.0) == 1.0
    assert robust.clip_scale(4.0, 1.0) == 0.25
    assert robust.clip_scale(float("nan"), 1.0) == 0.0


def test_trim_count_keeps_at_least_one():
    assert robust.trim_count(11, 0.1) == 1
    assert robust.trim_count(10, 0.1) == 1
    assert robust.trim_count(5, 0.4) == 2
    assert robust.trim_count(2, 0.45) == 0
    assert robust.trim_count(3, 0.49) == 1


def test_trimmed_mean_unweighted():
    out, tr = robust.weighted_trimmed_mean(col(1, 2, 3, 100), np.ones(4), k=1, with_trimmed_mask=True)
    assert out[0] == 2.5
    assert list(tr) == [1, 0, 0, 1]  # отброшены наименьший и наибольший


def test_trimmed_mean_weighted():
    out, _ = robust.weighted_trimmed_mean(col(1, 2, 3, 100), np.array([1, 1, 3, 1.0]), k=1)
    assert math.isclose(out[0], (2 * 1 + 3 * 3) / 4)


def test_trimmed_mean_per_coordinate():
    X = np.array([[1, 10], [2, 20], [3, 30], [100, -5]], np.float64)
    out, tr = robust.weighted_trimmed_mean(X, np.ones(4), k=1, with_trimmed_mask=True)
    # колонка 1: отбрасываем 1 и 100 -> 2.5; колонка 2: отбрасываем -5 и 30 -> 15
    assert np.allclose(out, [2.5, 15.0])
    assert tr.sum() == 4  # по 2 отброшенных на каждую из 2 координат


def test_weighted_median():
    assert robust.weighted_median(col(1, 2, 3), np.array([1, 1, 5.0]))[0] == 3
    assert robust.weighted_median(col(1, 2, 3, 4), np.ones(4))[0] == 2.5
    assert robust.weighted_median(col(1, 2, 3), np.ones(3))[0] == 2


def test_k0_equals_weighted_mean():
    X = np.random.default_rng(0).standard_normal((5, 7))
    w = np.array([1, 2, 3, 4, 5.0])
    out, _ = robust.weighted_trimmed_mean(X, w, 0)
    assert np.allclose(out, robust.weighted_mean(X, w))


def _vectors(n_honest=9, poison=None, d=50, seed=0):
    rng = np.random.default_rng(seed)
    target = rng.standard_normal(d).astype(np.float32)
    target /= np.linalg.norm(target)
    flats = [(target + 0.05 * rng.standard_normal(d)).astype(np.float32) for _ in range(n_honest)]
    if poison is not None:
        flats.append(poison(target))
    return target, flats


def test_aggregate_clipping_and_trim_neutralize_poison():
    cfg = ServerConfig()
    cfg.aggregation.trim_ratio = 0.1
    target, flats = _vectors(poison=lambda t: -100.0 * t)
    norms = [float(np.linalg.norm(f)) for f in flats]
    agg, st = aggregate_vectors(flats, [100] * 10, cfg, norms, np.random.default_rng(0))
    cos = float(agg @ target / np.linalg.norm(agg))
    assert cos > 0.95 and abs(np.linalg.norm(agg) - 1.0) < 0.15
    assert st["clip_scales"][-1] < 0.02       # злоумышленник сильно заклиплен
    assert st["trimmed_frac"][-1] > 0.7       # и отброшен как крайний по большинству координат (ожидание честных: 0.2)
    assert max(st["trimmed_frac"][:-1]) < 0.4
    # без защиты (mean, без клиппинга) тот же яд ломает результат
    cfg2 = ServerConfig()
    cfg2.aggregation.method, cfg2.aggregation.clip_norm = "mean", 1e9
    bad, _ = aggregate_vectors(flats, [100] * 10, cfg2, norms, np.random.default_rng(0))
    assert float(bad @ target / np.linalg.norm(bad)) < 0


def test_claimed_example_count_is_capped():
    cfg = ServerConfig()
    cfg.aggregation.method = "mean"
    cfg.aggregation.clip_norm = 1e9
    cfg.aggregation.max_weight_examples = 100
    flats = [np.array([1.0], np.float32), np.array([0.0], np.float32)]
    agg, st = aggregate_vectors(flats, [10**6, 100], cfg, [1.0, 0.0], np.random.default_rng(0))
    assert st["weights"] == [100.0, 100.0] and math.isclose(float(agg[0]), 0.5)


def test_dp_math():
    w = np.array([100.0, 100.0, 100.0, 100.0])
    assert math.isclose(dp.sensitivity(2.0, w), 0.5)
    assert math.isclose(dp.gaussian_sigma(1.5, 2.0, w), 0.75)
    # один раунд, z=1: S=1; eps = 0.5 + sqrt(2 ln(1/delta))
    assert math.isclose(dp.epsilon_from_rdp_sum(1.0, 1e-6), 0.5 + math.sqrt(2 * math.log(1e6)))
    assert dp.epsilon_from_rdp_sum(4.0, 1e-6) > dp.epsilon_from_rdp_sum(1.0, 1e-6)
    x = dp.add_noise(np.zeros(200000), 0.3, np.random.default_rng(1))
    assert abs(x.std() - 0.3) < 0.01


def test_dp_requires_fixed_clip():
    cfg = ServerConfig()
    cfg.dp.enabled = True
    try:
        cfg.validate()
        assert False
    except ValueError:
        pass
