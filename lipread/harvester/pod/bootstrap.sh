#!/bin/bash
# Pod side, started detached with output in /workspace/bootstrap.log.
# Args: <life seconds> <download workers|auto> <crop processes|auto> [cpu_only 0|1].
# Installs deps, fetches weights, starts the fetcher + GPU feature worker + heartbeat, arms the self-destruct.
set -euo pipefail
LIFE_S=$1 WORKERS=$2 CROP=$3 CPU_ONLY=${4:-0}
cd "$(dirname "$0")/../.."
echo "$(date '+%F %T') bootstrap: life ${LIFE_S}s, workers $WORKERS, crop $CROP"

# armed first: even a failed install must not leave the pod billing
nohup bash harvester/pod/deadline.sh "$LIFE_S" > /workspace/deadline.log 2>&1 < /dev/null &

export DEBIAN_FRONTEND=noninteractive
apt-get -qq update && apt-get -qq install -y ffmpeg aria2 unzip rsync > /dev/null
command -v deno > /dev/null || { curl -fsSL https://deno.land/install.sh | sh -s -- -y > /dev/null; }
export PATH="$HOME/.deno/bin:$PATH"

VENC_URL=https://www.robots.ox.ac.uk/~vgg/research/vtp-for-lip-reading/checkpoints/extended_train_data/feature_extractor.pth
mkdir -p weights
[ "$CPU_ONLY" = 1 ] || [ -s weights/feature_extractor.pth ] || aria2c -q -x16 -s16 -k1M -d weights -o feature_extractor.pth "$VENC_URL" &
WDL=$!
python3 -m pip -q install -r harvester/pod/requirements.txt
# label check (fetch/asr_service.py): optional, the fetcher runs without it if GigaAM does not install
python3 -m pip -q install --no-deps git+https://github.com/salute-developers/GigaAM.git || echo "gigaam not installed: labels skipped"
python3 -c "import torch, torchvision; assert torch.cuda.is_available() or $CPU_ONLY" || { echo "no CUDA torch/torchvision"; exit 1; }
wait $WDL
[ "$CPU_ONLY" = 1 ] || [ "$(stat -c%s weights/feature_extractor.pth)" = 1079529003 ] || { echo "feature_extractor.pth size mismatch"; exit 1; }

# nproc shows the host's cores inside a RunPod container; the cgroup quota is what we actually get
CPUS=$(awk '$1 != "max" {printf "%d", $1 / $2}' /sys/fs/cgroup/cpu.max 2>/dev/null || true)
[ -n "$CPUS" ] || CPUS=$(awk '{q=$1} END {if (q > 0) printf "%d", q / 100000}' /sys/fs/cgroup/cpu/cpu.cfs_quota_us 2>/dev/null || true)
[ -n "$CPUS" ] && [ "$CPUS" -gt 0 ] || CPUS=$(nproc)
# saturate the pod: a crop process per core, three downloads per crop process (downloads mostly wait on the network)
[ "$CROP" = auto ] && CROP=$CPUS
[ "$WORKERS" = auto ] && WORKERS=$(( CROP * 3 ))
VRAM_GB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | awk '{print int($1/1024)}' || true)
VRAM_GB=${VRAM_GB:-0}
# every crop process holds its own CUDA context + S3FD (~0.8 GB); small cards detect on CPU
DET=cpu; [ "$VRAM_GB" -ge $(( CROP * 8 / 10 + 4 )) ] && DET=cuda
echo "$(date '+%F %T') sizing: $CPUS vCPU, ${VRAM_GB} GB VRAM -> crop $CROP, workers $WORKERS, detector $DET"

rm -f fetch/STOP fetch/FEATURES_STOP
chmod 600 fetch/cookies.txt 2>/dev/null || true
export HARVEST_POD=1 LIPREAD_DET_DEVICE=$DET HARVEST_MAX_WORKERS=$WORKERS HARVEST_MAX_CROP=$CROP HARVEST_MAX_DATA_GB=170
nohup python3 fetch/run.py --selection fetch/selection_pod.jsonl --target-hours 100000 \
  --workers "$WORKERS" --max-workers "$WORKERS" --crop-procs "$CROP" >> fetch/run.out 2>&1 < /dev/null &
[ "$CPU_ONLY" = 1 ] || nohup python3 fetch/feature_worker.py --min-free 0 >> fetch/features.out 2>&1 < /dev/null &
nohup bash harvester/pod/heartbeat.sh > /dev/null 2>&1 < /dev/null &
echo "$(date '+%F %T') bootstrap: started"
