#!/bin/bash
# Writes /workspace/status.json every 30 s for the Mac-side watcher.
R=$(cd "$(dirname "$0")/../.." && pwd)
while sleep 30; do
  clips=$(find $R/data/public -maxdepth 1 -name '*.json' ! -name '*.tmp.json' | wc -l)
  feats=$(find $R/data/public -maxdepth 1 -name '*.npy' ! -name '*.tmp.npy' | wc -l)
  gpu=$(nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv,noheader,nounits 2>/dev/null | head -1)
  disk=$(df -BG --output=avail "$R" | tail -1 | tr -dc 0-9)
  fetch=$(pgrep -f fetch/run.py > /dev/null && echo running || echo stopped)
  feat=$(pgrep -f fetch/feature_worker.py > /dev/null && echo running || echo stopped)
  last=$(tail -1 $R/fetch/progress.log 2>/dev/null | cut -c1-300 | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '{"ts":%s,"clips":%s,"features":%s,"gpu":"%s","disk_free_gb":%s,"fetch":"%s","features_worker":"%s","last":"%s"}\n' \
    "$(date +%s)" "$clips" "$feats" "$gpu" "${disk:-0}" "$fetch" "$feat" "$last" > /workspace/status.json.tmp
  mv /workspace/status.json.tmp /workspace/status.json
done
