# Сторонний код и источники

Часть «Великого & Могучего» (Velikiy Moguchiy) для iPhone построена на примере под лицензией Apache-2.0 и использует
порт клавиатуры под MIT. В репозитории нет ничего из KeyboardKit 10/11 (закрытый бинарный пакет) и нет кода под
PolyForm-Noncommercial или лицензиями «только для личного использования» (Jot Mobile, OSGKeyboard).

## Код в этом репозитории

| Источник | Лицензия | Что взято |
| --- | --- | --- |
| [LyalinDotCom/GeminiKeyboardSample](https://github.com/LyalinDotCom/GeminiKeyboardSample) | Apache-2.0 (`LICENSE` без изменений) | Весь базовый проект: приложение, которое держит «тёплую» сессию микрофона, протокол ретранслятора через App Group (`Shared/Relay`), `AudioCaptureEngine`, хранилища восстановления и истории, оболочка приложения на SwiftUI, контроллер клавиатуры на UIKit и его тесты. |
| KeyboardKit 9.9.1 (через порт из примера) | MIT, Copyright (c) 2016-2025 Daniel Saidi (полный текст в `THIRD_PARTY_NOTICES.md`) | Идеи и части кода клавиш, всплывающих панелей и состояний касаний в `KeyboardExtension/KeyboardKitPort` и `Shared/Keyboard`. |
| [KeyboardKit](https://github.com/KeyboardKit/KeyboardKit) 9.9.1 как Swift-пакет (последний выпуск под MIT; 10.0 и новее закрыты) | MIT, то же уведомление | Только в сборке для сравнения (схема `VelikiyMoguchiyKK`, `dist/VelikiyMoguchiy-KK-*.ipa`): клавиши клавиатур «Великий & Могучий KK RU/EN» (`KeyboardExtension/KeyboardKitVariant`). KeyboardKit Pro не используется. |

### Изменения в базе под Apache-2.0 (п. 4(b) лицензии)

- Клиент Gemini Live и пакетный клиент заменены клиентом DashScope Qwen-Omni realtime (`App/DashScope`).
- Убраны Live Activity основы, распознавание текста с камеры, перевод и пакетный и OCR-клиенты Gemini. Позже
  в проект снова добавлена Live Activity «тёплого» микрофона (`LiveActivity/`, `Widgets/`).
- Две клавиатуры (Великий & Могучий RU и Великий & Могучий EN) вместо одной; русская раскладка ЙЦУКЕН; сетка клавиш,
  цвета, размеры глифов, всплывающие панели и панель акцентов переписаны под системную клавиатуру iOS 26, замеренную
  в симуляторе.
- Минимальная версия снижена с iOS 27 до iOS 26.0; убран `isolated deinit`.
- Добавлен резервный канал связи через буфер обмена и уведомления Darwin для сборок без рабочего App Group
  (`Shared/Relay/RelayTransport.swift`).
- Строки интерфейса переведены на русский.

## Источники, использованные только как документация (код не копировался)

- [hoobnn/livetranslate-bridge](https://github.com/hoobnn/livetranslate-bridge) (MIT): устройство клиента
  `/api-ws/v1/realtime` (заголовок Bearer, `session.update`, PCM в base64).
- [n0an/VivaDicta](https://github.com/n0an/VivaDicta) (MIT) и [writingmate/aidictation](https://github.com/writingmate/aidictation)
  (MIT): рассматривались для русской раскладки; итоговая раскладка (ЙЦУКЕН, `ё`/`ъ` по долгому нажатию) снята
  с самой системной клавиатуры iOS 26 в симуляторе.
- Документация Apple по `UIInputViewController` (`needsInputModeSwitchKey`, `handleInputModeList(from:with:)`,
  `primaryLanguage`).
