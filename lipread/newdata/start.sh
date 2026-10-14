#!/bin/bash
# /root/newdata/start.sh [procs] [shard k/n]: запуск сборщика RuTube/VK/ручной очереди (detached). Остановка: touch /root/newdata/STOP
cd /root/newdata
N=${1:-6}
export RV_SHARD=${2:-0/1}
export RV_YT_PAR=${YT:-4}
export RV_NO_MANUAL=${NOMAN:-}
export RV_INBOX_ONLY=${INBOX_ONLY:-}
export RV_GPU_N=${GPUN:-1}
export RV_QREV=${NOMAN:-}
if pgrep -f "[r]v_collect.py run" >/dev/null; then echo "уже запущен"; exit 1; fi
rm -f STOP
setsid nohup venv/bin/python rv_collect.py run --procs $N --rt-workers ${RT:-1} >> logs/run.log 2>&1 &
echo "запущен, procs=$N shard=$RV_SHARD"
