#!/bin/bash
cd "$(dirname "$0")"
run() { python3 zeroshot.py "$@" 2>&1 | grep -v -i warn | head -12; echo ---; }
run qwen3-vl-plus vl_p1 --prompt 1
run qwen3-vl-plus vl_novideo --prompt 0 --novideo
run qwen3.5-omni-flash o35f_p1 --prompt 1
run qwen3.5-omni-plus o35p_p1 --prompt 1
run qwen3.8-omni-flash o38_p1_nothink --prompt 1
run qwen3.8-omni-flash o38_p0_think --prompt 0 --thinking --workers 8
run qwen3-vl-plus vl_p1_think --prompt 1 --thinking
