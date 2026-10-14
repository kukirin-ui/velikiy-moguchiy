#!/usr/bin/env bash
# Ночной цикл: новые клипы -> манифест и признаки -> обучение LoRA (до 240 минут) -> оценка на 50 тестовых клипах
# -> results/finetune-<дата>.md. Расписание НЕ ставится: запускайте руками (например, на ночь).
#
#   ./nightly.sh                      обычный запуск
#   MAX_MINUTES=60 ./nightly.sh       короче (лимит времени обучения)
#   TRAIN_ARGS="--mix silent=1" ./nightly.sh      дополнительные ключи train.py
#   RUN=my-run ./nightly.sh           имя запуска (по умолчанию nightly-<дата>; повторный запуск в тот же день ПРОДОЛЖАЕТ его)
#
# Память: каждый этап с моделью идёт под общим охранником ../tools/mem_guard.py (бюджет MPS = доступная память
# минус 6 ГБ, пауза SIGSTOP при росте свопа > 512 МБ или свободной памяти < 15%, потом продолжение), пустой кэш MPS
# регулярно, один процесс с моделью одновременно (этапы строго по очереди), nice 10. Лимит --max-minutes считается по
# АКТИВНОМУ времени (паузы охранника не в счёт), поэтому общее время ночи может быть больше.
# caffeinate -i не даёт Mac уснуть от простоя (крышку ноутбука закрывать нельзя, питание держите подключённым).
set -euo pipefail
cd "$(dirname "$0")"

if [[ -z "${LIPREAD_CAFFEINATED:-}" ]]; then
  export LIPREAD_CAFFEINATED=1
  exec caffeinate -i "$0" "$@"
fi

export PYTORCH_ENABLE_MPS_FALLBACK=1
GUARD=(python3 ../tools/mem_guard.py --)
[[ -x ../tools/mem_guard.py ]] || { echo "нет ../tools/mem_guard.py"; exit 2; }
export PYTHONIOENCODING=utf-8

DATE=$(date +%F)
RUN="${RUN:-nightly-$DATE}"
MAX_MINUTES="${MAX_MINUTES:-240}"
TRAIN_ARGS="${TRAIN_ARGS:-}"
mkdir -p logs results checkpoints
LOG="logs/nightly-$DATE.log"
exec > >(tee -a "$LOG") 2>&1

echo "=== nightly $(date '+%F %T'), run=$RUN, лимит обучения ${MAX_MINUTES} мин ==="

# не запускать два экземпляра одновременно
LOCK="work/nightly.lock"
mkdir -p work
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "Уже идёт другой nightly (удалите $LOCK, если это не так)"; exit 2
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

step() { echo; echo "--- $1 ($(date '+%T')) ---"; }

step "0. проверка памяти"
uv run python memguard.py --check || { echo "мало свободной памяти, не запускаю"; exit 3; }

step "1. манифест и признаки (dataset.py)"
"${GUARD[@]}" nice -n 10 ./run.sh dataset.py

step "2. обучение (train.py)"
set +e
"${GUARD[@]}" nice -n 10 ./run.sh train.py --run "$RUN" --resume --max-minutes "$MAX_MINUTES" $TRAIN_ARGS
RC=$?
set -e
if [[ $RC -ne 0 ]]; then
  echo "train.py завершился с кодом $RC (3 = мало памяти). Оценку не запускаю."
  exit $RC
fi

step "3. оценка на 50 тестовых клипов (evaluate.py)"
OUT="results/finetune-$DATE.md"
"${GUARD[@]}" nice -n 10 ./run.sh evaluate.py --lora "checkpoints/$RUN/best.pt" --out "$OUT" | tee "work/nightly-eval.log"
grep '^SUMMARY' "work/nightly-eval.log" >> results/finetune-history.txt || true

echo
echo "=== готово $(date '+%F %T'): $OUT ; лог $LOG ; адаптеры checkpoints/$RUN/best.pt ==="
