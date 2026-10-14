---
title: Диктовка для Linux (X11 и Wayland)
labels: help wanted,enhancement
---

Диктовка для рабочего стола Linux: глобальная клавиша, запись, распознавание, вставка текста в активное окно.

**Что уже есть.** Rust-ядро в [`mac/`](https://github.com/zigansh1n/velikiy-moguchiy/tree/main/mac/) (`velikiy-moguchiy-asr`, `velikiy-moguchiy-core`,
`velikiy-moguchiy-cli`) уже собирается и проходит тесты на Linux в CI — задание «Rust core (Linux)» в
[`.github/workflows/tests.yml`](https://github.com/zigansh1n/velikiy-moguchiy/blob/main/.github/workflows/tests.yml). `velikiy-moguchiy-cli transcribe` распознаёт
файл (нужен `ffmpeg`), так что основа есть. Как обернуть ядро в приложение для рабочего стола, видно по
[`windows/`](https://github.com/zigansh1n/velikiy-moguchiy/tree/main/windows/): логика приложения (сессия, жесты клавиши,
звук, настройки) отделена от вызовов Windows (`windows/win32`) и тестируется на любой ОС.

**Что сделать.**

1. Оболочку, которая записывает звук (PipeWire или PulseAudio), отдаёт его ядру и вставляет результат:
   на X11 — через `xdotool`/XTest, на Wayland — через `wtype`, `ydotool` или портал `RemoteDesktop`.
2. Глобальную клавишу: на Wayland это зависит от окружения (GNOME, KDE), опишите, что поддерживается.
3. Папку `linux/` со своим README и командой сборки.

**Как проверить.** Диктовка в терминале и в браузере хотя бы в одном окружении на X11 и одном на Wayland; в PR
напишите, где проверяли.
