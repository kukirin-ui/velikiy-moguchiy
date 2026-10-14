# Сторонние компоненты и лицензии

Сводка по всему репозиторию «Великий & Могучий» (Velikiy Moguchiy). Составлена по файлам самого репозитория:
вендорным `LICENSE`/`NOTICE`, `Cargo.lock`, `Package.resolved`, `pyproject.toml`/`uv.lock` и документам в папках.
Подробные списки по частям: [`mac/THIRD_PARTY.md`](mac/THIRD_PARTY.md), [`ios/THIRD_PARTY.md`](ios/THIRD_PARTY.md),
[`ios/THIRD_PARTY_NOTICES.md`](ios/THIRD_PARTY_NOTICES.md), [`android/THIRD_PARTY.md`](android/THIRD_PARTY.md).

Статусы:
- **подтверждено** — в репозитории есть текст лицензии или прямое и конкретное указание на неё (файл указан);
- **со слов** — в репозитории только упоминание лицензии, самого текста нет;
- **проверить** — репозиторий лицензию не подтверждает; не гадаем, нужно проверить у источника;
- **лицензия не указана** — у источника нет файла лицензии и не названы условия использования.

Это не юридическое заключение; юрист список пока не проверял (см. «Что сделано к v0.1 и что осталось»).

## 1. Основа приложения и вендорный код

