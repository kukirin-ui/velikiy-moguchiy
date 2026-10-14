---
title: Клавиатура Android в F-Droid и Google Play
labels: help wanted,enhancement
---

Сейчас клавиатуру для Android ставят APK со страницы релизов
([`android/README.md`](https://github.com/zigansh1n/velikiy-moguchiy/blob/main/android/README.md)). Через каталог её проще найти и обновлять.

**Что сделать.**

1. **F-Droid.** Проверить, что сборка не тянет несвободных зависимостей и собирается из исходников без секретов.
   Добавить описание, скриншоты и список изменений в формате, который читает F-Droid
   (`android/fastlane/metadata/android/ru-RU/`), и подготовить метаданные для запроса в
   [fdroiddata](https://gitlab.com/fdroid/fdroiddata). Тексты — на русском.
2. **Google Play.** Сборка App Bundle (`.aab`) в `.github/workflows/build-android.yml`, подписанная, только если
   заданы секреты (как сейчас APK). Ответы для раздела «Безопасность данных»: звук уходит провайдеру
   распознавания, ключ хранится в Android Keystore — по [`PRIVACY.md`](https://github.com/zigansh1n/velikiy-moguchiy/blob/main/PRIVACY.md).
3. Короткая инструкция в `android/README.md`: что делает CI, что остаётся сделать вручную в консолях каталогов.

**Как проверить.** `fdroid build` (или `fdroid lint`) проходит на метаданных; CI собирает `.aab` без секретов
и с ними. Отправку в каталоги делает тот, у кого есть доступ к аккаунтам, — PR её не требует.
