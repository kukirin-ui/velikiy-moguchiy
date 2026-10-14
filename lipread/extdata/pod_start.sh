#!/bin/bash
# /root/extdata/pod_start.sh [procs]: installs language ID once and starts pod_segments.py detached.
# Needs the collector's GPU servers (newdata/start.sh with the same GPUN). Stop: touch /root/newdata/inbox_seg/STOP
cd /root/newdata
if ! venv/bin/python -c "import speechbrain" 2>/dev/null; then
  # pinning torch keeps pip from replacing the image's CUDA build while it pulls torchaudio
  T=$(venv/bin/python -c "import torch; print(torch.__version__.split('+')[0])")
  venv/bin/pip install -q -r /root/extdata/pod_requirements.txt "torch==$T" > logs/ext_setup.log 2>&1
fi
venv/bin/python -c "import speechbrain, torch; assert torch.cuda.is_available()" || { echo EXT_SETUP_FAILED; exit 1; }
if pgrep -f "[p]od_segments.py" > /dev/null; then echo EXT_RUNNING; exit 0; fi
mkdir -p inbox_seg; rm -f inbox_seg/STOP
RV_GPU_N=${GPUN:-3} setsid nohup venv/bin/python /root/extdata/pod_segments.py --procs ${1:-6} \
  >> logs/segments.log 2>&1 < /dev/null &
echo EXT_STARTED
