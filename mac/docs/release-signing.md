# Сборки для выпуска и подпись

У проекта пока нет Apple Developer ID, поэтому каждая сборка для macOS **подписана ad hoc** и не нотаризована, и
**автообновления нет** (обновлятор Sparkle из исходного проекта, его ленты appcast и адрес обновлений удалены).
Пользователь один раз открывает приложение через «Системные настройки → Конфиденциальность и безопасность» или
снимает флаг карантина (см. [README](../README.md)).

## Откуда берутся сборки

Весь CI лежит в корне репозитория, в `.github/workflows/`:

- [`build-apple.yml`](../../.github/workflows/build-apple.yml) собирает приложение для Mac и неподписанный IPA для
  iOS по запросу: метка `build` на pull request, тег `mac-v*` / `ios-v*` или ручной запуск. Минут на macOS мало,
  поэтому на обычные push он не запускается.
- [`release.yml`](../../.github/workflows/release.yml) запускается по тегу `v*`: вызывает `build-apple.yml` и создаёт
  **черновик** выпуска на GitHub с архивом приложения для Mac и IPA.

Задача для Mac собирает `velikiy-moguchiy-cli` и `mic-warm`, создаёт проект Xcode через XcodeGen, собирает
приложение без подписи (ядро на Rust собирает скрипт цели перед сборкой) и запускает
[`scripts/package-app.sh`](../scripts/package-app.sh). Тот кладёт CLI и `mic-warm` в
`VelikiyMoguchiy.app/Contents/MacOS/`, подписывает, проверяет и упаковывает приложение в
`VelikiyMoguchiy-macOS-arm64.zip`.

## Подпись Developer ID в будущем

`scripts/package-app.sh` уже умеет подписывать настоящим сертификатом. Если задан `CODESIGN_IDENTITY`, он
подписывает вложенный код, CLI, `mic-warm` и приложение с hardened runtime, защищённой меткой времени и
entitlements приложения (`MacApp/VelikiyMoguchiy/VelikiyMoguchiy.entitlements`); если заданы ещё `APPLE_ID`,
`APPLE_APP_PASSWORD` и `APPLE_TEAM_ID`, он нотаризует приложение и прикрепляет билет (staple) перед упаковкой.
Чтобы включить это в CI:

1. Экспортируйте сертификат «Developer ID Application: …» вместе с закрытым ключом из «Связки ключей» в `.p12` и
   сохраните его в base64 (`base64 -i DeveloperIDApplication.p12`) как секрет `MACOS_CERTIFICATE_P12`, а пароль —
   как `MACOS_CERTIFICATE_PASSWORD`.
2. Добавьте `APPLE_ID`, `APPLE_APP_PASSWORD` ([пароль для приложения](https://support.apple.com/102654)) и
   `APPLE_TEAM_ID`.
3. В `build-apple.yml` перед упаковкой импортируйте сертификат во временную связку ключей и задайте
   `CODESIGN_IDENTITY=Developer ID Application`; в конце задачи удалите связку.

Подписанная сборка сохраняет разрешения macOS между обновлениями (её «личность» больше не меняется с каждой
сборкой), и без неё нельзя вернуть автообновление.
