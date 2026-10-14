#!/bin/bash
# Pod side of harvester/lipsasr_pod.sh: the model stages of whisper_eval.py --set voiced (GigaAM, lip n-best by base
# MultiVSR and me1) on the pod GPU. Resumes from the transcripts already in work/lipsasr/voiced. Ends with POD_DONE or
# POD_FAILED in that folder.
cd "$(dirname "$0")/../.."
W=work/lipsasr/voiced
rm -f $W/POD_DONE $W/POD_FAILED
trap 'touch $W/POD_FAILED' ERR
set -eE -o pipefail
echo "$(date '+%F %T') lipsasr: start"

command -v ffmpeg > /dev/null || { apt-get -qq update && apt-get -qq install -y ffmpeg > /dev/null; }
python3 -c "import torch; assert torch.cuda.is_available()" || { echo "no CUDA torch"; false; }
python3 -m pip -q install -r harvester/pod/requirements.txt
python3 -c "import gigaam" 2> /dev/null || python3 -m pip -q install --no-deps git+https://github.com/salute-developers/GigaAM.git

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

export MVSR_PRE_DEVICE=cuda PYTHONIOENCODING=utf-8
python3 whisper_eval.py --set voiced gpu
touch $W/POD_DONE
echo "$(date '+%F %T') lipsasr: done"
