#!/bin/bash
# pull_results.sh <pod name>: copies training results off a pod every 5 min until the pod is gone
cd "$(dirname "$0")/.."
name=$1; dst=results/pod_runs/$name; mkdir -p "$dst"
while [ -f harvester/state/$name.json ]; do
  read host port < <(python3 -c "import json;d=json.load(open('harvester/state/$name.json'));print(d['host'],d['port'])")
  e="ssh -i $HOME/.ssh/runpod_ed25519 -p $port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
  rsync -a --timeout=120 -e "$e" --include='*/' --include='best*' --include='*.json' --include='*.jsonl' --include='DONE' \
    --exclude='*' "root@$host:/root/lr/checkpoints/" "$dst/checkpoints/" 2>/dev/null
  rsync -a --timeout=60 -e "$e" "root@$host:/root/lr/logs/" "$dst/logs/" 2>/dev/null
  rsync -a --timeout=60 -e "$e" "root@$host:/root/lr/results/" "$dst/results/" 2>/dev/null
  rsync -a --timeout=60 -e "$e" "root@$host:/root/pilot2.log" "root@$host:/root/chain.log" "$dst/" 2>/dev/null
  sleep 300
done
