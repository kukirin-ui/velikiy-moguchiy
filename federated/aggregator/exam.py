"""Скрытый экзамен: WER адаптера на закрытом наборе. Набор лежит в закрытом датасете Hugging Face и скачивается
во временный каталог раннера; в репозитории нет ни фраз, ни признаков, ни списка клипов.

Формат набора (собирает aggregator/build_exam.py):
  exam.jsonl         {"id": ..., "text": ..., "feats": "feats/<id>.npy"} на строку
  feats/<id>.npy     признаки VTP (T, 512) fp16, посчитанные визуальной частью lips-0.1 (как у клиентов)

LipreadScorer запускает aggregator/exam_score.py в окружении с torch: базовая MultiVSR грузится один раз, каждый
адаптер вливается в веса (W += α/r·B·A), клипы распознаются, веса возвращаются. Признаки готовые, поэтому на CPU
бесплатного раннера считается только трансформер: это и есть «оценка только LoRA».
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Mapping, Protocol

import numpy as np

from protocol.adapter_io import save_adapter
from protocol.spec import AdapterSpec

SCRIPT = Path(__file__).resolve().parent / "exam_score.py"


@dataclass(frozen=True)
class ExamScore:
    wer: float
    cer: float
    n: int


class Scorer(Protocol):
    def score(self, adapters: Mapping[str, Mapping[str, np.ndarray]]) -> dict[str, ExamScore]: ...


class FunctionScorer:
    """Для тестов и симуляции: WER считает переданная функция от тензоров адаптера."""

    def __init__(self, fn: Callable[[Mapping[str, np.ndarray]], float], n: int = 100):
        self.fn, self.n, self.calls = fn, n, 0

    def score(self, adapters):
        self.calls += 1
        return {k: ExamScore(float(self.fn(v)), 0.0, self.n) for k, v in adapters.items()}


class LipreadScorer:
    def __init__(self, exam_dir: Path, lipread_dir: Path, spec: AdapterSpec, *, python: str = sys.executable,
                 beam: int = 4, limit: int = 0, timeout_seconds: float = 4 * 3600):
        self.exam_dir, self.lipread_dir, self.spec = Path(exam_dir), Path(lipread_dir), spec
        self.python, self.beam, self.limit, self.timeout = python, beam, limit, timeout_seconds
        if not (self.exam_dir / "exam.jsonl").exists():
            raise FileNotFoundError(f"нет экзамена: {self.exam_dir / 'exam.jsonl'}")

    def score(self, adapters):
        with tempfile.TemporaryDirectory() as td:
            names = list(adapters)
            files = []
            for i, name in enumerate(names):
                p = Path(td) / f"a{i:04d}.safetensors"
                save_adapter({k: np.asarray(v, np.float32) for k, v in adapters[name].items()}, p)
                files.append(str(p))
            out = Path(td) / "scores.json"
            cmd = [self.python, str(SCRIPT), "--exam", str(self.exam_dir), "--lipread", str(self.lipread_dir),
                   "--alpha", str(self.spec.alpha), "--rank", str(self.spec.rank), "--beam", str(self.beam),
                   "--limit", str(self.limit), "--out", str(out), *files]
            # the scorer prints only progress and numbers; the exam texts never reach the log. It runs the authors'
            # MultiVSR code, so it gets a bare environment: no tokens or keys of the job reach it
            env = {k: os.environ[k] for k in ("PATH", "HOME", "LANG", "TMPDIR") if k in os.environ}
            subprocess.run(cmd, check=True, timeout=self.timeout, env={**env, "PYTHONUNBUFFERED": "1"})
            res = json.loads(out.read_text())
        return {name: ExamScore(**res[f]) for name, f in zip(names, files)}
