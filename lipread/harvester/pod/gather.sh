#!/bin/bash
# On the training pod: every 5 min copies features, transcripts and clip metadata from the other pods into
# /root/train_data (mp4 stays where it is). Args: <user@host:port>...
mkdir -p /root/train_data
while true; do
  for src in "$@"; do
    hp=${src%:*}; port=${src##*:}
    rsync -a --timeout=120 -e "ssh -i /root/.ssh/gather -p $port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR" \
      --include='*.npy' --include='*.txt' --include='*.json' --exclude='*.tmp.*' --exclude='*' \
      "$hp:/root/lr/data/public/" /root/train_data/ 2>&1 | tail -1
  done
  rsync -a --include='*.npy' --include='*.txt' --include='*.json' --exclude='*.tmp.*' --exclude='*' /root/lr/data/public/ /root/train_data/
  echo "$(date '+%F %T') gathered: $(ls /root/train_data | grep -c 'npy$') clips with features"
  sleep 300
done
