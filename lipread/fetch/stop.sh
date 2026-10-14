#!/bin/bash
# Мягкая остановка: дорезает ролики, которые уже скачаны. Жёсткая: fetch/stop.sh now
cd "$(dirname "$0")/.." || exit 1
touch fetch/STOP fetch/FEATURES_STOP
pkill -TERM -f "fetch/run.py"
if [ "$1" = now ]; then pkill -TERM -f "fetch/feature_worker.py"; pkill -TERM -f "tools/mem_guard.py"; fi
echo "остановка запрошена (fetch/STOP). Прогресс: tail -f fetch/progress.log"
