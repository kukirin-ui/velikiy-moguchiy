# Homebrew для «Великий & Могучий»

Установка диктовки для macOS одной командой (Mac на Apple Silicon, macOS 14 или новее):

```bash
brew install --cask zigansh1n/tap/velikiy-moguchiy
```

Обновление:

```bash
brew upgrade --cask velikiy-moguchiy
```

Удаление:

```bash
brew uninstall --cask velikiy-moguchiy
```

Сборка не подписана сертификатом Apple, поэтому формула снимает с приложения карантин сама. Разрешения
(микрофон, универсальный доступ, мониторинг ввода) после обновления может понадобиться выдать заново — подробнее в
[`mac/README.md`](https://github.com/zigansh1n/velikiy-moguchiy/blob/main/mac/README.md).

Это служебный репозиторий: его файлы собираются автоматически из
[`tools/homebrew/`](https://github.com/zigansh1n/velikiy-moguchiy/tree/main/tools/homebrew) основного репозитория
при каждом опубликованном релизе. Править формулу нужно там, а не здесь.
