#!/usr/bin/env bash
# Скачивает веса MultiVSR (всего около 4,5 ГБ = 4,15 ГиБ) в weights/.
# Докачивает при обрыве (curl -C -), проверяет размер по Content-Length.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p weights

fetch() {  # url dest sha256 (тот же, что закреплён в приложении: SPLipsRuntimePolicy.m)
  local url="$1" dest="$2" sha="$3" want have
  want=$(curl -sIL "$url" | awk 'tolower($1)=="content-length:" {gsub("\r","",$2); n=$2} END{print n}')
  echo "== $dest: ожидается $want байт"
  curl -L --fail -C - -o "$dest" "$url"
  have=$(stat -f%z "$dest")
  [ "$have" = "$want" ] || { echo "Размер $have != $want, файл повреждён, запустите ещё раз"; exit 1; }
  echo "$sha  $dest" | shasum -a 256 -c --status || { echo "SHA-256 $dest не совпал: удалите файл и запустите ещё раз"; exit 1; }
}

fetch https://www.robots.ox.ac.uk/~vgg/research/multivsr/model.pth weights/model.pth \
  cd89f095cb3c653bacea5d18155b2235d78f9c36bd001db7aef60cca2a0cbf2c                                                       # 3 374 308 500 байт
fetch https://www.robots.ox.ac.uk/~vgg/research/vtp-for-lip-reading/checkpoints/extended_train_data/feature_extractor.pth weights/feature_extractor.pth \
  3c822d0ec5a6d3f9abd9f2aac86eb73ec6af0eb8795bc7438ec205013a97125c                                                       # 1 079 529 003 байт
echo "Готово: weights/model.pth, weights/feature_extractor.pth"
