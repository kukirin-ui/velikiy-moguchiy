#!/bin/bash
# Moves a running harvest from the /workspace network volume to the pod's local disk and restarts it there.
# Args: <seconds of life left> <download workers> <crop processes>
set -u
SRC=/workspace/lipread-ru DST=/root/lr
touch $SRC/fetch/STOP $SRC/fetch/FEATURES_STOP
for pat in 'python3 fetch/run.py' 'python3 fetch/feature_worker.py' 'harvester/pod/heartbeat.sh'; do pkill -TERM -f "$pat"; done
ps -eo pid,args | awk '$2 == "bash" && $3 ~ /deadline.sh$/ {print $1}' | xargs -r kill
for _ in $(seq 60); do pgrep -f 'python3 fetch/' > /dev/null || break; sleep 2; done
pkill -KILL -f 'python3 fetch/'; pkill -KILL -x ffmpeg; pkill -KILL -x ffprobe
mkdir -p $DST
rsync -a --exclude data/tmp $SRC/ $DST/
rm -rf $DST/data/tmp $DST/fetch/STOP $DST/fetch/FEATURES_STOP /root/htmp
cd $DST
cp /workspace/lipread-ru/harvester/pod/*.sh harvester/pod/ 2>/dev/null
nohup bash harvester/pod/deadline.sh "$1" >> /workspace/deadline.log 2>&1 < /dev/null &
bash harvester/pod/restart_fetch.sh "$2" "$3"
nohup python3 fetch/feature_worker.py --min-free 0 >> fetch/features.out 2>&1 < /dev/null &
nohup bash harvester/pod/heartbeat.sh > /dev/null 2>&1 < /dev/null &
shred -u $SRC/fetch/cookies.txt
echo "relocated to $DST, $(ls data/public | grep -c 'json$') clips carried over"
