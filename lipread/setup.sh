#!/usr/bin/env bash
# Установка: код MultiVSR у авторов (закреплённый коммит) + наши правки под Apple Silicon + окружение uv.
# Кода MultiVSR в репозитории нет (у него нет лицензии): он клонируется с GitHub авторов, а
# multivsr_compat.py правит эту локальную копию на вашей машине.
# Веса моделей НЕ скачиваются, для них отдельный скрипт download_weights.sh.
set -euo pipefail
cd "$(dirname "$0")"
COMMIT=af28d8c4b687ee7e41942732eb240e0cdfff3ccd

command -v uv >/dev/null || { echo "Нужен uv: brew install uv"; exit 1; }
command -v ffmpeg >/dev/null || { echo "Нужен ffmpeg: brew install ffmpeg"; exit 1; }

if [ ! -d multivsr/.git ]; then
  git init -q multivsr
  git -C multivsr remote add origin https://github.com/Sindhu-Hegde/multivsr
  git -C multivsr fetch -q --depth 1 origin "$COMMIT"
  git -C multivsr checkout -q FETCH_HEAD
fi
python3 multivsr_compat.py multivsr || echo "Правки под MPS не применены полностью (см. сообщения выше); multivsr/ изменён вручную?"
uv sync
echo "Готово. Проверка: ./run.sh record.py --help && ./run.sh evaluate.py --help"
