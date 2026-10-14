#!/bin/bash
# backstop.sh <seconds>: terminates this pod after <seconds> whatever else happens; armed right after ssh comes up,
# before any upload, so a Mac that dies mid-launch cannot leave the pod billing. Retries until RunPod confirms.
env_of() { tr '\0' '\n' < /proc/1/environ | grep "^$1=" | cut -d= -f2-; }
KEY=$(env_of RUNPOD_API_KEY); ID=$(env_of RUNPOD_POD_ID)
sleep "$1"
until r=$(curl -s -m 30 https://api.runpod.io/graphql -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
    -d "{\"query\":\"mutation { podTerminate(input: {podId: \\\"$ID\\\"}) }\"}"); echo "$r" | grep -q '"data"' && ! echo "$r" | grep -q '"errors"'; do
  sleep 30
done
