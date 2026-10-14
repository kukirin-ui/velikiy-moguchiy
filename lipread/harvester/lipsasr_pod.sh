#!/bin/bash
# lipsasr_pod.sh <pod name>: lips + audio measurement on the personal dictations (whisper_eval.py --set voiced).
# The model stages (GigaAM, lip n-best) run on the pod GPU, since the Mac takes no ML runs (RULES.md R11); the Qwen API
# stage and the reports then run on the Mac. Inputs go up: the webcam clips, the noise/pseudo-whisper wavs already made
# by the prep stage (the café bed needs macOS `say`), the transcripts done so far and the me1 checkpoint. Pod dir:
# LIPSASR_DIR (default /root/lipsasr, apart from a collector's /root/lr so its code is never overwritten). Rerunning
# resumes every stage.
set -euo pipefail
cd "$(dirname "$0")/.."
name=$1; R=${LIPSASR_DIR:-/root/lipsasr}; W=work/lipsasr/voiced
read host port < <(python3 -c "import json;d=json.load(open('harvester/state/$name.json'));print(d['host'],d['port'])")
e="ssh -i $HOME/.ssh/runpod_ed25519 -p $port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
for c in $(./run.sh python -c "import whisper_eval as w; print(*w.SETS['voiced']['conds'])"); do
  [ "$(ls $W/$c/*.wav 2> /dev/null | wc -l)" -gt 0 ] || { echo "missing $W/$c: run ./run.sh whisper_eval.py --set voiced prep"; exit 1; }
done

$e root@$host "mkdir -p $R/data/voiced $R/$W $R/results/pod_runs/t1/checkpoints/me1 $R/harvester/pod"
rsync -a -e "$e" whisper_eval.py mvsr.py preprocess.py lora.py metrics.py memguard.py root@$host:$R/
rsync -a -e "$e" --exclude=.git --exclude=samples multivsr/ root@$host:$R/multivsr/
rsync -a -e "$e" harvester/pod/lipsasr.sh harvester/pod/requirements.txt root@$host:$R/harvester/pod/
rsync -a -e "$e" --include='*.mp4' --include='*.txt' --include='*.json' --exclude='*' data/voiced/ root@$host:$R/data/voiced/
rsync -a -e "$e" --exclude='src*' --exclude='qwen.jsonl' --exclude='POD_*' $W/ root@$host:$R/$W/
rsync -a -e "$e" results/pod_runs/t1/checkpoints/me1/ root@$host:$R/results/pod_runs/t1/checkpoints/me1/
$e root@$host "cd $R || exit 1; nohup bash harvester/pod/lipsasr.sh > /workspace/lipsasr.log 2>&1 < /dev/null &"
echo "$(date '+%F %T') started on $name, log: /workspace/lipsasr.log"

while true; do
  sleep 60
  st=$($e root@$host "cd $R/$W && ls POD_DONE POD_FAILED 2> /dev/null; wc -l < gigaam.jsonl; cat lips_*.jsonl 2> /dev/null | wc -l" | tr '\n' ' ') || continue
  echo "$(date '+%F %T') $st"
  case "$st" in *POD_FAILED*) $e root@$host "tail -20 /workspace/lipsasr.log"; exit 1;; *POD_DONE*) break;; esac
done
rsync -a -e "$e" root@$host:$R/$W/gigaam.jsonl "root@$host:$R/$W/lips_*.jsonl" $W/
./run.sh whisper_eval.py --set voiced qwen
./run.sh whisper_eval.py --set voiced report --ref gigaam
./run.sh whisper_eval.py --set voiced report --ref qwen
echo "reports: results/lipsasr/voiced_ref-gigaam.md, results/lipsasr/voiced_ref-qwen.md"
