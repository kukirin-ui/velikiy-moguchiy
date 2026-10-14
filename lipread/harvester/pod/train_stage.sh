#!/bin/bash
# Pod side of one checkpoint of the collection loop (harvester/checkpoint_loop.py train --execute), in /root/lr.
# Args: <life s> <run> <init best.pt|base> <steps> <minutes> <exam the start checkpoint 0|1> <max clips per channel>
#       <chunk batch> <clip list>
# data/pool holds every clip shipped to this pod; the list (mp4/txt/json names the Mac picked, balanced by channel)
# becomes data/stage as hard links. data/exams holds the frozen exams, clips/ the personal test texts only
# (train_e2e.py drops clips with those phrases, R10). The pod may serve many checkpoints: setup and the smoke run
# happen once per pod. Ends with STAGE_DONE, or STAGE_FAILED on any error.
# `train_stage.sh setup <life s>` only sets the pod up (harvester/pod/pilot_train.sh shares it).
set -Eeuo pipefail
cd "$(dirname "$0")/../.."
# preprocess.py's face detector (exams of raw videos) on the GPU: on the CPU it takes minutes per clip
export MVSR_PRE_DEVICE=cuda

setup() {  # once per pod: the self-destruct timer of $1 s, ffmpeg, the MultiVSR weights, python packages
  if [ -f SETUP_OK ]; then return; fi
  mkdir -p fetch
  nohup bash harvester/pod/deadline.sh "$1" 600 > /workspace/deadline.log 2>&1 < /dev/null &
  export DEBIAN_FRONTEND=noninteractive
  apt-get -qq update && apt-get -qq install -y ffmpeg aria2 > /dev/null
  mkdir -p weights
  aria2c -q -x16 -s16 -k1M -d weights -o model.pth https://www.robots.ox.ac.uk/~vgg/research/multivsr/model.pth &
  W1=$!
  aria2c -q -x16 -s16 -k1M -d weights -o feature_extractor.pth \
    https://www.robots.ox.ac.uk/~vgg/research/vtp-for-lip-reading/checkpoints/extended_train_data/feature_extractor.pth &
  W2=$!
  python3 -m pip -q install -r harvester/pod/requirements.txt
  wait $W1 $W2
  [ "$(stat -c%s weights/model.pth)" = 3374308500 ]
  [ "$(stat -c%s weights/feature_extractor.pth)" = 1079529003 ]
  python3 -c "import torch; assert torch.cuda.is_available()"
  touch SETUP_OK
}
if [ "${1:-}" = setup ]; then
  setup "$2"
  exit
fi

LIFE_S=$1 RUN=$2 INIT=$3 STEPS=$4 MINUTES=$5 BASELINE=$6 CAP=$7 CHUNK=$8 LIST=$9
trap 'echo "$(date "+%F %T") failed at line $LINENO"; touch STAGE_FAILED' ERR
mkdir -p fetch logs results/exams
setup "$LIFE_S"

rm -rf data/stage && mkdir -p data/stage
(cd data/pool && xargs -a "../../$LIST" ln -f -t ../stage)
echo "$(date '+%F %T') stage $RUN: $(ls data/stage | grep -c 'json$') clips"

INIT_ARG=(); [ "$INIT" = base ] || INIT_ARG=(--init "$INIT")
WARMUP=$(( STEPS / 10 > 5 ? STEPS / 10 : 5 ))
TRAIN=(python3 train_e2e.py --from-videos data/stage --video-dir data/stage --channel-map harvester/video_channels.tsv
       --max-per-channel "$CAP" --batch 4 --accum 8 --chunk-batch "$CHUNK" --workers 8 "${INIT_ARG[@]}")
LONG=("${TRAIN[@]}" --run "$RUN" --max-steps "$STEPS" --max-minutes "$MINUTES" --warmup "$WARMUP" --eval-every 25)
if ! "${LONG[@]}" > "logs/$RUN.log" 2>&1; then
  grep -q '\[R4\]' "logs/$RUN.log"  # anything but a missing smoke run is a failure
  # R4: the same code, GPU and batch layout for 30 steps first, once per pod and code version
  "${TRAIN[@]}" --run "${RUN}_smoke" --max-steps 30 --eval-every 30 2>&1 | tee "logs/${RUN}_smoke.log"
  "${LONG[@]}" > "logs/$RUN.log" 2>&1
fi
tail -3 "logs/$RUN.log"
CKPT="checkpoints/$RUN/best.pt"
if [ ! -f "$CKPT" ]; then
  # train_e2e.py saves best.pt only when the dev loss beats step 0: no gain, the checkpoint is its start
  echo "no dev-loss gain over $INIT: the checkpoint is the start"
  touch "checkpoints/$RUN/SAME_AS_INIT"
  if [ "$INIT" = base ]; then CKPT=base; else cp "$INIT" "$CKPT"; fi
fi

if [ "$BASELINE" = 1 ]; then
  python3 exams.py run --ckpt "$INIT" --name start --out "results/exams/${RUN}_start.json" --device cuda
fi
python3 exams.py run --ckpt "$CKPT" --name "$RUN" --out "results/exams/${RUN}.json" --device cuda
touch STAGE_DONE
echo "$(date '+%F %T') done"
