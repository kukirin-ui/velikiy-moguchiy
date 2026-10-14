#!/bin/bash
# Pod side of the long training after the pilot (harvester/final_train.py run), in /root/lr.
# Args: <life s> <init best.pt> <chunk batch> <clips> <train_e2e.py --dev-pct> <exams.py --only>
# lists/final.txt (mp4/txt/json names the Mac picked, dev clips included) becomes data/final as hard links of data/pool.
# R4 smoke run, then one run with as many steps as fit (at most 3 passes), last.pt + best.pt saved at every evaluation
# (~45 min apart) for the Mac to pull; TRAIN_DONE; the exams of last.pt, best.pt and the app's model
# (checkpoints/app/best.pt). Ends with FINAL_DONE, or FINAL_FAILED on any error.
set -Eeuo pipefail
LIFE_S=$1 INIT=$2 CHUNK=$3 N=$4 DEV_PCT=$5 ONLY=$6
cd "$(dirname "$0")/../.."
T0=$(date +%s)
trap 'echo "$(date "+%F %T") failed at line $LINENO"; touch FINAL_FAILED' ERR
export MVSR_PRE_DEVICE=cuda
mkdir -p fetch logs results/exams checkpoints
bash harvester/pod/train_stage.sh setup "$LIFE_S"
rm -rf checkpoints/final checkpoints/final_smoke results/exams/final_*.json logs/final*

rm -rf data/final && mkdir -p data/final
(cd data/pool && xargs -a ../../lists/final.txt ln -f -t ../final)
echo "$(date '+%F %T') final: $(ls data/final | grep -c 'json$') clips"

train() {
  python3 train_e2e.py --from-videos data/final --video-dir data/final --channel-map harvester/video_channels.tsv \
    --dev-pct "$DEV_PCT" --batch 4 --accum 8 --chunk-batch "$CHUNK" --workers 8 --init "$INIT" "$@"
}
exam() {  # <checkpoint> <name>
  python3 exams.py run --ckpt "$1" --name "$2" --out "results/exams/final_$2.json" --device cuda --only "$ONLY"
}

S0=$(date +%s)
train --run final_smoke --max-steps 30 --eval-every 30 > logs/final_smoke.log 2>&1
SMOKE_S=$(( $(date +%s) - S0 ))
EXAM_S=420  # one exam run on a 3090 took ~250 s; the app's model is examined last, after both final checkpoints

B=$(python3 harvester/final_train.py steps --smoke-log logs/final_smoke.log --smoke-s "$SMOKE_S" --exam-s "$EXAM_S" \
    --left $(( LIFE_S - ($(date +%s) - T0) )) --clips "$N")
read -r STEPS EVAL WARMUP GUARD <<< "$B"
train --run final --max-steps "$STEPS" --eval-every "$EVAL" --warmup "$WARMUP" --max-minutes "$GUARD" --save-last \
  > logs/final.log 2>&1
tail -2 logs/final.log
touch TRAIN_DONE

exam checkpoints/final/last.pt last
if [ -f checkpoints/final/best.pt ]; then exam checkpoints/final/best.pt best; fi
exam checkpoints/app/best.pt app
touch FINAL_DONE
echo "$(date '+%F %T') done"
