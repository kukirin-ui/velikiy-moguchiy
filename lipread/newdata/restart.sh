#!/bin/bash
# /root/newdata/restart.sh [procs]: жёсткий перезапуск сборщика (текущие ролики теряются, готовые клипы остаются)
cd /root/newdata
pkill -f "[r]v_collect.py run"; sleep 3
for d in work/tmp/*; do rm -rf "$d"; done
python3 - <<'PY'
import sqlite3
c=sqlite3.connect("/root/newdata/rv_state.db",timeout=30)
c.execute("UPDATE videos SET status='s1_ok' WHERE status IN ('claimed','inflight')"); c.commit()
PY
./start.sh ${1:-6} ${2:-0/1}
