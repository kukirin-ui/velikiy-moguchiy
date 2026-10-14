#!/bin/bash
# Replaces the feature workers with <n> sharded ones so the GPU keeps up with the crop pool.
cd "$(dirname "$0")/../.." || exit 1
n=${1:-4}
pkill -TERM -f 'python3 fetch/feature_worker.py'
for _ in $(seq 30); do pgrep -f 'python3 fetch/feature_worker.py' > /dev/null || break; sleep 2; done
rm -f fetch/FEATURES_STOP data/public/*.tmp.npy
for k in $(seq 1 "$n"); do
  setsid nohup python3 fetch/feature_worker.py --min-free 0 --shard "$k/$n" >> fetch/features.out 2>&1 < /dev/null &
done
echo "feature workers: $n"
