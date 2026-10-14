#!/bin/bash
# push_train_data.sh <pod name> [streams]: copies the backed-up yt_ clips to a training pod over several parallel
# rsync streams (one SSH stream tops out well below the uplink); reruns until the pod is gone so later clips follow
cd "$(dirname "$0")/.."
name=$1; streams=${2:-4}
groups=("[0-9a-f]" "[g-zA-F]" "[G-Z]" "[_-]")
while [ -f harvester/state/$name.json ]; do
  read host port < <(python3 -c "import json;d=json.load(open('harvester/state/$name.json'));print(d['host'],d['port'])")
  e="ssh -i $HOME/.ssh/runpod_ed25519 -p $port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
  echo "$(date '+%F %T') pass start"
  for g in "${groups[@]:0:$streams}"; do
    rsync -a --timeout=300 -e "$e" --include="yt_$g*.mp4" --include="yt_$g*.txt" --include="yt_$g*.json" \
      --include="yt_$g*.npy" --exclude='*.tmp.*' --exclude='*' data/public_pod/ "root@$host:/root/lr/data/public/" &
  done
  wait
  echo "$(date '+%F %T') pass done"
  sleep 120
done
