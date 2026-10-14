#!/bin/bash
# Replaces the running self-destruct timer with a new one: <seconds of life left>.
cd "$(dirname "$0")/../.." || exit 1
ps -eo pid,args | awk '$2 == "bash" && $3 ~ /deadline.sh$/ {print $1}' | xargs -r kill
setsid nohup bash harvester/pod/deadline.sh "$1" "${2:-600}" >> /workspace/deadline.log 2>&1 < /dev/null &
if [ -f /root/backstop.sh ]; then  # harvest.arm_backstop's timer must not fire before the new deadline
  ps -eo pid,args | awk '$2 == "bash" && $3 == "/root/backstop.sh" {print $1}' | xargs -r kill
  setsid nohup bash /root/backstop.sh $(( $1 + 1800 )) >> /root/backstop.log 2>&1 < /dev/null &
fi
echo "timer: $1 s"