| Компонент | Где | Как используется | Лицензия | Подтверждение | Статус |
|---|---|---|---|---|---|
| [koe](https://github.com/missuo/koe) (Vincent Yang) | всё `mac/` | форк | MIT, `Copyright (c) 2026 Vincent Yang` | `mac/LICENSE` | подтверждено |
| [Lipflow](https://github.com/amywork777/lipflow) | `mac/vendor/lipflow/`; приложение запускает установленный `Lipflow.app` | вендорный код, в приложение не линкуется | MIT, `Copyright (c) 2026 Amy Zhou` | `mac/vendor/lipflow/LICENSE` | подтверждено |
| ESPnet (урезанный) | `mac/vendor/lipflow/espnet/` | вендорный код внутри Lipflow | Apache-2.0 | `mac/vendor/lipflow/NOTICE`, заголовки файлов | со слов: **текста Apache-2.0 рядом нет** |
| Auto-AVSR / VSR for Multiple Languages | Lipflow: `mean_face.npy`, словарь, предобработка | адаптированный код и данные | Apache-2.0 | `mac/vendor/lipflow/NOTICE` | со слов |
| Chaplin (Amanvir Parhar) | Lipflow: идея, зеркала весов | ссылка | MIT | `mac/vendor/lipflow/NOTICE` | со слов |
| [macos-mic-keepwarm](https://github.com/drewburchfield/macos-mic-keepwarm) (`mic-warm`) | `mac/vendor/mic-warm/`; бинарник кладётся в приложение | вендорный код, поставляется | MIT, `Copyright (c) 2025-2026 Drew Burchfield` | `mac/vendor/mic-warm/LICENSE` | подтверждено |
| [giga-pisar](https://github.com/moznoazachem/giga-pisar) | `SPClipboardManager.m`, `main.m` | перенесённый код | MIT, `Copyright (c) 2026 moznoazachem` | `mac/THIRD_PARTY.md` (полный текст) | подтверждено |
| [OpenLess](https://github.com/openless-ai/openless) | по `mac/THIRD_PARTY.md`: хоткеи, перевод строки в терминалах, IPv4 first, автостоп по тишине | только как спецификация | AGPL-3.0 | `mac/THIRD_PARTY.md` | **снято в v0.1**: `velikiy-moguchiy-core/src/unicode_typing.rs`, который называл себя производным от OpenLess, переписан с нуля по письменному описанию поведения, без старого кода; остальное — независимые реализации по описанию поведения |
| OpenWhispr `snippets.ts` | поведение `commands.rs`, `snippets.rs` | спецификация | MIT | `mac/THIRD_PARTY.md` | со слов |
| Voxt | `velikiy-moguchiy-asr/src/glm.rs` («same approach as Voxt») | подход | не указана | — | проверить |
| Wispr Flow, Apple Dictation, TypeWhisper и др. | поведение отдельных функций | спецификация, код не брался | проприетарные / разные | `mac/THIRD_PARTY.md` | — |

## 2. Клавиатура iOS

| Компонент | Где | Как используется | Лицензия | Подтверждение | Статус |
|---|---|---|---|---|---|
| [GeminiKeyboardSample](https://github.com/LyalinDotCom/GeminiKeyboardSample) (LyalinDotCom) | основа всего `ios/` | форк с изменениями | **Apache-2.0** | `ios/LICENSE` (полный текст), `ios/THIRD_PARTY.md` (список изменений по п. 4(b)) | подтверждено; правообладатель в `LICENSE` не назван (шаблонная строка), есть ли у исходника файл `NOTICE` — **проверить** |
| KeyboardKit 9.9.1 (порт) | `ios/KeyboardExtension/KeyboardKitPort/`, `Shared/Keyboard/` | адаптированный код | MIT, `Copyright (c) 2016-2025 Daniel Saidi` | `ios/THIRD_PARTY_NOTICES.md` (полный текст) | подтверждено |
| [KeyboardKit](https://github.com/KeyboardKit/KeyboardKit) 9.9.1 (Swift-пакет) | только сборка для сравнения (схема `VelikiyMoguchiyKK`) | зависимость | MIT (последний MIT-выпуск; 10.0+ закрыты) | `ios/project.yml`, `Package.resolved`, `THIRD_PARTY_NOTICES.md` | подтверждено |
| livetranslate-bridge, VivaDicta, aidictation | — | только как документация, код не брался | MIT | `ios/THIRD_PARTY.md` | со слов |

## 3. Swift-пакеты

В репозитории закреплены только адреса и версии, тексты лицензий не лежат, поэтому всё — **проверить**.

| Пакет | Версия | Где | Поставляется в приложении |
|---|---|---|---|
| [Sparkle](https://github.com/sparkle-project/Sparkle) | — | убран из `mac/MacApp/project.yml` в v0.1 | нет: фреймворк был подключён, но не использовался; автообновления нет, пока нет Developer ID |
| mlx-audio-swift, mlx-swift, mlx-swift-lm, swift-transformers, swift-jinja, swift-huggingface, EventSource, yyjson, apple/swift-* (argument-parser, asn1, atomics, collections, crypto, nio, numerics, system), swift-syntax | см. `mac/Packages/MLXBridge/Package.resolved`, `mac/tools/llmbatch/Package.resolved` | `MLXBridge`, `llmbatch` | нет: схема MLX сейчас не собирается, `llmbatch` — инструмент разработчика |

## 4. Rust (macOS-приложение и CLI)

`mac/Cargo.lock`: крейты с crates.io, у всех есть поле `license`. В приложение и встроенный CLI
(ядро с `--no-default-features --features apple-speech,sherpa-onnx`, aarch64-apple-darwin) линкуются 182 крейта, все под
разрешительными лицензиями: MIT, Apache-2.0, их сочетания, ISC, BSD, Unicode-3.0, Zlib, BSL-1.0,
CDLA-Permissive-2.0 (данные корневых сертификатов `webpki-roots`). Их список и тексты лицензий (из самих крейтов,
плюс `COPYING` встроенной libopus) лежат в приложении: `mac/MacApp/VelikiyMoguchiy/Licenses/ThirdPartyNotices.txt`,
окно «О программе → Лицензии». Пересобрать после смены зависимостей: `python3 tools/third-party-notices/generate.py`.

| Что отметить | Лицензия | Статус |
|---|---|---|
| `cbindgen` 0.27 | MPL-2.0 | только инструмент сборки (генерирует `velikiy_moguchiy_core.h`), в приложение не линкуется |
| `r-efi` | MIT OR Apache-2.0 OR LGPL-2.1-or-later | только для UEFI, в сборку не попадает |
| `audiopus_sys` собирает и статически линкует **libopus** | BSD-подобная (Xiph.Org и др.) | текст `opus/COPYING` кладётся в приложение (`ThirdPartyNotices.txt`) |
| `ring` (код BoringSSL/OpenSSL) | Apache-2.0 AND ISC + уведомления BoringSSL | файлы лицензий `ring` кладутся в приложение (`ThirdPartyNotices.txt`) |
| `sherpa-onnx` / `sherpa-onnx-sys` и их статические библиотеки: sherpa-onnx, kaldi-native-fbank, kaldi-decoder, OpenFst, simple-sentencepiece, ONNX Runtime, KISS FFT | Apache-2.0; ONNX Runtime — MIT; KISS FFT — BSD-3-Clause | в релизной сборке: вариант **без синтеза речи** (`mac/scripts/sherpa-onnx-libs.sh`, закреплён по SHA-256), потому что обычный тянет espeak-ng (GPL-3.0); тексты лицензий — в `ThirdPartyNotices.txt` |
| `libsqlite3-sys` | MIT | линкуется системный SQLite, свой не встраивается |

## 4а. Windows (`windows/`)

`windows/Cargo.lock`: то же Rust-ядро плюс крейты для Windows. В `VelikiyMoguchiy.exe` из релиза
(x86_64-pc-windows-msvc, без функции `sherpa-onnx`) линкуются 178 крейтов, все под разрешительными лицензиями:
MIT, Apache-2.0, их сочетания, ISC, BSD, Unicode-3.0, Zlib, BSL-1.0, CDLA-Permissive-2.0. Их список и тексты
лицензий (из самих крейтов, плюс `COPYING` встроенной libopus) лежат в zip рядом с программой:
`ThirdPartyNotices.txt`, его пишет `windows/tools/third_party_notices.py` при сборке релиза.

| Что отметить | Лицензия | Статус |
|---|---|---|
| `windows` 0.62 и `windows-*` (Microsoft, привязки Win32) | MIT OR Apache-2.0 | линкуются, текст в `ThirdPartyNotices.txt` |
| `cpal` 0.18 (микрофон через WASAPI), `dasp_sample` | Apache-2.0; MIT OR Apache-2.0 | линкуются, текст в `ThirdPartyNotices.txt` |
| `audiopus_sys` собирает и статически линкует **libopus** | BSD-подобная (Xiph.Org и др.) | текст `opus/COPYING` — в `ThirdPartyNotices.txt` |
| `ring` (код BoringSSL/OpenSSL) | Apache-2.0 AND ISC + уведомления BoringSSL | линкуется, файлы лицензий — в `ThirdPartyNotices.txt` |
| `embed-resource`, `png` | MIT; MIT OR Apache-2.0 | только сборка (ресурсы и иконки), в программу не линкуются |
| Иконки программы | MIT (проект) | делаются при сборке из иконки Mac-приложения (`mac/MacApp/.../AppIcon.appiconset`) |
| `sherpa-onnx` / `sherpa-onnx-sys`: готовые библиотеки с GitHub k2-fsa (sherpa-onnx — Apache-2.0, onnxruntime — MIT, kaldi-native-fbank — Apache-2.0, **espeak-ng — GPL-3.0**, piper-phonemize — MIT) | разные, включая **GPL-3.0** | **в релиз не входит**: только при сборке с функцией `sherpa-onnx`. Общий C API sherpa-onnx тянет в программу и синтез речи с espeak-ng, поэтому такая сборка не может распространяться только под MIT. CI проверяет, что в релизном exe нет espeak-ng |

## 5. Python

**lipread** (`lipread/pyproject.toml`, `uv.lock`; лицензии по метаданным установленных пакетов, в репозитории не записаны):
torch 2.7.1 (BSD-3-Clause), torchvision 0.22.1 (BSD), numpy 2.2.6 (BSD), einops 0.8.1 (MIT),
linear-attention-transformer 0.19.1 (MIT), transformers 4.53.1 (Apache-2.0), tokenizers 0.21.2 (Apache-2.0),
configargparse 1.7.1 (MIT), scipy 1.16.0 (BSD), pandas (BSD-3-Clause), tqdm 4.67.1 (MPL-2.0 AND MIT),
pillow 11.3.0 (MIT-CMU); opencv-python 4.12.0.88 и pyobjc-framework-avfoundation — **проверить**.

Только на арендованных серверах (`harvester/pod/`, `extdata/`, `newdata/`, `synth/pod/` — **проверить**): yt-dlp, hydra-core,
omegaconf, sentencepiece, soundfile, deno, GigaAM (из git), speechbrain, torchaudio, mediapipe, silero-vad,
python_speech_features, pydub, onnx, onnxruntime, diffusers, accelerate, librosa, pyarrow.

**federated** (`federated/pyproject.toml`, без lock-файла): numpy (BSD-3-Clause и др.), safetensors (Apache-2.0),
cryptography (Apache-2.0 OR BSD-3-Clause), pydantic (MIT), fastapi (MIT), uvicorn (BSD-3-Clause),
python-multipart (Apache-2.0), httpx (BSD-3-Clause), pytest (MIT), torch (BSD-3-Clause, только симуляция).

**Режим «губы» в приложении** ставит на машину пользователя (в `~/.velikiy-moguchiy/lips/`, в приложение не кладётся)
[uv](https://github.com/astral-sh/uv) (MIT / Apache-2.0), Python и пакеты из `lipread/uv.lock`, код MultiVSR (см. §6)
и `imageio-ffmpeg` (BSD-2-Clause; внутри — сборка FFmpeg под GPL, скачивается пользователем с PyPI).

**Lipflow** (`mac/vendor/lipflow/uv.lock`, 116 пакетов, ставятся на машину пользователя его `setup.sh`, в приложение не
кладутся): лицензии в lock-файле не записаны — **проверить**, в первую очередь на копилефт: pynput, pystray,
python-xlib, av (PyAV, несёт FFmpeg).

## 6. Модели, веса, данные и сервисы

**Исходных кода и весов MultiVSR в репозитории нет**: у MultiVSR лицензия не указана (в репозитории авторов нет файла
лицензии, README условий не называет и просит ссылаться на статью), поэтому `lipread/setup.sh` и
`lipread/download_weights.sh` берут их у авторов на машину пользователя. Дообученная модель проекта lips-0.1
(надстройка LoRA и дообученная визуальная часть MultiVSR) — производная от MultiVSR. Она опубликована по решению
автора проекта на Hugging Face (`z1gansh1n/velikiy-moguchiy-lips`) и в выпуске `lips-0.1`
[velikiy-moguchiy-models](https://github.com/zigansh1n/velikiy-moguchiy-models/releases), пока её не заменит
собственная модель, обученная с нуля; если авторы MultiVSR возразят, её уберут. Разрешения авторов на это нет, и
запрета тоже: условий они не называют.

| Что | Как используется | Что сказано в репозитории | Где | Статус |
|---|---|---|---|---|
| [MultiVSR](https://github.com/Sindhu-Hegde/multivsr): код | `lipread/setup.sh` клонирует у авторов на закреплённом коммите; `lipread/multivsr_compat.py` правит эту локальную копию на машине пользователя | «у репозитория MultiVSR нет файла LICENSE» | `lipread/README.md` | **лицензия не указана**; кода MultiVSR в репозитории нет: прежний патч с их кодом удалён, скрипт вносит те же правки локально (в нём только короткие строки-ориентиры) и сверяет результат по SHA-256 |
| MultiVSR: веса `model.pth` | скачиваются у авторов (`download_weights.sh`; приложение в режиме «губы» — с согласия пользователя, по SHA-256) | «лицензия не указана» | `lipread/download_weights.sh`, `mac/MacApp/VelikiyMoguchiy/LipData/SPLipsRuntimePolicy.m` | **лицензия не указана**, проектом не распространяются |
| Дообученная модель lips-0.1 (производная от MultiVSR) | режим «губы» и «Обучить на мне»; публикуется в выпуске `lips-0.1` и на Hugging Face | «опубликована по решению автора проекта до замены своей моделью; будет убрана, если авторы MultiVSR возразят» | `README.md`, `lipread/README.md` | **лицензия основы не указана**; разрешения авторов MultiVSR нет, запрета тоже нет |
| VTP `feature_extractor.pth` | скачивается | «лицензия VTP-чекпойнта не найдена» | `lipread/README.md` | **лицензия не указана** |
| Датасет MultiVSR (Hugging Face) | метаданные | «аннотации MIT; видео — авторы роликов» | `lipread/extdata/selection.py` | со слов |
| GigaAM | эталонные тексты на серверах | лицензия не указана | `harvester/pod/bootstrap.sh` | проверить (и можно ли его выходы использовать как разметку) |
| MuseTalk 1.5 | генерация синтетики | «MIT, любое использование, в том числе коммерческое» | `lipread/results/synth/README.md` | со слов |
| SFHQ (лица) | синтетика, только эксперименты на арендованных серверах | «Kaggle CC0» в одном месте и «оговорка про веса StyleGAN (некоммерческие)» в другом | `lipread/results/synth/README.md` | противоречие не снято, поэтому **не распространяется**: ни лиц, ни клипов, ни картинок с ними в репозитории и в сборках нет (кадры из `results/synth/` удалены), только код и описания |
| Golos (Sber) | звук для синтетики | «публичная лицензия с указанием авторства, условия как у BY-SA, коммерческое использование разрешено» | `lipread/synth/sources.py` | со слов; текст лицензии в репозиторий не положен |
| Russian LibriSpeech (RuLS) | звук для синтетики | «public domain in the USA» | `lipread/synth/sources.py` | со слов |
| Common Voice ru | по желанию | «CC0-1.0; нельзя перевыкладывать и опознавать дикторов» | `lipread/synth/sources.py` | со слов |
| MuAViC ru | главный экзамен | «MuAViC CC BY-NC 4.0; тексты mTEDx CC BY-NC-ND 4.0; видео — авторы» | `lipread/extdata/selection.py` | **некоммерческая**: только оценка (экзамен), в сборки, в данные для обучения и в репозиторий не попадает и не распространяется |
| AVSpeech, VoxCeleb2 | кандидаты | «метаданные CC BY 4.0 / CC BY-SA 4.0» | `lipread/extdata/selection.py` | со слов, только метаданные |
| LRWR, RUSAVIC | не получены | «по запросу, по лицензионному соглашению, только для исследований» | страницы датасетов у авторов | со слов |
| Ролики YouTube, RuTube, VK | сбор клипов | «публиковать нельзя: авторские права и лица; можно только списки каналов и код сбора» | `tools/privacy_guard.py`, `.gitignore` | клипы не публикуются |
| Whisper (токенизатор, `whisper-tiny`), Silero VAD, SpeechBrain voxlingua107, MediaPipe, S3FD, SyncNet, sd-vae-ft-mse, TAESD | вспомогательные модели на серверах | лицензии не указаны | `lipread/` (README, `newdata/`, `extdata/`, `synth/pod/`) | проверить |
| Модели Lipflow (Auto-AVSR на LRS3, языковая модель) | скачиваются самим Lipflow на машину пользователя | «non-commercial research use» | `mac/vendor/lipflow/NOTICE`, `README.md` | **некоммерческие**: только для оценки, в приложение не встраиваются и нами не распространяются |
| Vosk small streaming ru ([alphacep](https://huggingface.co/alphacep/vosk-model-small-streaming-ru), в формате sherpa-onnx) | локальное распознавание без ключа; скачивается по манифесту на машину пользователя | «apache-2.0» в карточке модели | `mac/velikiy-moguchiy-core/src/manifests/sherpa-onnx/ru-vosk-small.json` | со слов; нами не распространяется |
| Qwen3 / Qwen3-ASR (MLX), другие модели sherpa-onnx | скачиваются по манифестам | лицензии не указаны | `mac/velikiy-moguchiy-core/src/manifests/` | проверить |
| WeType `embed140m` (Tencent) | офлайн-распознавание, только за функцией `wetype-offline` | «восстановлено статическим анализом приложения WeType 3.5.2», веса раздаёт `model.koe.li` | `mac/velikiy-moguchiy-asr/src/wetype.rs` | **лицензия не указана**; с v0.1 **не входит ни в сборку по умолчанию, ни в релиз**: функция выключена везде, манифест загрузки весов без неё не ставится; код оставлен только для локальных экспериментов разработчика |

Облачные сервисы распознавания и LLM (DashScope / Qwen, Doubao / Volcengine, GLM, MiMo, OpenAI, Anthropic, APFEL)
используются по ключу самого пользователя и по условиям этих сервисов. Клиент **DoubaoIME**, который представлялся
официальным Android-приложением ByteDance (ключ из их приложения, чужой User-Agent), **удалён в v0.1** вместе с
проверкой соединения в настройках; провайдер по умолчанию теперь Qwen (DashScope) с ключом пользователя.

## 7. Прочее

| Что | Статус |
|---|---|
| Значки macOS и iOS (`mac/MacApp/VelikiyMoguchiy/Assets.xcassets/AppIcon.appiconset/`, `ios/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png`), значок строки меню, орнаменты, рамки, заставки и буквицы README (`design/readme/`) | **своя работа**: киноварная «В» в рамке в манере Билибина, лоза, розетки; генерируются `design/old-rus/make_assets.py` (MIT, как код). Текст в SVG переведён в контуры. Прежние значки удалены |
| Скриншоты системной клавиатуры Apple (`ios/screenshots/compare/*-apple-*.png`, `ios/Tests/Reference/Apple/`) | для сравнения раскладок; решить, оставлять ли в публичном репозитории |
| Лицо реального человека (`lipread/results/framing/windows96.jpg`) | **удалено** в v0.1, в истории публичного репозитория его нет |
| Синтетические лица SFHQ на картинках в `lipread/results/synth/` (и `synth/dashscope/`) | **удалены** в v0.1, см. SFHQ выше |
| Звуки сигналов macOS (Tink, Pop, Basso) | системные звуки, вызываются по имени, в репозитории не лежат |

## 8. Картины и шрифты оформления

Картины взяты с Wikimedia Commons; на странице каждого файла указано, что он в общественном достоянии **и в России, и в США**
(шаблоны `PD-Russia-expired`, `PD-old-auto-expired` / `PD-Art-two-auto` и «опубликовано до 1 января 1931 г.» для США).
В репозитории лежат только тонированные под палитру фрагменты (`design/readme/*.jpg`, рамка «О программе» на Mac);
исходные файлы `design/old-rus/make_assets.py` скачивает в `design/old-rus/.cache/`.

| Автор | Картина | Год | Источник | Статус | Где |
|---|---|---|---|---|---|
| Виктор Васнецов (1848–1926) | «Богатыри» | 1881–1898 | [Commons](https://commons.wikimedia.org/wiki/File:Viktor_Vasnetsov_-_Богатыри_-_Google_Art_Project.jpg) | общественное достояние: автор умер в 1926 г.; в США опубликовано до 1931 г. | баннер README, «О программе» на Mac |
| Николай Рерих (1874–1947) | «Заморские гости» | 1901 | [Commons](https://commons.wikimedia.org/wiki/File:Nicholas_Roerich,_Guests_from_Overseas_(corrected_colour).jpg) | `PD-Russia-expired` (ст. 1281 ГК РФ); в США опубликовано до 1931 г. | README, «Семейство продуктов» |
| Николай Рерих | «Гонец. Восстал род на род» | 1897 | [Commons](https://commons.wikimedia.org/wiki/File:Messenger_(1897)_by_Nikolai_Roerich.jpg) | `PD-Russia-expired`; в США опубликовано до 1931 г. | README, «Дорожная карта» |
| Андрей Рябушкин (1861–1904) | «Свадебный поезд в Москве (XVII столетие)» | 1901 | [Commons](https://commons.wikimedia.org/wiki/File:Ryabushkin_Wedding_train_in_Moscow_1901_gtg.jpg) | автор умер в 1904 г.; в США опубликовано до 1931 г. | README, «Сообщество» |
| Иван Билибин (1876–1942) | заставка к «Сказке об Иване-царевиче, Жар-птице и о Сером волке» | 1899 | [Commons](https://commons.wikimedia.org/wiki/File:Сказка_об_Иване-царевиче,_Жар-птице_и_Сером_Волке_1.jpg) | `PD-Russia-expired`; в США опубликовано до 1931 г. | README, конец |

Фотографии плоских картин сами по себе охраны не создают (позиция Wikimedia Foundation, `PD-Art`).

| Шрифт | Авторы | Лицензия | Где |
|---|---|---|---|
| [Oglavie, Monomakh, Vertograd](https://github.com/typiconman/fonts-cu) (набор fonts-cu) | Aleksandr Andreev, Nikita Simmons | SIL OFL 1.1 | Oglavie — вязь заголовков, Monomakh — золотые буквицы, подписи и меню: вложены в приложения Mac и iOS (`Fonts/`, текст лицензии рядом); Vertograd — буквицы README, только в генераторе (`design/old-rus/fonts/`); в SVG все — контурами |
| [Old Standard TT](https://fonts.google.com/specimen/Old+Standard+TT) | Alexey Kryukov | SIL OFL 1.1 | подписи и заголовки разделов: вложен в приложения Mac и iOS, в SVG — контурами |

## 9. Клавиатура Android

| Компонент | Где | Как используется | Лицензия | Подтверждение | Статус |
|---|---|---|---|---|---|
| Списки слов [AOSP LatinIME](https://android.googlesource.com/platform/packages/inputmethods/LatinIME/+/127336e9f29d69607eab55982324b210279ae8c5/dictionaries/) (`ru_wordlist`, `en_US_wordlist`) | `android/app/src/main/assets/dictionary/` | данные подсказок: урезаны по частоте, без личных имён (`android/tools/build_wordlists.py`) | **Apache-2.0**, Copyright (c) 2008, The Android Open Source Project | полный `NOTICE` LatinIME с текстом Apache-2.0 — в `android/THIRD_PARTY.md` и в APK (`assets/licenses.txt`, «Настройки → Лицензии») | подтверждено; `NOTICE` LatinIME говорит «Includes Dictionaries © Lexiteria LLC. Used by permission.», дальше происхождение слов в папке `dictionaries/` не описано |
| Material Icons, значок «mic» | иконка приложения (`android/app/src/main/res/drawable/ic_launcher_foreground.xml`) | контур значка | Apache-2.0, Google LLC | `android/THIRD_PARTY.md`, `assets/licenses.txt` | со слов |
| KeyboardKit 9.9.1 (через порт `ios/Shared/Keyboard`) | `android/app/.../keyboard/KeyboardLayout.kt` | идеи раскладок и состояния Shift/страниц | MIT, `Copyright (c) 2016-2025 Daniel Saidi` | полный текст в `android/THIRD_PARTY.md` и `assets/licenses.txt` | подтверждено |
| AndroidX, Jetpack Compose, Kotlin, kotlinx.coroutines, kotlinx.serialization, OkHttp, Okio | зависимости APK (`android/gradle/libs.versions.toml`) | библиотеки | Apache-2.0 | список в `android/THIRD_PARTY.md` и `assets/licenses.txt` | со слов |

## Что сделано к v0.1 и что осталось

Сделано:

1. **OpenLess (AGPL-3.0)**: `unicode_typing.rs` переписан с нуля; `mac/THIRD_PARTY.md` описывает, как.
2. **WeType**: за выключенной функцией `wetype-offline`, не в сборке по умолчанию и не в релизе. **DoubaoIME**: удалён.
3. **MultiVSR**: ни весов, ни кода в репозитории; патч заменён скриптом `lipread/multivsr_compat.py`.
4. **Некоммерческие данные** (MuAViC, LRS3-модели Lipflow, LRWR/RUSAVIC): только для оценки, не распространяются,
   в сборки и в данные для обучения не попадают.
5. **SFHQ и синтетика**: не распространяются, в репозитории только код и описания.
6. **Уведомления в сборках**: «О программе → Лицензии» на Mac и «Настройки → Лицензии» на iPhone показывают
   вложенный `ThirdPartyNotices.txt` (`tools/third-party-notices/generate.py`). Sparkle убран.
7. **Значки** заменены своими; фото лица удалено.

Осталось (не блокирует открытый исходный код, но нужно до коммерческого распространения):

1. **Golos, GigaAM** — положить тексты лицензий (в `lipread/` упоминается `data/synth/LICENSES.md`, в репозитории его нет).
2. **ESPnet** внутри Lipflow — положить текст Apache-2.0 рядом с `mac/vendor/lipflow/`.
3. **Скриншоты системной клавиатуры Apple** (`ios/screenshots/compare/*-apple-*.png`, `ios/Tests/Reference/Apple/`) —
   решить, оставлять ли их в публичном репозитории (нужны проверке совпадения раскладок).
4. Юридическая проверка этого списка: пока не проводилась.
