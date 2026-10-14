#!/bin/bash
# Ends the pod's billing: after $1 seconds, or earlier once the renderers are DONE, stops them, waits until the Mac
# has pulled the clips (it touches /workspace/mac_pulled), at most 2 h, then terminates the pod.
env_of() { tr '\0' '\n' < /proc/1/environ | grep "^$1=" | cut -d= -f2-; }
KEY=$(env_of RUNPOD_API_KEY); ID=$(env_of RUNPOD_POD_ID)
W=$2
end=$(( $(date +%s) + $1 ))
until [ -e "$W/DONE" ] || [ "$(date +%s)" -ge "$end" ]; do sleep 30; done
touch "$W/STOP" /workspace/stopped_at
for p in "$W"/gen_*.pid; do kill "$(cat "$p")" 2>/dev/null; done
pull_end=$(( $(date +%s) + 7200 ))
until [ /workspace/mac_pulled -nt /workspace/stopped_at ] || [ "$(date +%s)" -ge "$pull_end" ]; do sleep 30; done
curl -s https://api.runpod.io/graphql -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d "{\"query\":\"mutation { podTerminate(input: {podId: \\\"$ID\\\"}) }\"}"
