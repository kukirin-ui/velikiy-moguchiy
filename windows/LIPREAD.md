# Чтение по губам на Windows — набросок этапа 2

Пока не сделано. Здесь — как запустить `lipread/lips_service.py` под Windows и подключить его к приложению.

## Как это работает на Mac

Приложение держит клавишу `hotkey.lips_key`, пишет видео с камеры (MP4, 25 к/с, без звука) и отправляет путь к
файлу локальному сервису: `POST http://127.0.0.1:8766/transcribe {"path", "rescore", "context"}`. Сервис —
Python-процесс из `lipread/` с загруженной моделью MultiVSR (+ LoRA пользователя). Он завершается сам после
`--idle-sec` без запросов или когда умирает `--parent-pid`, и так освобождает память; приложение запускает его
заново при следующем клипе. Протокол HTTP + JSON на 127.0.0.1 переносится без изменений.

## Что поменять в сервисе

Код сервиса почти кроссплатформенный (`http.server`, `threading`, `torch`), но есть Mac-специфичные места:

- **Память.** `available_gb()`, `swap_used_mb()` и `rss_gb()` вызывают `vm_stat`, `sysctl` и `ps`. Под Windows —
  `psutil.virtual_memory().available`, `psutil.swap_memory().used`, `psutil.Process().memory_info().rss`
  (или `GlobalMemoryStatusEx` через `ctypes`, чтобы не тянуть зависимость). Проверка `--min-avail-gb` остаётся.
- **Устройство.** `mvsr.pick_device` уже выбирает `cuda → mps → cpu`. На Windows это CUDA на NVIDIA (fp16 включается
  сам) или процессор. Переменные `PYTORCH_MPS_*` и `memguard.mps_cleanup()` там ни на что не влияют;
  для CUDA нужен аналог — `torch.cuda.empty_cache()` после клипа.
- **Проверка родителя.** `_alive()` вызывает `os.kill(pid, 0)`. На Windows это **не проверка, а
  `TerminateProcess`**: сервис убил бы приложение. Нужна ветка для Windows: `OpenProcess` +
  `GetExitCodeProcess` через `ctypes` или `psutil.pid_exists`.
- **ffmpeg** вызывается из `preprocess.py` по имени: его надо положить рядом (`ffmpeg.exe`) или искать в `PATH`.
- **Окружение.** `setup.sh` и пути `.venv/bin/python` — для macOS. Для Windows нужен `setup.ps1` на `uv`
  (`uv venv`, `uv sync`; `.venv\Scripts\python.exe`), колёса `torch` с CUDA или CPU, `opencv-python`, `scipy`.
  Код и веса MultiVSR, как и на Mac, скачиваются у авторов на компьютер пользователя (лицензия MultiVSR не указана,
  проект их не распространяет).

## Что сделать в приложении

- **Камера:** Media Foundation (`IMFSourceReader` → `IMFSinkWriter`, H.264, 25 к/с) в отдельном потоке, как микрофон
  в `win32/src/mic.rs`. Пока клавиша нажата, кадры пишутся во временный MP4 в `%TEMP%`.
- **Клавиша:** `hotkey.lips_key` по образцу `windows.trigger_key`; жест «удерживать» уже есть в `hotkey.rs`.
- **Сервис:** запуск `python lips_service.py --port 8766 --parent-pid <pid>` скрытым процессом
  (`CREATE_NO_WINDOW`), путь к checkout — `lips.service_dir` из общего `config.yaml`; запрос через тот же
  `reqwest`, что уже есть в ядре. Плашка показывает «Загружаю модель…», пока `/health` не скажет `loaded`.
- **Результат** вставляется тем же путём, что и диктовка (`Host::paste`), а флаг `experimental.lips` включает режим,
  как на Mac.

Главный вопрос — производительность: на процессоре без CUDA фраза в 8 секунд может распознаваться десятки секунд.
Начать стоит с компьютеров с NVIDIA и честно предупреждать об этом в настройках.
