#!/bin/bash
# Pod side of the synthetic-lips run: started detached, output in /workspace/synth_bootstrap.log.
#   bash synth/pod/bootstrap.sh <stage: 10h|1000h|stub> <life seconds>
# Stages:
#   stub   local test (Mac or pod): pilot data under data/synth/src, 3 clips, no downloads, no pod calls
#   10h    Golos 10 h crowd sample + 3 RuLS shards (HF parquet), SFHQ samples (~1400 faces): ~10 h of video
#   1000h  Golos full (opus tar from Sber's CDN, 1227 h) + RuLS full (98 h) + Common Voice ru if $CV_TAR_URL is set;
#          SFHQ part 1 (89k faces, $FACE_LIMIT of them used)
# Env: MIN_FPS (default 150 a GPU, 4090 class) stops a pod that renders slower than budgeted; HOURS overrides the
# stage's target. Arms the deadline first, so even a failed install does not leave the pod billing.
set -euo pipefail
STAGE=$1 LIFE_S=$2
cd "$(dirname "$0")/../.."
R=$(pwd)
W=${SYNTH_WORK:-/workspace/synth}
[ "$STAGE" = stub ] && W=${SYNTH_WORK:-$R/data/synth/stub}
mkdir -p "$W"
log() { echo "$(date '+%F %T') $*"; }
log "bootstrap: stage $STAGE, life ${LIFE_S}s, work $W"

if [ "$STAGE" != stub ]; then
  nohup bash synth/pod/deadline.sh "$LIFE_S" "$W" > /workspace/synth_deadline.log 2>&1 < /dev/null &
  export DEBIAN_FRONTEND=noninteractive
  apt-get -qq update && apt-get -qq install -y ffmpeg aria2 unzip > /dev/null
  python3 -m pip -q install -r synth/pod/requirements.txt
  python3 -c "import torch; assert torch.cuda.is_available()" || { log "no CUDA torch"; exit 1; }
  PY=python3
else
  PY=${SYNTH_PY:-$R/work/synth/.venv/bin/python}
fi

# --- models (MuseTalk 1.5 UNet, sd-vae-ft-mse encoder, TAESD decoder, whisper-tiny) ---
MODELS=$W/models
[ "$STAGE" = stub ] && MODELS=$R/work/synth/models
$PY - "$MODELS" <<'EOF'
import os, sys
from huggingface_hub import hf_hub_download
d = sys.argv[1]
for repo, files, sub in [("TMElyralab/MuseTalk", ["musetalkV15/musetalk.json", "musetalkV15/unet.pth"], ""),
                         ("stabilityai/sd-vae-ft-mse", ["config.json", "diffusion_pytorch_model.safetensors"], "sd-vae"),
                         ("madebyollin/taesd", ["config.json", "diffusion_pytorch_model.safetensors"], "taesd"),
                         ("openai/whisper-tiny", ["config.json", "model.safetensors", "preprocessor_config.json"], "whisper")]:
    for f in files:
        if not os.path.exists(os.path.join(d, sub, f)):
            hf_hub_download(repo, f, local_dir=os.path.join(d, sub))
assert os.path.getsize(os.path.join(d, "musetalkV15", "unet.pth")) > 3_000_000_000, "unet.pth truncated"
EOF
log "models ready"

# --- faces and audio ---
HF=https://huggingface.co/datasets
SRC=()
case $STAGE in
  stub)
    FACES=$R/data/synth/src/faces/sfhq4; FACE_LIMIT=${FACE_LIMIT:-12}; HOURS=${HOURS:-0}; LIMIT=3
    SRC=("parquet:$R/data/synth/src/golos/*.parquet@golos" "parquet:$R/data/synth/src/ruls/*.parquet@ruls") ;;
  10h)
    FACES=$W/faces; FACE_LIMIT=${FACE_LIMIT:-0}; HOURS=${HOURS:-10}; LIMIT=0
    mkdir -p "$FACES" "$W/golos10" "$W/ruls"
    for z in small-sample-4.zip small-sample.zip; do
      [ -e "$FACES/$z.done" ] || { aria2c -q -x8 -d "$FACES" -o "$z" "$HF/bitmind/SyntheticFacesHQ/resolve/main/$z" \
        && unzip -q -j -o "$FACES/$z" '*.jpg' '*.png' -d "$FACES/${z%.zip}" ; rm -f "$FACES/$z"; touch "$FACES/$z.done"; }
    done
    for f in train-00000-of-00003-85be0fb4b3de87ab train-00001-of-00003-fcf1367484d8316d train-00002-of-00003-8e44cef5e8ee83d1; do
      [ -s "$W/golos10/$f.parquet" ] || aria2c -q -x8 -d "$W/golos10" -o "$f.parquet" \
        "$HF/bond005/sberdevices_golos_10h_crowd/resolve/main/data/$f.parquet"
    done
    for f in train-00000-of-00023-72d87f7fc46c617b train-00001-of-00023-ed27323519b5b2a6 train-00002-of-00023-a3620683b6f260db; do
      [ -s "$W/ruls/$f.parquet" ] || aria2c -q -x8 -d "$W/ruls" -o "$f.parquet" \
        "$HF/bond005/rulibrispeech/resolve/main/data/$f.parquet"
    done
    SRC=("parquet:$W/golos10/*.parquet@golos" "parquet:$W/ruls/*.parquet@ruls") ;;
  1000h)
    FACES=$W/faces; FACE_LIMIT=${FACE_LIMIT:-30000}; HOURS=${HOURS:-1000}; LIMIT=0
    mkdir -p "$FACES" "$W/ruls"
    [ -e "$FACES/part1.done" ] || { aria2c -q -x16 -d "$FACES" -o p1.zip "$HF/bitmind/SyntheticFacesHQ/resolve/main/SFHQ-part1.zip" \
      && unzip -q -o "$FACES/p1.zip" -d "$FACES/part1" && rm -f "$FACES/p1.zip" && touch "$FACES/part1.done"; }
    [ -e "$W/golos.done" ] || { aria2c -q -x16 -d "$W" -o golos_opus.tar https://cdn.chatwm.opensmodel.sberdevices.ru/golos/golos_opus.tar \
      && tar -xf "$W/golos_opus.tar" -C "$W" && rm -f "$W/golos_opus.tar" && touch "$W/golos.done"; }
    $PY - "$W" <<'EOF'
