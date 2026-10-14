#!/bin/bash
# Pod side of harvester/framing_pod.sh: test WER of base MultiVSR, me1 and e2e_full on three crops of the 50 test clips
# (work/faces = S3FD as MultiVSR, work/faces_s3fd720 = the same box without the JPEG step, work/faces_s3fd480 = the same
# box on frames decoded at 480p). One model at a time on the GPU. Reports: results/framing/cuda/<model>_<crop>.md/.json.
# Ends with POD_DONE or POD_FAILED in results/framing/cuda; rerunning skips the reports already written.
cd "$(dirname "$0")/../.."
O=results/framing/cuda
mkdir -p $O
rm -f $O/POD_DONE $O/POD_FAILED
trap 'touch $O/POD_FAILED' ERR
set -eE -o pipefail
echo "$(date '+%F %T') framing: start"

command -v ffmpeg > /dev/null || { apt-get -qq update && apt-get -qq install -y ffmpeg > /dev/null; }
python3 -c "import torch; assert torch.cuda.is_available()" || { echo "no CUDA torch"; false; }
python3 -m pip -q install -r harvester/pod/requirements.txt

get() {  # url dest bytes: the collector pods carry only feature_extractor.pth, model.pth comes from Oxford directly
  [ "$(stat -L -c%s "$2" 2> /dev/null)" = "$3" ] && return
  command -v aria2c > /dev/null && aria2c -q -x16 -s16 -k1M -d "$(dirname "$2")" -o "$(basename "$2")" --allow-overwrite=true "$1" \
    || curl -L --fail -o "$2" "$1"
  [ "$(stat -L -c%s "$2")" = "$3" ] || { echo "$2: size mismatch"; false; }
}
mkdir -p weights
for f in model.pth feature_extractor.pth; do  # a collector pod already holds some weights in /root/lr
  [ -e weights/$f ] || [ ! -s /root/lr/weights/$f ] || ln -s /root/lr/weights/$f weights/$f
done
get https://www.robots.ox.ac.uk/~vgg/research/multivsr/model.pth weights/model.pth 3374308500
get https://www.robots.ox.ac.uk/~vgg/research/vtp-for-lip-reading/checkpoints/extended_train_data/feature_extractor.pth \
  weights/feature_extractor.pth 1079529003

export PYTHONIOENCODING=utf-8
C=results/pod_runs/t1/checkpoints
for crop in s3fd s3fd720 s3fd480; do
  faces=work/faces; [ $crop = s3fd ] || faces=work/faces_$crop
  [ "$(ls $faces/*.avi | wc -l)" = 50 ] || { echo "$faces: expected 50 crops"; false; }
  for model in base me1 e2e_full; do
    out=$O/${model}_$crop.md
    [ -s ${out%.md}.json ] && continue
    lora=(); [ $model = base ] || lora=(--lora $C/$model/best.pt --venc-ckpt $C/$model/best_venc.pth --baseline-json $O/base_$crop.json)
    python3 evaluate.py --device cuda --faces $faces "${lora[@]}" --out $out --note "Кадрирование: $crop" > ${out%.md}.log 2>&1
    echo "$(date '+%F %T') $model $crop: $(grep '^WER' ${out%.md}.log | head -1)"
  done
done
touch $O/POD_DONE
echo "$(date '+%F %T') framing: done"
