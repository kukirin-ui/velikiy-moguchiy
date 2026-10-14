# velikiy-moguchiy-asr

Библиотека на Rust для потокового распознавания речи (ASR) с единым асинхронным интерфейсом к нескольким облачным и
локальным провайдерам.

## Возможности

- **Единый трейт `AsrProvider`** — провайдеры меняются без изменения логики приложения
- **Потоковое распознавание** — промежуточные, подтверждённые и итоговые результаты по мере обработки звука
- **Облачные провайдеры** — Alibaba Qwen (DashScope), Volcengine Doubao, Zhipu GLM, Xiaomi MiMo, каждый со своим ключом
- **Локальные провайдеры** — Apple Speech Framework, MLX (модели Qwen3-ASR на Apple Silicon), Sherpa-ONNX
- **TranscriptAggregator** — встроенный помощник, который сводит события потока в один текст
- **Горячие слова** — точнее распознают термины своей области
- **Async/await** — на `tokio` и `async-trait`

## Провайдеры

| Провайдер | Движок | Функция Cargo | Соединение | Ключи |
|---|---|---|---|---|
| `DoubaoWsProvider` | Volcengine Seed-ASR | *(всегда)* | WebSocket | App Key + Access Key |
| `QwenAsrProvider` | Alibaba DashScope Qwen-ASR / Qwen Omni | *(всегда)* | WebSocket | ключ API |
| `GlmAsrProvider` | Zhipu GLM-ASR | *(всегда)* | HTTP POST + SSE | ключ API |
| `MimoAsrProvider` | Xiaomi MiMo ASR | *(всегда)* | HTTP POST + SSE | ключ API |
| `AppleSpeechProvider` | macOS Speech Framework | `apple-speech` | локально | не нужны |
| `MlxProvider` | Qwen3-ASR на MLX (Apple Silicon) | `mlx` | локально | не нужны (локальная модель) |
| `SherpaOnnxProvider` | Sherpa-ONNX | `sherpa-onnx` | локально | не нужны (локальная модель) |
| `WeTypeOfflineProvider` | WeType `embed_140m` (китайский на устройстве) | `wetype-offline`, только для разработчиков, см. ниже | локально | не нужны (скачивает модель) |

## Подключение

Добавьте `velikiy-moguchiy-asr` в свой `Cargo.toml`:

```toml
[dependencies]
velikiy-moguchiy-asr = { git = "https://github.com/zigansh1n/velikiy-moguchiy.git" }
```

Локальные провайдеры включаются функциями:

```toml
[dependencies]
velikiy-moguchiy-asr = { git = "https://github.com/zigansh1n/velikiy-moguchiy.git", features = ["sherpa-onnx"] }
```

## Быстрый старт

### Doubao (облачное распознавание Volcengine)

```rust
use velikiy_moguchiy_asr::{AsrConfig, AsrEvent, AsrProvider, DoubaoWsProvider, TranscriptAggregator};

#[tokio::main]
async fn main() -> Result<(), velikiy_moguchiy_asr::AsrError> {
    let config = AsrConfig {
        app_key: "your-app-key".into(),
        access_key: "your-access-key".into(),
        // Defaults: 16kHz sample rate, DDC/ITN/punctuation/two-pass enabled
        ..Default::default()
    };

    let mut asr = DoubaoWsProvider::new();
    asr.connect(&config).await?;

    // Feed PCM 16-bit LE mono audio in chunks
    // asr.send_audio(&pcm_chunk).await?;

    // Signal end of audio input
    asr.finish_input().await?;

    // Collect results
    let mut aggregator = TranscriptAggregator::new();
    loop {
        match asr.next_event().await? {
            AsrEvent::Interim(text) => aggregator.update_interim(&text),
            AsrEvent::Definite(text) => aggregator.update_definite(&text),
            AsrEvent::Final(text) => {
                aggregator.update_final(&text);
                break;
            }
            AsrEvent::Closed(_) => break,
            _ => {}
        }
    }

    println!("Result: {}", aggregator.best_text());
    asr.close().await?;
    Ok(())
}
```

### Qwen (облачное распознавание Alibaba Cloud)

