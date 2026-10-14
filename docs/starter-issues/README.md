# Задачи для новых участников

Продолжение работы над версиями для Windows и Android, порт на Linux и несколько простых задач с понятной проверкой.
Они выкладываются как issues по мере готовности. В начале каждого файла — заголовок и ярлыки.

| Файл | Задача | Ярлыки |
|---|---|---|
| [`windows-lipread.md`](windows-lipread.md) | Режим «губы» на Windows | help wanted |
| [`windows-installer.md`](windows-installer.md) | Установщик и подпись приложения для Windows | help wanted |
| [`android-lipread.md`](android-lipread.md) | Чтение по губам для клавиатуры Android — исследование | help wanted |
| [`android-store.md`](android-store.md) | Клавиатура Android в F-Droid и Google Play | help wanted |
| [`linux-port.md`](linux-port.md) | Диктовка для Linux (X11 и Wayland) | help wanted |
| [`cli-linux-release.md`](cli-linux-release.md) | Сборка `velikiy-moguchiy-cli` для Linux в релизе | good first issue |
| [`demo-gif.md`](demo-gif.md) | Короткое демо для README | good first issue |
| [`link-check.md`](link-check.md) | Проверка ссылок в документации в CI | good first issue |
| [`altstore-screenshots.md`](altstore-screenshots.md) | Скриншоты клавиатуры для источника AltStore | good first issue |

Открыть одну задачу (заголовок и ярлыки берутся из файла):

```bash
f=docs/starter-issues/link-check.md; gh issue create -R zigansh1n/velikiy-moguchiy --title "$(sed -n 's/^title: //p' "$f")" --label "$(sed -n 's/^labels: //p' "$f")" --body "$(awk 'n >= 2; /^---$/ { n++ }' "$f")"
```

Ярлыки «good first issue» и «help wanted» создаёт workflow «Labels» ([`tools/labels/`](../../tools/labels/)).
