#!/usr/bin/env bash
# Любая модельная задача (PyTorch/MPS) запускается под общим охранником памяти tools/mem_guard.py:
# бюджет MPS = доступная память - 6 ГБ, пауза (SIGSTOP) при росте свопа > 512 МБ или свободной памяти < 15%.
# Пример: ./guarded.sh train.py --run my1 --resume --max-minutes 240
#         ./guarded.sh evaluate.py --lora checkpoints/my1/best.pt
set -euo pipefail
cd "$(dirname "$0")"
exec python3 ../tools/mem_guard.py -- ./run.sh "$@"
