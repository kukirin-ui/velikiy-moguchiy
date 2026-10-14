#!/bin/bash
# push_personal.sh <pod name>: copies the personal silent and webcam clips to a training pod every 5 min
cd "$(dirname "$0")/.."
name=$1
while [ -f harvester/state/$name.json ]; do
  read host port < <(python3 -c "import json;d=json.load(open('harvester/state/$name.json'));print(d['host'],d['port'])")
  e="ssh -i $HOME/.ssh/runpod_ed25519 -p $port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
  rsync -a --timeout=120 -e "$e" --include='*.mp4' --include='*.txt' --exclude='*' data/silent/ "root@$host:/root/lr/data/silent/"
  rsync -a --timeout=120 -e "$e" --include='*.mp4' --include='*.txt' --exclude='*' data/voiced/ "root@$host:/root/lr/data/voiced/"
  sleep 300
done
