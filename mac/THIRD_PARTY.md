# Сторонний код и спецификации

## giga-pisar (MIT) — перенесённый код

Источник: https://github.com/moznoazachem/giga-pisar (коммиты cc15efd, 9cf1def).
Используется в `MacApp/VelikiyMoguchiy/Clipboard/SPClipboardManager.m` и `MacApp/VelikiyMoguchiy/main.m`:

- чтение буфера обмена для резервной копии в одноразовом дочернем процессе исполняемого файла приложения
  с жёстким сроком и пределом 16 МиБ (переписано на Objective-C);
- правило скрытых элементов (`org.nspasteboard.ConcealedType` никогда не копируется в резервную копию и не
  восстанавливается) и пометки временного содержимого на временных вставках.

```
MIT License

Copyright (c) 2026 moznoazachem

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## OpenLess (AGPL-3.0) — только как спецификация, код не копировался

Источник: https://github.com/openless-ai/openless. Его поведение прочитано как спецификация и реализовано
независимо:

- 6a7cd5f: клавиша-модификатор, зажатая вместе с другой клавишей или системной клавишей функционального ряда
  (Fn+яркость/громкость), не запускает диктовку (`SPHotkeyMonitor.m`);
- 6efc839: перенос строки в терминалах вводится как перевод строки, а не Shift+Return
  (`velikiy-moguchiy-core/src/unicode_typing.rs`). Ранняя версия этого файла называла себя производной от
  `unicode_keystroke.rs` из OpenLess; к открытому выпуску (v0.1) модуль переписан с нуля: сначала составлено
  письменное описание поведения, которое нужно вызывающему коду (интерфейс, семантика нажатий клавиш и
  универсального доступа, тесты), и новый модуль написан только по этому описанию, без старого кода;
- af9eaa3: подключение к хосту распознавания сначала по IPv4 (`velikiy-moguchiy-asr/src/net_connect.rs`);
- `silence_auto_stop.rs`: идея завершать запись без рук через несколько секунд после последней речи (уровни
  против порога, таймер запускается только после того, как речь прозвучала).
  `velikiy-moguchiy-core/src/silence.rs` — независимая реализация на RMS с оценкой уровня шума.

## Только как спецификация, код не копировался

Голосовые команды (`velikiy-moguchiy-core/src/commands.rs`) и сниппеты (`velikiy-moguchiy-core/src/snippets.rs`)
повторяют поведение Wispr Flow, Apple Dictation и `src/utils/snippets.ts` из OpenWhispr (MIT): сравнение без учёта
регистра, сначала самый длинный триггер. Русская грамматика команд и протокол пометок с моделью Omni — наши;
код из этих проектов не брался.
Кнопка мыши как клавиша диктовки (`SPHotkeyMonitor.m`) — обычный CGEventTap на событиях дополнительных кнопок мыши;
`mouse_dictation.rs` из OpenLess (AGPL) не читался.
