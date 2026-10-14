#!/bin/bash
# After $1 seconds stops the harvest, waits until the Mac has pulled a backup taken after the stop
# (it touches /workspace/mac_pulled), at most $2 seconds (default 15 min), then wipes the cookies and terminates the pod.
env_of() { tr '\0' '\n' < /proc/1/environ | grep "^$1=" | cut -d= -f2-; }
KEY=$(env_of RUNPOD_API_KEY); ID=$(env_of RUNPOD_POD_ID)
R=$(cd "$(dirname "$0")/../.." && pwd)
sleep "$1"
touch "$R/fetch/STOP" "$R/fetch/FEATURES_STOP" /workspace/stopped_at
sleep 120  # let the crop pool finish the videos it holds
touch /workspace/stopped_at
end=$(( $(date +%s) + ${2:-900} ))
until [ /workspace/mac_pulled -nt /workspace/stopped_at ] || [ "$(date +%s)" -ge "$end" ]; do sleep 30; done
shred -u "$R/fetch/cookies.txt" /workspace/lipread-ru/fetch/cookies.txt 2>/dev/null
until r=$(curl -s -m 30 https://api.runpod.io/graphql -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
    -d "{\"query\":\"mutation { podTerminate(input: {podId: \\\"$ID\\\"}) }\"}"); echo "$r" | grep -q '"data"' && ! echo "$r" | grep -q '"errors"'; do
  sleep 30  # one lost request must not leave the pod billing until the balance is gone
done
