#!/bin/bash
# Restarts the pod fetcher in place.
# Args: <download workers> <crop processes>
cd "$(dirname "$0")/../.." || exit 1
touch fetch/STOP
pkill -TERM -f 'python3 fetch/run.py'
for _ in $(seq 60); do pgrep -f 'python3 fetch/run.py' > /dev/null || break; sleep 2; done
pkill -KILL -f 'python3 fetch/run.py'; pkill -KILL -x ffmpeg; sleep 1
rm -f fetch/STOP
export HARVEST_POD=1 LIPREAD_DET_DEVICE=${LIPREAD_DET_DEVICE:-cpu} HARVEST_MAX_WORKERS=$1 HARVEST_MAX_CROP=$2 HARVEST_MAX_DATA_GB=120
export PATH="$HOME/.deno/bin:$PATH"
setsid nohup python3 fetch/run.py --selection fetch/selection_pod.jsonl --target-hours 100000 \
  --workers "$1" --max-workers "$1" --crop-procs "$2" >> fetch/run.out 2>&1 < /dev/null &
echo "restarted in $(pwd): workers $1, crop $2"
