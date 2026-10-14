#!/usr/bin/env bash
# Запуск любого скрипта проекта в uv-окружении. Операции, которых нет на MPS, уходят на CPU, а не падают.
# Пример: ./run.sh evaluate.py --device cpu
set -euo pipefail
cd "$(dirname "$0")"
export PYTORCH_ENABLE_MPS_FALLBACK=1
export PYTHONIOENCODING=utf-8
exec uv run "$@"
