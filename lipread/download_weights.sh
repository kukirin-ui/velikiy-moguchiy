#!/usr/bin/env bash
# Скачивает веса MultiVSR (всего около 4,5 ГБ = 4,15 ГиБ) в weights/.
# Докачивает при обрыве (curl -C -), проверяет размер по Content-Length.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p weights

fetch() {  # url dest
  local url="$1" dest="$2" want have
  want=$(curl -sIL "$url" | awk 'tolower($1)=="content-length:" {gsub("\r","",$2); n=$2} END{print n}')
  echo "== $dest: ожидается $want байт"
  curl -L --fail -C - -o "$dest" "$url"
  have=$(stat -f%z "$dest")
  [ "$have" = "$want" ] || { echo "Размер $have != $want, файл повреждён, запустите ещё раз"; exit 1; }
}

fetch https://www.robots.ox.ac.uk/~vgg/research/multivsr/model.pth weights/model.pth                                   # 3 374 308 500 байт
fetch https://www.robots.ox.ac.uk/~vgg/research/vtp-for-lip-reading/checkpoints/extended_train_data/feature_extractor.pth weights/feature_extractor.pth  # 1 079 529 003 байт
echo "Готово: weights/model.pth, weights/feature_extractor.pth"
