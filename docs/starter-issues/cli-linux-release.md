---
title: Сборка velikiy-moguchiy-cli для Linux в релизе
labels: good first issue,enhancement
---

`velikiy-moguchiy-cli` (распознавание файла, словарь, бенчмарк провайдеров) не зависит от macOS, но в релизе есть
только приложения для Mac, iPhone, Android и Windows, а сборки для Linux нет.

**Что сделать.** В [`.github/workflows/release.yml`](https://github.com/zigansh1n/velikiy-moguchiy/blob/main/.github/workflows/release.yml) добавить задание на
`ubuntu-latest`, которое собирает `cargo build --release -p velikiy-moguchiy-cli` для `x86_64-unknown-linux-gnu`,
упаковывает бинарник в `velikiy-moguchiy-cli-linux-x86_64.tar.gz` и добавляет его к черновику релиза вместе с
контрольной суммой в `SHA256SUMS.txt`. В [`mac/README.md`](https://github.com/zigansh1n/velikiy-moguchiy/blob/main/mac/README.md) — пара строк, как этим
пользоваться.

**Как проверить.** Запустите workflow в своём форке с тегом вида `v0.0.0-test` и приложите к PR ссылку на
получившийся черновик релиза. На чистой Ubuntu `./velikiy-moguchiy-cli --help` должен работать без дополнительных
библиотек.
