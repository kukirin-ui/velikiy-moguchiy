# Автоматизация репозитория

Что в репозитории работает само, без автора, и что нужно сделать один раз, чтобы это включить.

## Что работает само

| Что | Когда | Где настраивается |
|---|---|---|
| Проверки кода (Rust, federated, lipread) | каждый PR и push в `main` | `.github/workflows/tests.yml` |
| Проверка приватности (`tools/privacy_guard.py`) | каждый push и PR | `.github/workflows/privacy.yml` |
| Проверка текстов языковой моделью: черновики, заглушки, личные данные, атрибуция ИИ, устаревшие утверждения | каждый PR, меняющий документы (остальные PR проходят сразу) | `.github/workflows/text-review.yml`, `tools/text_review/` |
| Проверка лицензий зависимостей | PR, меняющий зависимости; push в `main`; раз в неделю | `.github/workflows/licenses.yml`, `tools/licenses/allowlist.toml` |
| Обновления зависимостей (Dependabot) | по понедельникам | `.github/dependabot.yml` |
| Автомерж обновлений patch и minor | когда все обязательные проверки зелёные | `.github/workflows/dependabot-automerge.yml` |
| Страница статистики `docs/STATS.md` | раз в день, коммит только при изменении цифр | `.github/workflows/stats.yml` |
| Таблица участников в README | при изменении `contributors.json` | `.github/workflows/contributors.yml` |
| Проверка журнала исключений | PR, меняющий `data-governance/` | `.github/workflows/data-governance.yml` |
| Запуск клавиатуры Android на эмуляторе: установка, включение через adb, набор клавишами, диктовка через подставной сервер, микрофон | PR, меняющий `android/`; каждую ночь; вручную | `.github/workflows/smoke-android.yml`, `android/scripts/emulator-tests.sh` |
| Запуск программы для Windows: старт с временными настройками, значок в трее, диктовка в Блокнот через подставной сервер, чистый выход | PR, меняющий `windows/` или ядро; каждую ночь; вручную | `.github/workflows/smoke-windows.yml`, `windows/tools/smoke/` |
| Сборка приложения для Mac и IPA | метка `build` на PR, теги `mac-v*` и `ios-v*`, вручную | `.github/workflows/build-apple.yml` |
| Релиз: версия, тег, сборки для всех платформ, заметки, публикация | раз в день, если с прошлого релиза изменился продукт и проверки `main` зелёные; вручную | `.github/workflows/release.yml`, `tools/release/plan.py`, `.github/release-notes.md` |
| Черновик релиза | тег `v*`, поставленный вручную (черновик публикуется вручную) | `.github/workflows/release.yml` |
| Формула Homebrew и источник AltStore | сразу после автоматического релиза; при публикации или удалении релиза вручную | `.github/workflows/stores.yml`, `tools/homebrew/`, `tools/altstore/` |
| Ярлыки «good first issue» и «help wanted» | при изменении `tools/labels/labels.json` | `.github/workflows/labels.yml` |
| «Помочь обучить»: сервер приёма на Cloudflare Workers | push в `main`, меняющий `federated/worker/` | `.github/workflows/federated-worker.yml` |
| «Помочь обучить»: экзамен, слияние, новая версия адаптера, таблица участников | раз в день | `.github/workflows/federated-aggregate.yml` |

## Что сделать владельцу один раз

1. **Обложка репозитория.** Settings → General → Social preview → Edit → Upload an image… и выбрать
   [`docs/assets/social-preview.png`](assets/social-preview.png). Обложку показывают мессенджеры и сайты, когда в
   них вставляют ссылку на репозиторий. Через API её не загрузить, только руками.
