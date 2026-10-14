#!/bin/bash
# Pod side of the pilot's one training step (harvester/pilot_train.py run), in /root/lr.
# Args: <life s> <the arms' life s> <init best.pt> <chunk batch> <NEW clips> <FULL clips> <train_e2e.py --dev-pct>
#       <exams.py --only>
# data/pool holds the clips of every run; lists/pilot_{new,narrow,full}.txt (mp4/txt/json names the Mac picked, the
# same dev clips in each) become data/pilot_<list> as hard links. Three runs from the same init with the same steps and
# batch layout, within the arms' life: new (seed 0), narrow0 (seed 0), narrow1 (seed 1, the seed noise); ARMS_DONE.
# Then FULL, the release model, on every pilot clip in what is left of the life, or FULL_SKIPPED. The exams grade each
# run's final step (last.pt), not best.pt. Ends with PILOT_DONE, or PILOT_FAILED on any error.
set -Eeuo pipefail
LIFE_S=$1 ARMS_S=$2 INIT=$3 CHUNK=$4 N_NEW=$5 N_FULL=$6 DEV_PCT=$7 ONLY=$8
cd "$(dirname "$0")/../.."
T0=$(date +%s)
trap 'echo "$(date "+%F %T") failed at line $LINENO"; touch PILOT_FAILED' ERR
export MVSR_PRE_DEVICE=cuda
mkdir -p fetch logs results/exams checkpoints
bash harvester/pod/train_stage.sh setup "$LIFE_S"
rm -rf checkpoints/pilot_* results/exams/pilot_*.json logs/pilot_*

for D in new narrow full; do
  rm -rf "data/pilot_$D" && mkdir -p "data/pilot_$D"
  (cd data/pool && xargs -a "../../lists/pilot_$D.txt" ln -f -t "../pilot_$D")
  echo "$(date '+%F %T') $D: $(ls "data/pilot_$D" | grep -c 'json$') clips"
done

train() {  # <clip folder> <train_e2e.py flags>
  local d=$1; shift
  python3 train_e2e.py --from-videos "data/$d" --video-dir "data/$d" --channel-map harvester/video_channels.tsv \
    --dev-pct "$DEV_PCT" --batch 4 --accum 8 --chunk-batch "$CHUNK" --workers 8 --init "$INIT" "$@"
}

# R4: the same code, GPU and batch layout for 30 steps first; it also measures this card's speed and a run's overhead
S0=$(date +%s)
train pilot_new --run pilot_smoke --max-steps 30 --eval-every 30 > logs/pilot_smoke.log 2>&1
SMOKE_S=$(( $(date +%s) - S0 ))
E0=$(date +%s)
python3 exams.py run --ckpt "$INIT" --name init --out results/exams/pilot_init.json --device cuda --only "$ONLY"
EXAM_S=$(( $(date +%s) - E0 ))  # the same exams as every arm's: the budget reserves three more of these

# steps for all three runs, three exam runs and the Mac's pull before the arms' end (pilot_train.py budget())
B=$(python3 harvester/pilot_train.py steps --smoke-log logs/pilot_smoke.log --smoke-s "$SMOKE_S" --exam-s "$EXAM_S" \
    --left $(( ARMS_S - ($(date +%s) - T0) )) --clips "$N_NEW")
read -r STEPS EVAL WARMUP GUARD <<< "$B"

arm() {  # <run> <clip folder> <seed> <steps> <eval every> <warmup> <time guard min>
  train "$2" --run "pilot_$1" --seed "$3" --max-steps "$4" --eval-every "$5" --warmup "$6" --max-minutes "$7" \
    --save-last > "logs/pilot_$1.log" 2>&1
  tail -2 "logs/pilot_$1.log"
  python3 exams.py run --ckpt "checkpoints/pilot_$1/last.pt" --name "$1" --out "results/exams/pilot_$1.json" \
    --device cuda --only "$ONLY"
}
arm new pilot_new 0 "$STEPS" "$EVAL" "$WARMUP" "$GUARD"
arm narrow0 pilot_narrow 0 "$STEPS" "$EVAL" "$WARMUP" "$GUARD"
arm narrow1 pilot_narrow 1 "$STEPS" "$EVAL" "$WARMUP" "$GUARD"
touch ARMS_DONE

# FULL, the release model: one run and its exam in what is left before the timer, or skipped (prints why)
F=$(python3 harvester/pilot_train.py steps --full --smoke-log logs/pilot_smoke.log --smoke-s "$SMOKE_S" \
    --exam-s "$EXAM_S" --left $(( LIFE_S - ($(date +%s) - T0) )) --clips "$N_FULL")
read -r FSTEPS FEVAL FWARMUP FGUARD <<< "$F"
if [ "$FSTEPS" -gt 0 ]; then
  arm full pilot_full 0 "$FSTEPS" "$FEVAL" "$FWARMUP" "$FGUARD"
else
  touch FULL_SKIPPED
fi
touch PILOT_DONE
echo "$(date '+%F %T') done"
