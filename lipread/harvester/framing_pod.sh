#!/bin/bash
# framing_pod.sh <pod name>: does a 480p source cost test WER? (results/framing/README.md, the s3fd480 row)
# The evaluations run on the pod GPU, since the Mac takes no ML runs (RULES.md R11): base MultiVSR, me1 and e2e_full on
# the 50 test clips cropped three ways (harvester/pod/framing.sh). Inputs go up: the test clips, the three crop folders
# (made on the Mac with facecrop.py), the code and the me1/e2e_full checkpoints. Pod dir: FRAMING_DIR (default
# /root/framing, apart from a collector's /root/lr so its code is never overwritten). Rerunning resumes.
# The Mac then pulls the reports into results/framing/cuda and prints the paired comparison (metrics only, no model).
set -euo pipefail
cd "$(dirname "$0")/.."
name=$1; R=${FRAMING_DIR:-/root/framing}; C=results/pod_runs/t1/checkpoints
read host port < <(python3 -c "import json;d=json.load(open('harvester/state/$name.json'));print(d['host'],d['port'])")
e="ssh -i $HOME/.ssh/runpod_ed25519 -p $port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
for d in work/faces work/faces_s3fd720 work/faces_s3fd480; do
  [ "$(ls $d/*.avi 2> /dev/null | wc -l)" -eq 50 ] || { echo "missing crops in $d (results/framing/README.md says how they were made)"; exit 1; }
done

$e root@$host "mkdir -p $R/clips $R/work $R/$C/me1 $R/$C/e2e_full $R/harvester/pod $R/results/framing/cuda"
rsync -a -e "$e" evaluate.py mvsr.py preprocess.py facecrop.py lora.py metrics.py memguard.py root@$host:$R/
rsync -a -e "$e" --exclude=.git --exclude=samples multivsr/ root@$host:$R/multivsr/
rsync -a -e "$e" harvester/pod/framing.sh harvester/pod/requirements.txt root@$host:$R/harvester/pod/
rsync -a -e "$e" --include='*.mp4' --include='*.txt' --exclude='*' clips/ root@$host:$R/clips/
rsync -a -e "$e" work/faces work/faces_s3fd720 work/faces_s3fd480 root@$host:$R/work/
for m in me1 e2e_full; do rsync -a -e "$e" $C/$m/best.pt $C/$m/best_venc.pth root@$host:$R/$C/$m/; done
$e root@$host "cd $R || exit 1; nohup bash harvester/pod/framing.sh > /workspace/framing.log 2>&1 < /dev/null &"
echo "$(date '+%F %T') started on $name, log: /workspace/framing.log"

while true; do
  sleep 60
  st=$($e root@$host "cd $R/results/framing/cuda && ls POD_DONE POD_FAILED 2> /dev/null; ls *.json 2> /dev/null | wc -l" | tr '\n' ' ') || continue
  echo "$(date '+%F %T') $st"
  case "$st" in *POD_FAILED*) $e root@$host "tail -20 /workspace/framing.log"; exit 1;; *POD_DONE*) break;; esac
done
mkdir -p results/framing/cuda
rsync -a -e "$e" --include='*.md' --include='*.json' --include='*.log' --exclude='*' root@$host:$R/results/framing/cuda/ results/framing/cuda/
.venv/bin/python results/framing/paired.py results/framing/cuda | tee results/framing/cuda/paired.txt