2. **Репозиторий Homebrew** (см. раздел [Homebrew](#homebrew) ниже): создать репозиторий, сделать ключ, добавить его
   в репозиторий и записать секрет — четыре команды.
3. **Задачи для новичков:** выбрать задачи в [`docs/starter-issues/`](starter-issues/) и открыть нужные как issues
   командой оттуда же.

## Защита ветки `main`

Правила лежат в [`.github/rulesets/main.json`](../.github/rulesets/main.json) и применяются как ruleset репозитория:

- изменения в `main` — только через PR (одобрение не требуется, чтобы автомерж Dependabot работал без людей);
- обязательные проверки: задания «Tests», «Licences», «Privacy guard» и «Text review» (пропущенное задание считается
  пройденным; «Text review» проходит и тогда, когда модель не настроена или недоступна);
- force push и удаление ветки запрещены;
- **обходить правила могут** администратор репозитория (владелец не заблокирован) и deploy key `BOT_PUSH_KEY`.

GitHub Actions в личном репозитории нельзя разрешить обход ruleset, поэтому автокоммиты (статистика, таблица
участников) пушатся deploy key с правом записи. Его закрытая часть — секрет репозитория `BOT_PUSH_KEY`; автор
коммитов — `github-actions[bot]`. Без секрета эти workflow пушат обычным токеном, и защита `main` такой push
отклоняет.

Изменить правила: поправить JSON и применить.

```bash
gh api repos/zigansh1n/velikiy-moguchiy/rulesets --jq '.[] | select(.name=="main") | .id'
```

```bash
gh api -X PUT repos/zigansh1n/velikiy-moguchiy/rulesets/ID --input .github/rulesets/main.json
```

Новое обязательное задание добавляется в `required_status_checks` по его имени (`name:` задания в workflow).

Заменить ключ для автокоммитов:

```bash
ssh-keygen -t ed25519 -N "" -C "actions-bot-push" -f bot_push_key
```

```bash
gh repo deploy-key add bot_push_key.pub --allow-write --title "actions-bot-push" -R zigansh1n/velikiy-moguchiy
```

```bash
gh secret set BOT_PUSH_KEY -R zigansh1n/velikiy-moguchiy < bot_push_key
```

После этого удалите оба файла ключа и старый ключ в Settings → Deploy keys.

## Релизы

Релизы выходят сами: workflow «Release» (`.github/workflows/release.yml`) запускается раз в день в 03:23 UTC и ничего
не ждёт от людей. Сколько бы PR ни слили за день, выйдет один релиз.

1. **Что выпускать.** [`tools/release/plan.py`](../tools/release/plan.py) идёт по `main` от последнего коммита назад и
   берёт первый, у которого все проверки, запущенные push в `main`, завершились зелёными (успех или пропуск).
   Коммит, чьи проверки ещё идут, были отменены более новым push или упали, не выпускается, берётся предыдущий.
2. **Есть ли что выпускать.** Релиз нужен, только если с последнего тега `v*` изменился продукт: `mac/`, `ios/`,
   `android/`, `windows/`, код чтения по губам, который приложение для Mac кладёт в себя (`lipread/*.py`,
   `pyproject.toml`, `uv.lock`), клиент «Помочь обучить» (`federated/client/`, `federated/protocol/`) или
   `tools/mem_guard.py`. Документы (`.md`) и тесты сами по себе релиз не вызывают.
3. **Номер версии.** По умолчанию растёт третья цифра: 0.1.0 → 0.1.1. Если в сообщении любого коммита или в
   заголовке любого слитого PR с прошлого релиза есть `[minor]`, растёт вторая (0.1.4 → 0.2.0), если `[major]` —
   первая (0.9.2 → 1.0.0). Сами пометки в заметки не попадают. Первый релиз, когда тегов `v*` ещё нет, — 0.1.0.
4. **Заметки к выпуску.** Шаблон `.github/release-notes.md`; на место `{{VERSION}}` встаёт номер версии, на место
   `{{CHANGES}}` — раздел «Что нового»: заголовки PR, слитых с прошлого релиза, по продуктам (по тому, в какой папке
   больше всего изменённых файлов PR), обновления зависимостей одной строкой и ссылка на сравнение версий. Поэтому
   заголовок PR пишется по-русски и понятно пользователю. Раздел «Что нового» показывает и AltStore.
5. **Проверки заметок.** Весь текст проходит `tools/privacy_guard.py`, раздел «Что нового» — проверку текстов
   (`tools/text_review.py --file`); замечание важности medium или high останавливает релиз. Исправление —
   поправить заголовок PR на GitHub и запустить workflow ещё раз (или дождаться следующего дня).
6. **Проверки перед сборкой.** Как и у черновика: `privacy_guard.py` на дереве выпускаемого коммита, у коммита автор и
   коммиттер — адреса GitHub no-reply; после сборки `tools/scan_artifacts.py` читает все файлы внутри сборок. Адреса
   авторов шрифтов в самих шрифтах и встроенные адреса OpenSSL он не считает находками.
7. **Сборка и публикация.** Выбранный коммит собирается теми же `build-apple.yml`, `build-android.yml` и
   `build-windows.yml` с номером версии. Релиз сначала создаётся черновиком со всеми файлами и `SHA256SUMS.txt`,
   затем публикуется и помечается последним; тег ставится на коммит в момент публикации. Если что-то упало, тега
   нет и следующий запуск попробует снова.
8. **После публикации** тот же запуск вызывает «Homebrew and AltStore» (`stores.yml`): формула и источник AltStore
   переходят на новую версию. Отдельно его вызывать приходится потому, что релиз, опубликованный токеном
   GitHub Actions, не порождает событий для других workflow. Значок «релиз» в README берёт последнюю версию с
   GitHub, значок «сборка релиза» — состояние последнего запуска «Release» на `main`.

Запустить релиз, не дожидаясь расписания (Actions → Release → Run workflow, или командой):

```bash
gh workflow run release.yml -R zigansh1n/velikiy-moguchiy
```

Параметры ручного запуска: `bump` — какую цифру поднять (`auto` читает пометки), `version` — точный номер,
`force` — выпустить, даже если продукт не менялся, `dry_run` — собрать и проверить всё, но не ставить тег и не
публиковать. Например, первый релиз с точным номером:

```bash
gh workflow run release.yml -R zigansh1n/velikiy-moguchiy -f version=0.1.0
```

Чем кончился последний запуск и почему релиза не было, видно в сводке задания «Plan» (Actions → Release).

**Черновик по тегу.** Тег `v*`, поставленный вручную, по-прежнему собирает **черновик** релиза с теми же проверками и
заметками (от предыдущего тега до этого); его публикуют на странице Releases, и тогда «Homebrew and AltStore»
запускается сам. Тег с дефисом (`v0.3.0-rc1`) даёт предварительный релиз: он не становится последним и не попадает
в формулу Homebrew. Следующий автоматический релиз считает версию от последнего тега без дефиса.

PR, меняющие `tools/release/`, проверку текстов (`tools/text_review.py`, `tools/text_review/`), шаблон заметок или
`release.yml`, получают пробный план: задание
«Plan» показывает, какой релиз вышел бы сейчас, и проверяет его заметки, ничего не собирая и не публикуя.

## Проверка текстов

`text-review.yml` отправляет добавленные строки изменённых документов языковой модели через любой
OpenAI-совместимый API и оставляет замечания в PR (`tools/text_review.py`, промпт и исключения в `tools/text_review/`).
Модель задаётся в настройках репозитория (Settings → Secrets and variables → Actions):

| Имя | Вид | Значение |
|---|---|---|
| `TEXT_REVIEW_ENDPOINT` | переменная | адрес chat completions, например `https://api.cloudflare.com/client/v4/accounts/<ID аккаунта>/ai/v1/chat/completions` |
| `TEXT_REVIEW_MODEL` | переменная | модель, например `@cf/openai/gpt-oss-120b` |
| `TEXT_REVIEW_TOKEN` | секрет | ключ API (для Cloudflare — токен с правом Workers AI) |

Бесплатной суточной квоты Cloudflare Workers AI (10 000 нейронов) хватает примерно на 40 запросов в день; один PR
с правкой документа — обычно один-два запроса, не больше 10. Пока не задано что-то из трёх, проверка пишет «модель не
настроена» и проходит. GitHub Models, на которую проверка рассчитывалась сначала, закрыта GitHub 30 июля 2026 г.

## «Помочь обучить»: что сделать один раз

Участники обучают модель чтения по губам у себя и присылают только обновление весов. Сервер приёма — Cloudflare
Worker (`federated/worker/`), хранение — Hugging Face (аккаунт `z1gansh1n`), проверка и публикация — GitHub
Actions. Пока шагов ниже нет, оба процесса пропускаются и проверки остаются зелёными. Подробности, формат экзамена
и пула: [`federated/docs/DEPLOY.md`](../federated/docs/DEPLOY.md).

Уже готово: аккаунт Cloudflare проекта; закрытые датасеты `z1gansh1n/velikiy-moguchiy-inbox` и
`z1gansh1n/velikiy-moguchiy-exam`, открытый `z1gansh1n/velikiy-moguchiy-lips` (версии адаптера); секреты
`CLOUDFLARE_ACCOUNT_ID`, `FL_TASK_SECRET`, `FL_MODEL_SIGNING_KEY`, `BOT_PUSH_KEY`; переменные `FL_INBOX`, `FL_MODELS`,
`FL_EXAM_REPO`; открытый ключ подписи — в `federated/client/community_defaults.py`. Осталось задать `HF_TOKEN`
(fine-grained с записью в `velikiy-moguchiy-lips` и `velikiy-moguchiy-inbox`) и шаги ниже.

1. **Аккаунт Cloudflare** — отдельный аккаунт проекта «velikiy-moguchiy» (бесплатный план), не личный. Поддомен
   `workers.dev` (`velikiy-moguchiy`) деплой регистрирует сам, если его ещё нет; адрес сервера —
   `https://velikiy-moguchiy-train.velikiy-moguchiy.workers.dev`.
2. **Токен Cloudflare.** <https://dash.cloudflare.com/profile/api-tokens> → **Create Token** → Custom: права
   **Workers Scripts: Edit**, **Workers KV Storage: Edit**, **Account Settings: Read**, только для аккаунта
   «velikiy-moguchiy», без зон. Скопируйте токен.
3. **Account ID** аккаунта проекта: главная страница аккаунта в Cloudflare, справа.
4. **Секреты** (каждая команда спросит значение):

   ```bash
   gh secret set CLOUDFLARE_API_TOKEN -R zigansh1n/velikiy-moguchiy
   ```

   ```bash
   gh secret set CLOUDFLARE_ACCOUNT_ID -R zigansh1n/velikiy-moguchiy
   ```

5. **Два узких токена Hugging Face** (<https://huggingface.co/settings/tokens> → Create new token → **Fine-grained**):
   - `HF_INTAKE_TOKEN` — для Worker: только **запись** в `z1gansh1n/velikiy-moguchiy-inbox`, больше ничего;
   - `HF_READ_TOKEN` — для оценки в агрегаторе: только **чтение** `z1gansh1n/velikiy-moguchiy-inbox` и
     `z1gansh1n/velikiy-moguchiy-exam`.

   ```bash
   gh secret set HF_INTAKE_TOKEN -R zigansh1n/velikiy-moguchiy
   ```

   ```bash
   gh secret set HF_READ_TOKEN -R zigansh1n/velikiy-moguchiy
   ```

   Общий `HF_TOKEN` с записью получает только шаг публикации агрегатора.
6. **Вход участников через GitHub.** <https://github.com/settings/applications/new>: имя `Великий & Могучий`, оба
   адреса `https://github.com/zigansh1n/velikiy-moguchiy`, галочка **Enable Device Flow** → Register. Client secret
   не нужен. Скопируйте **Client ID**:

   ```bash
   gh variable set FL_GITHUB_CLIENT_ID -R zigansh1n/velikiy-moguchiy -b "<client-id>"
   ```

7. **Развернуть.** Actions → **Federated intake deploy** → Run workflow. Процесс проверяет, что поддомен аккаунта
   именно `velikiy-moguchiy`, создаёт хранилище лимитов (KV), кладёт в Worker секреты (`HF_INTAKE_TOKEN`,
   `FL_TASK_SECRET`), публикует его и, если адрес изменился, коммитит его в `federated/client/community_defaults.py`.
   Проверка: `https://velikiy-moguchiy-train.velikiy-moguchiy.workers.dev/v1/health`.
8. **Пул роликов и экзамен** (на поде, где лежат данные сборщика; не на Mac): `federated/docs/DEPLOY.md`, раздел
   «Пул роликов и скрытый экзамен». Пока экзамена нет, ежедневный раунд пропускается; пока нет пула, сервер честно
   отвечает, что заданий нет.
9. **Первая версия.** Actions → **Federated aggregation** → Run workflow: берёт LoRA из lips-0.1, считает WER на
   экзамене и публикует v1; дальше раунд идёт сам раз в день и публикует версию, только когда на экзамене прошли
   хотя бы 5 обновлений.

Необязательно: `MODELS_REPO_TOKEN` — fine-grained токен GitHub на `velikiy-moguchiy-models` (Contents: write), чтобы
каждая версия адаптера выходила ещё и релизом там.

Секреты и переменные, которые читают эти процессы (если репозиторий снова пересоздаётся, задайте заново; новые
ключи можно просто сгенерировать — подписанных версий пока нет):

| Имя | Вид | Кто читает |
|---|---|---|
| `HF_TOKEN` | секрет | только шаг публикации и отката агрегатора (запись в реестр и во входящие) |
| `HF_READ_TOKEN` | секрет | только шаг скачивания в оценке агрегатора (чтение входящих и экзамена) |
| `HF_INTAKE_TOKEN` | секрет | деплой (уходит в секреты Worker: запись во входящие) |
| `FL_MODEL_SIGNING_KEY` | секрет | только шаг публикации и отката агрегатора; открытая часть — файл `federated/client/community_defaults.py` |
| `FL_TASK_SECRET` | секрет | деплой (уходит в секреты Worker) |
| `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID` | секреты | деплой |
| `MODELS_REPO_TOKEN` | секрет, необязательно | агрегатор (релиз-зеркало) |
| `BOT_PUSH_KEY` | секрет | коммиты адреса сервера и таблицы участников |
| `FL_INBOX`, `FL_MODELS`, `FL_EXAM_REPO` | переменные | агрегатор, деплой |
| `FL_GITHUB_CLIENT_ID` | переменная | деплой |
| `FL_MAX_UPDATES_PER_DAY`, `FL_MAX_TASKS_PER_DAY`, `FL_MIN_ACCOUNT_AGE_DAYS`, `FL_BANNED_LOGINS`, `FL_EXAM_LIMIT` | переменные, необязательно | деплой, агрегатор |

Новый ключ подписи (закрытая часть сразу уходит в секрет и нигде не печатается, открытая записывается в
`community_defaults.py` — его нужно закоммитить; версии со старой подписью приложение после этого не примет):

```bash
uv run --with cryptography python federated/aggregator/keys.py
```

## Со-мейнтейнеры

1. Пригласить участника в Settings → Collaborators с ролью **Maintain** (обходить правила `main` эта роль не может).
2. Добавить его в [`.github/CODEOWNERS`](../.github/CODEOWNERS) рядом с владельцем для нужных папок — тогда GitHub
   сам будет просить его посмотреть PR.

## Dependabot и автомерж

Раз в неделю Dependabot открывает по одному PR на экосистему: Rust (`mac/`), Python (`lipread/`, `federated/`),
Swift (пакеты в `mac/`) и GitHub Actions. Обновления patch и minor сливаются сами, когда все обязательные проверки
зелёные; major ждут человека. Для `lipread/` приходят только patch: версии там подобраны под модель MultiVSR, а CI
модель не запускает. В настройках репозитория включено «Allow auto-merge».

## Лицензии зависимостей

`tools/licenses/check.py` проверяет зависимости Rust через cargo-deny, а пакеты Python — по метаданным PyPI.
Единственный список разрешённых лицензий — [`tools/licenses/allowlist.toml`](../tools/licenses/allowlist.toml).
GPL, AGPL, LGPL, SSPL и нераспознанные лицензии не проходят. Если PyPI не называет лицензию пакета, а в его файле
LICENSE она разрешительная, пакет добавляется в `[python.clarify]`. Проверить у себя:

```bash
python3 tools/licenses/check.py python
```

## Страница статистики

`tools/stats/stats.py` раз в день собирает звёзды, форки, авторов изменений, скачивания релизов приложения и
моделей и качество моделей и переписывает [`docs/STATS.md`](STATS.md), если цифры изменились. Качество модели
берётся из `metrics.json` в корне репозитория
[velikiy-moguchiy-models](https://github.com/zigansh1n/velikiy-moguchiy-models), а если его нет — из фразы вида
«72,3% WER на … (MuAViC-ru)» в описании релиза модели. Формат `metrics.json`:

```json
{ "lips-0.1": { "wer": 72.3, "test": "MuAViC-ru" } }
```

## Шаблоны issue

- **«Сообщить о проблеме»** (`problem.yml`). Приложение может открыть форму с заполненными полями: идентификаторы
  полей передаются в адресе, значения кодируются как в URL, например
  `https://github.com/zigansh1n/velikiy-moguchiy/issues/new?template=problem.yml&version=0.1.0&system=macOS%2026.1&log=…`.
  Поля: `version`, `system`, `steps`, `expected`, `actual`, `provider`, `log`. Адрес длиннее ~8000
  символов GitHub не откроет, поэтому длинный лог лучше обрезать до последних строк.
- **«Исключить мои видео»** (`exclusion.yml`) — запрос владельца канала YouTube. Как его обработать, описано в
  [`data-governance/exclusions/README.md`](../data-governance/exclusions/README.md).
- **«Предложение»** (`proposal.yml`).
- Вопросы — в [Discussions](https://github.com/zigansh1n/velikiy-moguchiy/discussions).

## Homebrew

Mac-приложение ставится одной командой:

```bash
brew install --cask zigansh1n/tap/velikiy-moguchiy
```

Формула — [`tools/homebrew/Casks/velikiy-moguchiy.rb`](../tools/homebrew/Casks/velikiy-moguchiy.rb). После
каждого опубликованного релиза (кроме предварительных, с `-` в теге) workflow «Homebrew and AltStore» скачивает
`VelikiyMoguchiy-macOS-arm64.zip`, вписывает в формулу версию и SHA-256 (`tools/homebrew/bump.py`), коммитит её в
`main` и копирует содержимое `tools/homebrew/` в отдельный репозиторий `zigansh1n/homebrew-tap`. Homebrew ищет
формулы сторонних авторов только в репозиториях с именем `homebrew-…`, поэтому без него не обойтись. Править формулу
нужно здесь: репозиторий tap перезаписывается.

Сборка подписана только ad hoc, поэтому формула после установки снимает с приложения карантин (`xattr`), как
советует [`mac/README.md`](../mac/README.md).

Как включить (один раз):

```bash
gh repo create zigansh1n/homebrew-tap --public --description "Homebrew для «Великий & Могучий»"
```

```bash
ssh-keygen -t ed25519 -N "" -C "homebrew-tap-push" -f tap_key
```

```bash
gh repo deploy-key add tap_key.pub --allow-write --title "velikiy-moguchiy releases" -R zigansh1n/homebrew-tap
```

```bash
gh secret set HOMEBREW_TAP_KEY -R zigansh1n/velikiy-moguchiy < tap_key
```

Удалите оба файла ключа и запустите Actions → «Homebrew and AltStore» → Run workflow: tap заполнится сразу, не
дожидаясь следующего релиза. Пока секрета нет, workflow обновляет только формулу в этом репозитории и остаётся
зелёным.

## AltStore и SideStore

Источник для iPhone — [`docs/altstore/source.json`](altstore/source.json). Его адрес, который вводят в AltStore или
SideStore («Источники → +»):

```
https://raw.githubusercontent.com/zigansh1n/velikiy-moguchiy/main/docs/altstore/source.json
```

Файл собирает [`tools/altstore/source.py`](../tools/altstore/source.py) после каждого опубликованного или удалённого
релиза: по одной версии на релиз с `VelikiyMoguchiy-iOS-unsigned.ipa` (адрес файла, размер, дата, описание из
раздела «Что нового» или вступления). Идентификатор приложения, номер сборки, минимальная iOS и тексты разрешений
берутся из самого IPA, права (entitlements) — из `ios/dist/*.entitlements.plist`. Коммит в `main` идёт через
deploy key `BOT_PUSH_KEY`, как у статистики. Своих секретов источнику не нужно. Скриншоты пока не добавлены — это
одна из задач в [`docs/starter-issues/`](starter-issues/).

## Ярлыки и задачи для новичков

Ярлыки «good first issue» и «help wanted» описаны в [`tools/labels/labels.json`](../tools/labels/labels.json) и
создаются (или обновляются) workflow «Labels» при изменении файла; повторный запуск ничего не ломает, ярлыки не из
файла он не трогает. Имена ярлыков английские: по ним GitHub и каталоги задач для новичков находят проект. Вручную:

```bash
python3 tools/labels/sync.py
```

Задачи для участников — [`docs/starter-issues/`](starter-issues/): следующие шаги для Windows и Android, порт на Linux и
несколько простых задач. Как открыть одну как issue, написано там же.