```rust
use velikiy_moguchiy_asr::{AsrConfig, AsrEvent, AsrProvider, QwenAsrProvider, TranscriptAggregator};

#[tokio::main]
async fn main() -> Result<(), velikiy_moguchiy_asr::AsrError> {
    let config = AsrConfig {
        access_key: "your-dashscope-api-key".into(),
        language: Some("zh".into()),
        ..Default::default()
    };

    let mut asr = QwenAsrProvider::new();
    asr.connect(&config).await?;

    // Same streaming loop as Doubao...
    // asr.send_audio(&pcm_chunk).await?;
    // asr.finish_input().await?;
    // loop { match asr.next_event().await? { ... } }

    asr.close().await?;
    Ok(())
}
```

### Sherpa-ONNX (локально, без сети)

```rust
use velikiy_moguchiy_asr::{AsrConfig, AsrEvent, AsrProvider, SherpaOnnxConfig, SherpaOnnxProvider, TranscriptAggregator};
use std::path::PathBuf;

#[tokio::main]
async fn main() -> Result<(), velikiy_moguchiy_asr::AsrError> {
    let sherpa_config = SherpaOnnxConfig {
        model_dir: PathBuf::from("/path/to/sherpa-onnx-model/"),
        num_threads: 4,
        hotwords: vec!["custom term".into()],
        hotwords_score: 1.5,
        endpoint_silence: 0.8,
    };

    let mut asr = SherpaOnnxProvider::new(sherpa_config);
    // Local providers ignore AsrConfig, but the trait requires it
    asr.connect(&AsrConfig::default()).await?;

    // Same streaming loop...
    asr.close().await?;
    Ok(())
}
```

### WeType (китайский на устройстве, чистый Rust) — только для разработчиков, ни в одном выпуске

> **По умолчанию выключено и никогда не входит в открытую или релизную сборку.** Веса модели
> принадлежат Tencent (WeChat Input Method), восстановлены из её приложения и не имеют лицензии,
> а файлы модели раздаёт сторонний сервер. Код спрятан за функцией Cargo `wetype-offline`: её нет
> ни в одном наборе по умолчанию, ни в сборке приложения для Mac (`MacApp/project.yml`, `Makefile`),
> ни в сборках Apple в CI; без неё не компилируются ни провайдер, ни манифест, который скачал бы веса.
> Включайте её только для своих локальных экспериментов и на свой риск.
>
> DoubaoIME, неофициальный клиент, выдававший себя за Android-клавиатуру ByteDance, удалён по той же
> причине; используйте официальный провайдер Doubao (Volcengine) со своим ключом.


Полностью локальное распознавание китайской речи — реализация на чистом Rust модели
`embed_140m` из WeChat Input Method (40-слойный pre-norm Transformer CTC, восстановленный из её
блоба XNET). Без сети, учётной записи и внешнего движка вывода — только `ndarray` (умножение матриц)
и `rustfft` (FBank). Веса держатся в памяти в int8 (~180 МБ) и общие для всех сеансов. Промежуточные
результаты идут сразу, через собственный **потоковый KV-кэш** модели, а после остановки — итоговый
текст полного качества.

Нужна папка с `embed140m.koepack` (~135 МБ) и `dict.decoder.utf8.txt`; `ensure_and_new` скачивает
их при первом использовании и проверяет SHA-256 (если файлы уже есть, в сеть не ходит).

```rust
use velikiy_moguchiy_asr::wetype::WeTypeOfflineProvider;
use velikiy_moguchiy_asr::{AsrConfig, AsrProvider};

#[tokio::main]
async fn main() -> Result<(), velikiy_moguchiy_asr::AsrError> {
    let mut asr = WeTypeOfflineProvider::ensure_and_new(
        "/path/to/model_dir",
        "https://model.koe.li",            // host serving the two model files
        |file, done, total| {
            if let Some(t) = total {
                eprintln!("{file}: {done}/{t} bytes");
            }
        },
    )
    .await?;

    asr.connect(&AsrConfig::default()).await?;
    // asr.send_audio(&pcm16le_mono_16k).await?;  // Interim results stream live
    asr.finish_input().await?;                    // then a full-quality Final
    // ... standard next_event loop ...
    asr.close().await?;
    Ok(())
}
```

Нужна функция `wetype-offline`. Если файлами модели вы управляете сами, вызывайте
`WeTypeOfflineProvider::new(dir)` напрямую.

## Трейт провайдера

Все провайдеры реализуют трейт `AsrProvider`, поэтому взаимозаменяемы:

