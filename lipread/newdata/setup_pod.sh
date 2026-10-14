#!/bin/bash
# разовая подготовка пода: venv (поверх системных пакетов), mediapipe/silero/GigaAM. Код и веса копируются отдельно (scp).
set -e
mkdir -p /root/newdata/logs /root/newdata/weights /root/newdata/work/tmp
cd /root/newdata
[ -d venv ] || python3 -m venv --system-site-packages venv
venv/bin/pip install -q mediapipe==0.10.21 silero-vad soundfile python_speech_features hydra-core omegaconf sentencepiece pydub tqdm onnx onnxruntime
rm -rf /tmp/GigaAM; git clone -q --depth 1 https://github.com/salute-developers/GigaAM.git /tmp/GigaAM
venv/bin/pip install -q --no-deps /tmp/GigaAM
venv/bin/python -c "import mediapipe, silero_vad, gigaam, soundfile, python_speech_features; print('SETUP_OK')"
