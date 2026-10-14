#!/bin/bash
# Запуск сбора публичных данных в фоне. Повторный запуск безопасен (клипы с .json пропускаются).
#   fetch/start.sh            - загрузка+кроп (fetch/run.py) и живые признаки VTP (fetch/feature_worker.py)
#   fetch/start.sh fetch      - только загрузка+кроп
#   fetch/start.sh features   - только признаки
cd "$(dirname "$0")/.." || exit 1
ROOT=$(pwd)
MG="$ROOT/../tools/mem_guard.py"
rm -f fetch/STOP fetch/FEATURES_STOP
what=${1:-all}
if [ "$what" = all ] || [ "$what" = fetch ]; then
  nohup caffeinate -i python3 "$MG" --reserve-gb 6 --min-free-pct 12 -- nice -n 10 "$ROOT/.venv/bin/python" "$ROOT/fetch/run.py" \
    --target-hours "${TARGET_HOURS:-300}" >> fetch/run.out 2>&1 &
  echo "fetch: запущен (обёртка mem_guard pid $!)"
fi
if [ "$what" = all ] || [ "$what" = features ]; then
  nohup caffeinate -i python3 "$MG" --max-budget-gb 4 --reserve-gb 6 --min-free-pct 12 -- nice -n 10 "$ROOT/.venv/bin/python" "$ROOT/fetch/feature_worker.py" \
    >> fetch/features.out 2>&1 &
  echo "features: запущен (обёртка mem_guard pid $!)"
fi