```rust
#[async_trait]
pub trait AsrProvider: Send {
    /// Connect to the ASR service (or initialize local model)
    async fn connect(&mut self, config: &AsrConfig) -> Result<()>;
    /// Push a chunk of raw audio (PCM 16-bit LE, mono, 16kHz)
    async fn send_audio(&mut self, frame: &[u8]) -> Result<()>;
    /// Signal that no more audio will be sent
    async fn finish_input(&mut self) -> Result<()>;
    /// Wait for the next recognition event
    async fn next_event(&mut self) -> Result<AsrEvent>;
    /// Close the connection and release resources
    async fn close(&mut self) -> Result<()>;
}
```

Код можно писать без привязки к провайдеру:

```rust
async fn transcribe(asr: &mut dyn AsrProvider, audio: &[u8]) -> Result<String, velikiy_moguchiy_asr::AsrError> {
    asr.connect(&AsrConfig::default()).await?;
    asr.send_audio(audio).await?;
    asr.finish_input().await?;

    let mut aggregator = TranscriptAggregator::new();
    loop {
        match asr.next_event().await? {
            AsrEvent::Interim(t) => aggregator.update_interim(&t),
            AsrEvent::Definite(t) => aggregator.update_definite(&t),
            AsrEvent::Final(t) => { aggregator.update_final(&t); break; }
            AsrEvent::Closed(_) => break,
            _ => {}
        }
    }
    asr.close().await?;
    Ok(aggregator.best_text().to_string())
}
```

## События

Перечисление `AsrEvent` описывает все события потокового распознавания:

| Событие | Что значит |
|---|---|
| `Connected` | соединение установлено или локальная модель загружена |
| `Interim(String)` | промежуточный результат, может измениться с новым звуком |
| `Definite(String)` | подтверждённое предложение из второго прохода (точнее) |
| `Final(String)` | итоговый результат сеанса |
| `Error(String)` | ошибка сервера или провайдера |
| `Closed` | соединение закрыто или сеанс завершён |

## Настройки

`AsrConfig` управляет облачными провайдерами:

```rust
let config = AsrConfig {
    url: "wss://...".into(),              // WebSocket endpoint (provider-specific default)
    app_key: "...".into(),                // App ID (Doubao) or unused (Qwen)
    access_key: "...".into(),             // Access Token (Doubao) or API Key (Qwen)
    resource_id: "...".into(),            // Resource ID (Doubao-specific)
    sample_rate_hz: 16000,                // Audio sample rate in Hz
    connect_timeout_ms: 3000,             // Connection timeout
    final_wait_timeout_ms: 5000,          // Timeout for final result after finish
    enable_ddc: true,                     // Disfluency removal / smoothing
    enable_itn: true,                     // Inverse text normalization (e.g. "三百" → "300")
    enable_punc: true,                    // Automatic punctuation
    enable_nonstream: true,               // Two-pass recognition for higher accuracy
    hotwords: vec!["Velikiy Moguchiy".into()],         // Boost specific terms
    language: Some("zh".into()),          // Language code ("zh", "en", etc.)
    custom_headers: HashMap::new(),       // Custom HTTP headers
};
```

Локальные провайдеры (`MlxProvider`, `AppleSpeechProvider`, `SherpaOnnxProvider`, `WeTypeOfflineProvider`) берут
настройки из своих структур и конструкторов и `AsrConfig` не учитывают.

## TranscriptAggregator

Помощник, который сводит поток событий interim/definite/final в один текст:

```rust
let mut agg = TranscriptAggregator::new();

// As events arrive:
agg.update_interim("hel");
agg.update_interim("hello wo");
agg.update_definite("hello world");     // two-pass confirmed
agg.update_final("hello world.");       // session complete

// Get the best available text (priority: final > definite > interim)
println!("{}", agg.best_text()); // "hello world."

// Check state
agg.has_final_result();  // true
agg.has_any_text();      // true

// Access interim revision history (useful for debugging)
let history = agg.interim_history(10); // last 10 interim snapshots
```

## Ошибки

Все провайдеры возвращают `Result<T, AsrError>`:

```rust
pub enum AsrError {
    Connection(String),  // WebSocket/network or model loading failure
    Timeout,             // Timed out waiting for ASR result
    Protocol(String),    // Binary protocol or server-side error
}
```

## Лицензия

MIT
