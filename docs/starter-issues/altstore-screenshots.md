---
title: Скриншоты клавиатуры для источника AltStore
labels: good first issue,documentation
---

IPA для iPhone публикуется в источнике AltStore и SideStore (`docs/altstore/source.json`, его собирает
[`tools/altstore/source.py`](https://github.com/zigansh1n/velikiy-moguchiy/blob/main/tools/altstore/source.py)). Там пока нет ни одного скриншота, а без них
приложение в каталоге выглядит пустым.

**Что сделать.**

1. Снять 3–4 скриншота iPhone: клавиатура RU, клавиатура во время диктовки, экран настроек приложения. Без
   личных данных и ключей на экране.
2. Положить их PNG в `ios/screenshots/altstore/`.
3. В `source.py` заполнить `screenshots` ссылками вида
   `https://raw.githubusercontent.com/zigansh1n/velikiy-moguchiy/main/ios/screenshots/altstore/1.png`
   и поправить `selftest`, если нужно.

**Как проверить.** `python3 tools/altstore/source.py selftest` и `python3 tools/privacy_guard.py` проходят;
`python3 tools/altstore/source.py --print` показывает ссылки на скриншоты.
