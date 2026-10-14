# llmbatch — A/B/C-проверка вырождения ответов LLM

Пакетный прогон без интерфейса для пути переписывания текста локальной LLM на MLX. Он вызывает тот же API генерации
`MLXLLM` (`LLMModelFactory`, `ModelContainer`, формат чата `UserInput`, удаление `<think>`), что и
`MLXBridge/MLXLlmManager` в приложении, поэтому результаты A/B/C совпадают с тем, что видит пользователь.

## Последний результат (2026-05-31, 124 примера)

| вариант | вырождение, % | из чего |
|-----|----------|-----------|
| A — без LLM (база) | 0% | — |
| B — Qwen3-0.6B-4bit | 2,4% | 1 схлопывание + 2 перевода |
| C — Qwen3-1.7B-4bit | 0% | — |

---

## Полная процедура A/B/C

### Шаг 1 — собрать программу на Swift

```bash
cd /path/to/velikiy-moguchiy/mac/tools/llmbatch
swift build -c release
```

Программа появится в `.build/release/llmbatch`.

### Шаг 2 — скопировать пакет Metal (один раз на каждую сборку Xcode)

Командная строка SwiftPM не кладёт пакет ресурсов Metal, который нужен `mlx-swift` (`mlx-swift_Cmlx.bundle`), и без
него программа падает при загрузке модели. Скопируйте его из релизной сборки приложения в Xcode:

```bash
cp -R \
  ~/Library/Developer/Xcode/DerivedData/VelikiyMoguchiy-*/Build/Products/Release/mlx-swift_Cmlx.bundle \
  /path/to/velikiy-moguchiy/mac/tools/llmbatch/.build/release/
```

Шаблон `VelikiyMoguchiy-*` подходит к любому хэшу, который выдал Xcode; если папок несколько, выберите нужную
(`ls ~/Library/Developer/Xcode/DerivedData/`).

Копирование нужно повторять после каждой чистой релизной сборки приложения в Xcode.

### Шаг 3 — собрать корпус

```bash
cd /path/to/velikiy-moguchiy/mac
python3 tools/llmbatch/regression/make_corpus.py
```

Результат:
- `/tmp/velikiy-moguchiy-corpus.txt` — по одной строке распознавания (124 строки: 100 настоящих + 24 трудных);
- `/tmp/velikiy-moguchiy-corpus-meta.jsonl` — `{id, source, asr_text}` для каждой строки.

Настоящие примеры берутся из `~/.velikiy-moguchiy/history.db` (seed=42, воспроизводимо). Трудные покрывают четыре
известных вида сбоя: вывод словаря целиком, перевод, схлопывание и обрезание.

### Шаг 4 — подготовить промпты

Из корня репозитория соберите для каждой строки корпуса ту же пару системного и пользовательского промпта, что и в
приложении, с текущими `~/.velikiy-moguchiy/config.yaml` и `~/.velikiy-moguchiy/dictionary.txt`:

```bash
cargo run --example render_prompts --release -- /tmp/velikiy-moguchiy-corpus.txt \
  > /tmp/velikiy-moguchiy-prompts.jsonl
```

Каждая строка вывода: `{"id": N, "asr_text": "...", "system": "...", "user": "..."}`.

### Шаг 5 — прогнать llmbatch для каждой модели

```bash
BIN=/path/to/velikiy-moguchiy/mac/tools/llmbatch/.build/release/llmbatch

# Вариант B — 0.6B
$BIN ~/.velikiy-moguchiy/models/mlx/Qwen3-0.6B-4bit /tmp/velikiy-moguchiy-prompts.jsonl \
  > /tmp/velikiy-moguchiy-results-0.6b.jsonl

# Вариант C — 1.7B
$BIN ~/.velikiy-moguchiy/models/mlx/Qwen3-1.7B-4bit /tmp/velikiy-moguchiy-prompts.jsonl \
  > /tmp/velikiy-moguchiy-results-1.7b.jsonl
```

Каждая строка вывода: `{"id": N, "output": "..."}`.

Прогресс виден по появляющимся строкам. На Apple Silicon 124 примера занимают примерно 5–10 минут на вариант.

### Шаг 6 — классифицировать и сравнить

```bash
python3 tools/llmbatch/regression/classify.py
```

Читает `/tmp/velikiy-moguchiy-corpus-meta.jsonl`, `/tmp/velikiy-moguchiy-results-0.6b.jsonl`,
`/tmp/velikiy-moguchiy-results-1.7b.jsonl` и `~/.velikiy-moguchiy/dictionary.txt`.

Печатает по каждому варианту таблицу `ok / dump / collapse / truncation / translation / empty / error` и долю
вырождения, а затем сами выродившиеся примеры (до 30 на вариант).

---

## Файлы пакета

```
tools/llmbatch/
  Package.swift               манифест пакета Swift
  Package.resolved            закреплённые версии зависимостей
  Sources/llmbatch/Batch.swift  сама программа прогона
  regression/
    make_corpus.py            собирает тестовый корпус из 124 примеров
    classify.py               классифицирует ответы и печатает таблицу вырождения
  .gitignore                  исключает .build/ и *.bundle
```

Пример `render_prompts` на Rust лежит в `velikiy-moguchiy-core/examples/render_prompts.rs` (он часть основного
крейта, а не этого пакета).
