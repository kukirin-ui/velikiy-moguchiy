---
title: Режим «губы» на Windows
labels: help wanted,enhancement
---

На Mac есть экспериментальный режим чтения по губам: пока зажата клавиша, приложение пишет видео с камеры и
отдаёт его локальному сервису с моделью MultiVSR. В приложении для Windows ([`windows/`](https://github.com/zigansh1n/velikiy-moguchiy/tree/main/windows/))
этого режима пока нет.

**Что уже есть.** План по шагам — [`windows/LIPREAD.md`](https://github.com/zigansh1n/velikiy-moguchiy/blob/main/windows/LIPREAD.md): что поменять в
сервисе [`lipread/lips_service.py`](https://github.com/zigansh1n/velikiy-moguchiy/blob/main/lipread/lips_service.py) (память, CUDA, проверка
родительского процесса, ffmpeg, установка через `uv`) и что добавить в приложение (камера через Media Foundation,
клавиша `hotkey.lips_key`, запуск сервиса, вставка результата).

**Что сделать.**

1. Запустить сервис под Windows: ветка для `_alive()` без `os.kill` (на Windows он завершает процесс),
   замеры памяти без `vm_stat` и `sysctl`, `setup.ps1` вместо `setup.sh`.
2. Запись клипа с камеры в приложении и запрос к сервису по тому же HTTP-протоколу, что на Mac.
3. Включение режима флагом `experimental.lips`, как на Mac, и честное предупреждение в настройках о скорости
   без видеокарты NVIDIA.

**Как проверить.** Фраза, сказанная беззвучно, распознаётся на компьютере с NVIDIA; в PR напишите видеокарту и
время распознавания. Код и веса MultiVSR скачиваются у авторов на компьютер пользователя, в репозиторий и в
сборки они не попадают.
