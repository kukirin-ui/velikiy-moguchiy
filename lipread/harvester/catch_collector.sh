#!/bin/bash
# catch_collector.sh <name> <hours of life>: retries a 32-core 3090 every minute until one is free, then turns it
# into an inbox collector. Gives up when less than 45 min of the requested life would remain.
# COMMUNITY_ONLY=1 skips secure cloud; GPUS='type|type' tries these GPU types in order (default: RTX 3090).
cd "$(dirname "$0")/.."
name=$1; end=$(( $(date +%s) + $(python3 -c "print(int(float('$2')*3600) - 2700)") ))
# packing takes minutes; done up front so a pod is never created after the check below gave up on it
[ -f harvester/dist/harvester-$name.tar.gz ] || python3 harvester/harvest.py --name $name --part 3/3 pack \
  >> harvester/harvest-$name.log 2>&1
while [ "$(date +%s)" -lt "$end" ]; do
  [ -f harvester/STAGE_HOLD ] && { echo "$(date '+%F %T') catch: $name: stage hold, not launching" >> harvester/harvest-$name.log; exit 1; }
  left=$(python3 -c "print(round(($end + 2700 - $(date +%s)) / 3600, 2))")
  clouds=("" "--community"); [ "${COMMUNITY_ONLY:-0}" = 1 ] && clouds=("--community")
  IFS='|' read -r -a gpus <<< "${GPUS:-NVIDIA GeForce RTX 3090}"
  for g in "${gpus[@]}"; do for c in "${clouds[@]}"; do
    python3 harvester/harvest.py --name $name --part 3/3 launch --gpu "$g" $c --min-vcpu ${MIN_VCPU:-31} \
      --max-hours $left --cookies fetch/cookies_pod.txt >> harvester/harvest-$name.log 2>&1 &
    pid=$!
    # launch writes the state file when the pod is created and removes it when it gives the pod up (R5, errors)
    while kill -0 $pid 2>/dev/null && [ ! -f harvester/state/$name.json ]; do sleep 5; done
    if [ -f harvester/state/$name.json ] && python3 harvester/deploy_collector.py $name >> harvester/deploy-$name.log 2>&1; then
      wait $pid; exit 0
    fi
    # a pod that came up but could not become a collector would only bill: give it back and try again
    [ -f harvester/state/$name.json ] && python3 harvester/harvest.py --name $name stop >> harvester/harvest-$name.log 2>&1
    wait $pid
  done; done
  sleep 20
done
echo "$(date '+%F %T') catch: $name got no pod" >> harvester/harvest-$name.log
