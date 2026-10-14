#!/bin/bash
# Keeps asking RunPod for a pod until one is free, then launches and watches it.
# Args: <name> <part> <give-up after hours> [launch args...]
name=$1 part=$2 hours=$3; shift 3
cd "$(dirname "$0")/.." || exit 1
log="harvester/harvest-$name.log"
end=$(( $(date +%s) + ${hours%.*} * 3600 ))
fails=0
while [ "$(date +%s)" -lt "$end" ]; do
  before=$(grep -c "launch failed" "$log" 2>/dev/null || echo 0)
  python3 harvester/harvest.py --name "$name" --part "$part" launch "$@" >> "$log" 2>&1 && exit 0
  after=$(grep -c "launch failed" "$log" 2>/dev/null || echo 0)
  # a pod that was created and then failed to set up cost money; stop after three of those
  [ "$after" -gt "$before" ] && fails=$((fails + 1))
  [ "$fails" -ge 3 ] && { echo "$(date '+%F %T') catch: $name gave up after $fails failed setups" >> "$log"; exit 1; }
  sleep 60
done
echo "$(date '+%F %T') catch: $name found no free pod in $hours h" >> "$log"