import json, sys
from huggingface_hub import list_repo_files, hf_hub_download
w = sys.argv[1]
for f in list_repo_files("bond005/rulibrispeech", repo_type="dataset"):
    if f.startswith("data/train-"):
        hf_hub_download("bond005/rulibrispeech", f, repo_type="dataset", local_dir=f"{w}/ruls")
EOF
    for m in $(find "$W/golos_opus" -name '*.jsonl' -path '*train*'); do SRC+=("golos:$m@golos"); done
    [ ${#SRC[@]} -gt 0 ] || { log "no Golos train manifest found under $W/golos_opus"; exit 1; }
    SRC+=("parquet:$W/ruls/data/*.parquet@ruls")
    if [ -n "${CV_TAR_URL:-}" ]; then  # the owner's Mozilla Data Collective link; the dataset must not be re-hosted
      [ -e "$W/cv.done" ] || { mkdir -p "$W/cv" && curl -sL "$CV_TAR_URL" | tar -xz -C "$W/cv" && touch "$W/cv.done"; }
      SRC+=("cv:$(dirname "$(find "$W/cv" -name validated.tsv | head -1)")@cv")
    fi ;;
  *) log "unknown stage $STAGE"; exit 1 ;;
esac
log "data ready: ${SRC[*]}"

OUT=$W/clips
GEN=(synth/gen.py --faces "$FACES" --face-limit "$FACE_LIMIT" --face-cache "$W/face_cache" --models "$MODELS" --out "$OUT")
for s in "${SRC[@]}"; do GEN+=(--source "$s"); done
NG=$(nvidia-smi -L 2>/dev/null | wc -l || echo 0)
[ "$STAGE" = stub ] && NG=1
[ "$NG" -gt 0 ] || { log "no GPU"; exit 1; }

# faces once (S3FD + FaceMesh + VAE encode), then one renderer per GPU over disjoint rows
$PY "${GEN[@]}" --prep-only > "$W/prep.log" 2>&1
log "$(grep '^faces:' "$W/prep.log" | tail -1)"
PER=$(python3 -c "print($HOURS / $NG if $HOURS else 0)")
for i in $(seq 0 $((NG - 1))); do
  EXTRA=()
  [ "$STAGE" = stub ] && EXTRA=(--limit $LIMIT --group 3 --batch 8 --keep-wav "$W/wav")
  [ "$STAGE" != stub ] && EXTRA=(--batch 64 --group 32 --writers 6)
  CUDA_VISIBLE_DEVICES=$i nohup $PY "${GEN[@]}" --part "$i/$NG" --max-hours "$PER" "${EXTRA[@]}" \
    > "$W/gen_$i.log" 2>&1 < /dev/null &
  echo $! > "$W/gen_$i.pid"
done
log "started $NG renderer(s), ${PER} h each"

# speed guard: model fps per GPU after the warm-up must match the budget, else stop before money is wasted
if [ "$STAGE" != stub ]; then
  sleep 600
  FPS=$(grep -ho '[0-9]* frames/s model' "$W"/gen_*.log | tail -"$NG" | awk '{s+=$1} END {print int(s / NR)}')
  log "speed after 10 min: ${FPS} frames/s a GPU (budget ${MIN_FPS:-150})"
  if [ "${FPS:-0}" -lt "${MIN_FPS:-150}" ]; then
    log "too slow: stopping the renderers"
    for p in "$W"/gen_*.pid; do kill "$(cat "$p")" 2>/dev/null || true; done
    touch "$W/STOP"
  fi
fi
wait
touch "$W/DONE"
log "renderers finished: $(ls "$OUT" | grep -c '\.json$') clips"
