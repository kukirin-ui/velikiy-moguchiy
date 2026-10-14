#!/bin/bash
cd "$(dirname "$0")"
while pgrep -f run_zs.sh >/dev/null; do sleep 5; done
run() { python3 zeroshot.py "$@" 2>&1 | grep -v -i warn | head -8; echo ---; }
run qwen3-vl-plus vl_slow --prompt 1 --slow
run qwen3.5-plus q35p_slow --prompt 1 --slow
run qwen3.5-flash q35f_slow --prompt 1 --slow
run qwen3.7-plus q37p_slow --prompt 1 --slow
run qwen3.8-omni-flash o38_slow --prompt 1 --slow
