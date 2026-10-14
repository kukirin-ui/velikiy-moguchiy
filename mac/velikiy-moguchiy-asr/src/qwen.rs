use crate::config::AsrConfig;
use crate::error::{AsrError, Result};
use crate::event::AsrEvent;
use crate::key_pool;
use crate::provider::AsrProvider;
use crate::transcript::is_silent_transcript;
use futures_util::{SinkExt, StreamExt};
use serde::Serialize;
use std::collections::VecDeque;
use tokio::time::{timeout, Duration};
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream};
use uuid::Uuid;

type WsStream = WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>;

const SESSION_EVENT_TIMEOUT: Duration = Duration::from_secs(5);

// Omni realtime rejects every default voice except a few (Chelsie, Cherry, Ethan
// fail), even with text-only output; the session errors without a valid one.
const OMNI_VOICE: &str = "Serena";
// Without the worked example the model returns lowercase text with no punctuation
// in most runs; with it, punctuated output was consistent in testing.
const OMNI_DICTATION_INSTRUCTIONS: &str = "Ты — модуль диктовки. Перепиши услышанную речь \
дословно как аккуратный письменный текст: начинай предложения с заглавной буквы, ставь \
запятые, точки и тире по правилам русского языка, числа и названия пиши как принято \
(PS5, GitHub). Не отвечай на содержание и ничего не добавляй. Пример: «привет как дела \
у меня всё хорошо» → «Привет, как дела? У меня всё хорошо.»";

/// Qwen DashScope Realtime ASR Provider (Qwen-ASR-Realtime)
///
/// Protocol follows the Qwen WebSocket Realtime API:
/// 1. Wait for `session.created` after connection
/// 2. Send `session.update` with configuration
/// 3. Append Base64-encoded audio via `input_audio_buffer.append`
/// 4. Send `input_audio_buffer.commit` then `session.finish` when audio ends
///
/// Turn detection is manual: with server VAD every pause produces a final
/// segment, and the session loop stops waiting once any final has arrived,
/// which dropped the tail spoken after the last pause.
///
/// Models whose name contains `omni` run as a text-only Omni realtime session:
/// the gummy input transcription streams the live preview, and on release a
/// `response.create` asks the model for the punctuated final text, which
/// arrives as `response.text.done`. Omni rejects `session.finish`.
pub struct QwenAsrProvider {
    ws: Option<WsStream>,
    input_finished: bool,
    omni: bool,
    pending_events: VecDeque<AsrEvent>,
    gate: SpeechGate,
    active_key: String,
    last_error_key_problem: bool,
}

/// What the Omni speech gate lets through to the session.
#[derive(Debug, PartialEq, Eq)]
enum Gated {
    Delta(String),
    Final(String),
}

/// Keeps the Omni model's reply from reaching the user unless the gummy input
/// transcription heard speech. With VAD off, `response.create` is sent for every
/// recording, and on silence or noise the model answers anyway ("Не расслышал...").
///
/// Deltas are held back until speech is confirmed. A reply that arrives before
/// any transcript is deferred until `response.done`, since the transcription can
/// lag the model; if no speech shows up by then the session is empty.
#[derive(Default)]
struct SpeechGate {
    heard: bool,
    held: Vec<String>,
    deferred_final: Option<String>,
}

impl SpeechGate {
    /// Input transcription text (preview or completed). Returns what it unlocks.
    fn transcript(&mut self, text: &str) -> Vec<Gated> {
        if self.heard || is_silent_transcript(text) {
            return Vec::new();
        }
        self.heard = true;
        let mut out: Vec<Gated> = self.held.drain(..).map(Gated::Delta).collect();
        if let Some(text) = self.deferred_final.take() {
            out.push(Gated::Final(text));
        }
        out
    }

    fn delta(&mut self, delta: &str) -> Option<Gated> {
        if self.heard {
            Some(Gated::Delta(delta.to_string()))
        } else {
            self.held.push(delta.to_string());
            None
        }
    }

    /// `response.text.done`.
    fn done(&mut self, text: &str) -> Option<Gated> {
        if self.heard {
            Some(Gated::Final(text.to_string()))
        } else {
            self.deferred_final = Some(text.to_string());
            None
        }
    }

    /// `response.done`: no more transcript is coming for the reply. A reply still
    /// waiting for speech was a hallucination; an empty final marks the session empty.
    fn response_done(&mut self) -> Option<Gated> {
        self.held.clear();
        self.deferred_final
            .take()
            .map(|_| Gated::Final(String::new()))
    }
}

impl QwenAsrProvider {
    pub fn new() -> Self {
        Self {
            ws: None,
            input_finished: false,
            omni: false,
            pending_events: VecDeque::new(),
            gate: SpeechGate::default(),
            active_key: String::new(),
            last_error_key_problem: false,
        }
    }

    pub fn is_omni_model(model: &str) -> bool {
        model.to_ascii_lowercase().contains("omni")
    }

    /// `input_audio_transcription.corpus`: the user's dictionary terms as
    /// context for the recognizer.
    fn corpus(config: &AsrConfig) -> Option<serde_json::Value> {
        const MAX_CORPUS_CHARS: usize = 1000;
        let mut text = String::new();
        for word in config.hotwords.iter().map(|w| w.trim()).filter(|w| !w.is_empty()) {
            let extra = word.chars().count() + 2;
            if text.chars().count() + extra > MAX_CORPUS_CHARS {
                break;
            }
            if !text.is_empty() {
                text.push_str(", ");
            }
            text.push_str(word);
        }
        (!text.is_empty()).then(|| serde_json::json!({ "text": text }))
    }

    fn build_session_update(config: &AsrConfig) -> ClientEvent {
        let language = config.language.clone().unwrap_or_else(|| "zh".to_string());
        let corpus = Self::corpus(config);
        if Self::is_omni_model(&config.app_key) {
            return ClientEvent {
                event_id: format!("event_{}", Uuid::new_v4()),
                event_type: "session.update".to_string(),
                audio: None,
                session: Some(serde_json::json!({
                    "modalities": ["text"],
                    "voice": OMNI_VOICE,
                    "input_audio_format": "pcm",
                    "sample_rate": config.sample_rate_hz,
                    "input_audio_transcription": Self::transcription_settings(
                        serde_json::json!({ "language": language }),
                        corpus,
                    ),
                    "instructions": config
                        .instructions
                        .as_deref()
                        .unwrap_or(OMNI_DICTATION_INSTRUCTIONS),
                    "turn_detection": serde_json::Value::Null,
                })),
            };
        }
        ClientEvent {
            event_id: format!("event_{}", Uuid::new_v4()),
            event_type: "session.update".to_string(),
            audio: None,
            session: Some(serde_json::json!({
                "modalities": ["text"],
                "input_audio_format": "pcm",
                "sample_rate": config.sample_rate_hz,
                "input_audio_transcription": Self::transcription_settings(
                    serde_json::json!({ "model": config.app_key, "language": language }),
                    corpus,
                ),
                "turn_detection": serde_json::Value::Null
            })),
        }
    }

    fn transcription_settings(
        mut base: serde_json::Value,
        corpus: Option<serde_json::Value>,
    ) -> serde_json::Value {
        if let Some(corpus) = corpus {
            base["corpus"] = corpus;
        }
        base
    }

    fn build_audio_append(audio_data: &[u8]) -> ClientEvent {
        use base64::{engine::general_purpose::STANDARD, Engine};
        ClientEvent {
            event_id: format!("event_{}", Uuid::new_v4()),
            event_type: "input_audio_buffer.append".to_string(),
            audio: Some(STANDARD.encode(audio_data)),
            session: None,
        }
    }

    fn build_commit() -> ClientEvent {
        ClientEvent {
            event_id: format!("event_{}", Uuid::new_v4()),
            event_type: "input_audio_buffer.commit".to_string(),
            audio: None,
            session: None,
        }
    }

    fn build_response_create() -> ClientEvent {
        ClientEvent {
            event_id: format!("event_{}", Uuid::new_v4()),
            event_type: "response.create".to_string(),
            audio: None,
            session: None,
        }
    }

    fn build_session_finish() -> ClientEvent {
        ClientEvent {
            event_id: format!("event_{}", Uuid::new_v4()),
            event_type: "session.finish".to_string(),
            audio: None,
            session: None,
        }
    }

    fn parse_server_event(&mut self, text: &str) -> Result<Vec<AsrEvent>> {
        log::debug!("[Qwen ASR] Received: {}", text);

        let raw_json: serde_json::Value = serde_json::from_str(text)
            .map_err(|e| AsrError::Protocol(format!("parse server event: {e}")))?;

        let event_type = raw_json
            .get("type")
            .and_then(|t| t.as_str())
            .unwrap_or("unknown");

        let mut events = Vec::new();

        match event_type {
            "session.created" => {
                log::info!("[Qwen ASR] Session created");
            }
            "session.updated" => {
                log::info!("[Qwen ASR] Session updated");
                events.push(AsrEvent::Connected);
            }
            "input_audio_buffer.speech_started" => {
                log::debug!("[Qwen ASR] Speech started");
            }
            "input_audio_buffer.speech_stopped" => {
                log::debug!("[Qwen ASR] Speech stopped");
            }
            "input_audio_buffer.committed" => {
                log::debug!("[Qwen ASR] Audio buffer committed");
            }
            "conversation.item.created" => {
                log::debug!("[Qwen ASR] Conversation item created");
            }
            "conversation.item.input_audio_transcription.text"
            | "conversation.item.input_audio_transcription.delta" => {
                let text = raw_json.get("text").and_then(|v| v.as_str()).unwrap_or("");
                let stash = raw_json.get("stash").and_then(|v| v.as_str()).unwrap_or("");
                let preview = format!("{text}{stash}");
                if !preview.is_empty() {
                    if self.omni {
                        let unlocked = self.gate.transcript(&preview);
                        events.push(AsrEvent::Interim(preview));
                        events.extend(unlocked.into_iter().map(Self::gated_event));
                    } else {
                        events.push(AsrEvent::Interim(preview));
                    }
                }
            }
            "conversation.item.input_audio_transcription.completed" => {
                let transcript = raw_json
                    .get("transcript")
                    .and_then(|v| v.as_str())
                    .or_else(|| {
                        raw_json
                            .get("item")
                            .and_then(|i| i.get("content"))
                            .and_then(|c| c.as_array())
                            .and_then(|arr| arr.first())
                            .and_then(|content| content.get("transcript"))
                            .and_then(|v| v.as_str())
                    })
                    .unwrap_or("");

                if self.omni {
                    // Raw gummy transcript; the final text comes from the response.
                    if !transcript.is_empty() {
                        let unlocked = self.gate.transcript(transcript);
                        events.push(AsrEvent::Interim(transcript.to_string()));
                        events.extend(unlocked.into_iter().map(Self::gated_event));
                    }
                } else if !transcript.is_empty() {
                    log::info!("[Qwen ASR] Final: {} chars", transcript.chars().count());
                    log::debug!("[Qwen ASR] Final text: {}", transcript);
                    events.push(AsrEvent::Definite(transcript.to_string()));
                    events.push(AsrEvent::Final(transcript.to_string()));
                }
            }
            "response.text.delta" => {
                let delta = raw_json.get("delta").and_then(|v| v.as_str()).unwrap_or("");
                if !delta.is_empty() {
                    if self.omni {
                        events.extend(self.gate.delta(delta).map(Self::gated_event));
                    } else {
                        events.push(AsrEvent::FinalDelta(delta.to_string()));
                    }
                }
            }
            "response.text.done" => {
                let text = raw_json.get("text").and_then(|v| v.as_str()).unwrap_or("");
                log::info!("[Qwen Omni] Final: {} chars", text.chars().count());
                if self.omni {
                    // Definite carries the same text; the aggregator treats the
                    // pair as one result.
                    if let Some(gated) = self.gate.done(text) {
                        events.push(AsrEvent::Definite(text.to_string()));
                        events.push(Self::gated_event(gated));
                    }
                } else {
                    events.push(AsrEvent::Definite(text.to_string()));
                    events.push(AsrEvent::Final(text.to_string()));
                }
            }
            "response.done" => {
                if self.omni {
                    if let Some(empty) = self.gate.response_done() {
                        log::warn!(
                            "[Qwen Omni] no speech in the input transcription; dropping the model reply"
                        );
                        events.push(Self::gated_event(empty));
                    }
                }
                events.push(AsrEvent::Closed(None));
            }
            "session.finished" => {
                log::info!("[Qwen ASR] Session finished");
                events.push(AsrEvent::Closed(None));
            }
            "error" => {
                let error = raw_json.get("error");
                let message = error
                    .and_then(|e| e.get("message"))
                    .and_then(|m| m.as_str())
                    .unwrap_or("Unknown error");
                let code = error
                    .and_then(|e| e.get("code"))
                    .and_then(|c| c.as_str())
                    .unwrap_or("");
                log::error!("[Qwen ASR] Error: {} {}", code, message);
                self.last_error_key_problem = key_pool::error_event_is_key_problem(code, message);
                if self.last_error_key_problem && !self.active_key.is_empty() {
                    key_pool::global()
                        .lock()
                        .unwrap()
                        .mark_failed(&self.active_key, std::time::Instant::now());
                }
                events.push(AsrEvent::Error(message.to_string()));
            }
            other => {
                log::debug!("[Qwen ASR] Ignoring event type: {}", other);
            }
        }

        Ok(events)
    }

    fn gated_event(gated: Gated) -> AsrEvent {
        match gated {
            Gated::Delta(delta) => AsrEvent::FinalDelta(delta),
            Gated::Final(text) => AsrEvent::Final(text),
        }
    }

    async fn read_text_event(ws: &mut WsStream, timeout_duration: Duration) -> Result<String> {
        match timeout(timeout_duration, ws.next()).await {
            Ok(Some(Ok(Message::Text(text)))) => Ok(text.to_string()),
            Ok(Some(Ok(Message::Close(frame)))) => Err(AsrError::Connection(format!(
                "connection closed unexpectedly: {:?}",
                frame
            ))),
            Ok(Some(Ok(_))) => Err(AsrError::Connection(
                "expected text message from server".into(),
            )),
            Ok(Some(Err(e))) => Err(AsrError::Connection(format!("WebSocket error: {e}"))),
            Ok(None) => Err(AsrError::Connection("connection closed".into())),
            Err(_) => Err(AsrError::Connection(
                "timeout waiting for server event".into(),
            )),
        }
    }

    async fn send_client_event(&mut self, event: ClientEvent) -> Result<()> {
        let msg_text = serde_json::to_string(&event)
            .map_err(|e| AsrError::Protocol(format!("serialize client event: {e}")))?;

        if let Some(ref mut ws) = self.ws {
            ws.send(Message::Text(msg_text.into()))
                .await
                .map_err(|e| AsrError::Protocol(format!("send client event: {e}")))?;
            Ok(())
        } else {
            Err(AsrError::Connection("not connected".into()))
        }
    }
}

impl Default for QwenAsrProvider {
    fn default() -> Self {
        Self::new()
    }
}

/// One failed connection attempt with one key.
struct Attempt {
    error: AsrError,
    key_problem: bool,
}

impl Attempt {
    fn other(error: AsrError) -> Self {
        Self {
            error,
            key_problem: false,
        }
    }
}

impl QwenAsrProvider {
    fn effective_keys(config: &AsrConfig) -> Vec<String> {
        let keys: Vec<String> = config
            .access_keys
            .iter()
            .map(|k| k.trim().to_string())
            .filter(|k| !k.is_empty())
            .collect();
        if keys.is_empty() && !config.access_key.is_empty() {
            vec![config.access_key.clone()]
        } else {
            keys
        }
    }

    async fn connect_with_key(
        &mut self,
        config: &AsrConfig,
        api_key: &str,
    ) -> std::result::Result<(), Attempt> {
        use tokio_tungstenite::tungstenite::Error as WsError;

        let ws_url = format!("{}?model={}", config.url, config.app_key);
        log::info!("Connecting to Qwen ASR: {}", ws_url);

        let mut request = ws_url
            .into_client_request()
            .map_err(|e| Attempt::other(AsrError::Connection(format!("invalid URL: {e}"))))?;

        if config.custom_headers.is_empty() {
            request.headers_mut().insert(
                "Authorization",
                format!("Bearer {}", api_key)
                    .parse()
                    .map_err(|_| Attempt::other(AsrError::Connection("invalid api_key".into())))?,
            );
        } else {
            for (key, value) in &config.custom_headers {
                let header_name: tokio_tungstenite::tungstenite::http::HeaderName =
                    key.parse().map_err(|_| {
                        Attempt::other(AsrError::Connection(format!("invalid header name: {key}")))
                    })?;
                request.headers_mut().insert(
                    header_name,
                    value.parse().map_err(|_| {
                        Attempt::other(AsrError::Connection(format!(
                            "invalid header value for {key}"
                        )))
                    })?,
                );
            }
        }

        let connected = timeout(Duration::from_millis(config.connect_timeout_ms), async {
            // Resolves the host and races its addresses (IPv4 first) instead
            // of letting a dead IPv6 route eat the whole connect budget.
            crate::net_connect::connect_websocket(request).await
        })
        .await
        .map_err(|_| Attempt::other(AsrError::Connection("connection timed out".into())))?;
        let (ws_stream, response) = connected.map_err(|e| {
            let key_problem = match &e {
                WsError::Http(response) => {
                    let body = response
                        .body()
                        .as_deref()
                        .map(String::from_utf8_lossy)
                        .unwrap_or_default();
                    key_pool::http_failure_is_key_problem(response.status().as_u16(), &body)
                }
                _ => false,
            };
            Attempt {
                error: AsrError::Connection(e.to_string()),
                key_problem,
            }
        })?;

        log::info!("[Qwen ASR] WebSocket connected: {}", response.status());
        self.ws = Some(ws_stream);

        if let Some(ref mut ws) = self.ws {
            let created_text = Self::read_text_event(ws, SESSION_EVENT_TIMEOUT)
                .await
                .map_err(Attempt::other)?;
            let created_json: serde_json::Value = serde_json::from_str(&created_text)
                .map_err(|e| Attempt::other(AsrError::Protocol(format!("parse session.created: {e}"))))?;
            let created_type = created_json
                .get("type")
                .and_then(|v| v.as_str())
                .unwrap_or("unknown");

            if created_type != "session.created" {
                let error = created_json.get("error");
                let message = error
                    .and_then(|e| e.get("message"))
                    .and_then(|m| m.as_str())
                    .unwrap_or("expected session.created event");
                let code = error
                    .and_then(|e| e.get("code"))
                    .and_then(|c| c.as_str())
                    .unwrap_or("");
                return Err(Attempt {
                    error: AsrError::Connection(message.to_string()),
                    key_problem: key_pool::error_event_is_key_problem(code, message),
                });
            }
        }

        self.send_client_event(Self::build_session_update(config))
            .await
            .map_err(Attempt::other)?;

        loop {
            let event = self.next_event().await.map_err(Attempt::other)?;
            match event {
                AsrEvent::Connected => break,
                AsrEvent::Error(msg) => {
                    let key_problem = std::mem::take(&mut self.last_error_key_problem);
                    return Err(Attempt {
                        error: AsrError::Protocol(msg),
                        key_problem,
                    });
                }
                AsrEvent::Closed(reason) => {
                    return Err(Attempt::other(AsrError::Connection(
                        reason
                            .map(|r| format!("connection closed before session.updated: {r}"))
                            .unwrap_or_else(|| "connection closed before session.updated".into()),
                    )))
                }
                AsrEvent::Interim(_)
                | AsrEvent::Definite(_)
                | AsrEvent::FinalDelta(_)
                | AsrEvent::Final(_) => {
                    log::debug!("[Qwen ASR] Received transcript before session.updated");
                }
            }
        }
        Ok(())
    }
}

#[async_trait::async_trait]
impl AsrProvider for QwenAsrProvider {
    async fn connect(&mut self, config: &AsrConfig) -> Result<()> {
        let mut keys = Self::effective_keys(config);
        if keys.is_empty() {
            return Err(AsrError::Connection("api_key is required".into()));
        }
        if !config.custom_headers.is_empty() {
            keys.truncate(1);
        }

        crate::endpoint::validate_endpoint_url(&config.url).map_err(AsrError::Connection)?;
        self.omni = Self::is_omni_model(&config.app_key);
        self.gate = SpeechGate::default();

        let order = key_pool::global()
            .lock()
            .unwrap()
            .order(&keys, std::time::Instant::now());
        let mut last_error = None;
        for (attempt, &index) in order.iter().enumerate() {
            let key = &keys[index];
            if keys.len() > 1 {
                log::info!("[Qwen ASR] using key #{}", index + 1);
            }
            self.ws = None;
            self.pending_events.clear();
            self.active_key = key.clone();
            match self.connect_with_key(config, key).await {
                Ok(()) => {
                    key_pool::global().lock().unwrap().mark_working(key);
                    log::info!("Qwen ASR connected and configured");
                    return Ok(());
                }
                Err(failure) => {
                    if let Some(mut ws) = self.ws.take() {
                        let _ = ws.close(None).await;
                    }
                    if !failure.key_problem {
                        return Err(failure.error);
                    }
                    key_pool::global()
                        .lock()
                        .unwrap()
                        .mark_failed(key, std::time::Instant::now());
                    log::warn!(
                        "[Qwen ASR] key #{} rejected ({}){}",
                        index + 1,
                        failure.error,
                        if attempt + 1 < order.len() {
                            ", trying the next key"
                        } else {
                            ""
                        }
                    );
                    last_error = Some(failure.error);
                }
            }
        }
        Err(last_error.unwrap_or_else(|| AsrError::Connection("api_key is required".into())))
    }

    async fn send_audio(&mut self, frame: &[u8]) -> Result<()> {
        if frame.is_empty() {
            return Ok(());
        }

        self.send_client_event(Self::build_audio_append(frame))
            .await
    }

    async fn finish_input(&mut self) -> Result<()> {
        if self.input_finished {
            return Ok(());
        }

        self.input_finished = true;
        self.send_client_event(Self::build_commit()).await?;
        if self.omni {
            self.send_client_event(Self::build_response_create()).await
        } else {
            self.send_client_event(Self::build_session_finish()).await
        }
    }

    async fn next_event(&mut self) -> Result<AsrEvent> {
        if let Some(event) = self.pending_events.pop_front() {
            return Ok(event);
        }

        loop {
            let msg = self
                .ws
                .as_mut()
                .ok_or_else(|| AsrError::Connection("not connected".into()))?
                .next()
                .await;

            match msg {
                Some(Ok(Message::Text(text))) => {
                    let events = self.parse_server_event(&text)?;
                    self.pending_events.extend(events);
                    if let Some(event) = self.pending_events.pop_front() {
                        return Ok(event);
                    }
                    log::debug!("[Qwen ASR] Skipping text frame with no parseable events");
                }
                Some(Ok(Message::Close(frame))) => {
                    let reason = frame
                        .as_ref()
                        .map(|f| format!("code={}, reason={:?}", f.code, f.reason));
                    return Ok(AsrEvent::Closed(reason));
                }
                Some(Ok(Message::Binary(data))) => {
                    log::debug!("[Qwen ASR] Skipping binary frame ({} bytes)", data.len());
                }
                Some(Ok(frame)) => {
                    log::debug!("[Qwen ASR] Skipping frame: {:?}", frame);
                }
                Some(Err(e)) => return Err(AsrError::Protocol(e.to_string())),
                None => return Ok(AsrEvent::Closed(Some("WebSocket stream ended".into()))),
            }
        }
    }

    async fn close(&mut self) -> Result<()> {
        if let Some(mut ws) = self.ws.take() {
            let _ = ws.close(None).await;
        }
        Ok(())
    }
}

#[derive(Serialize)]
struct ClientEvent {
    #[serde(rename = "event_id")]
    event_id: String,
    #[serde(rename = "type")]
    event_type: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    audio: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    session: Option<serde_json::Value>,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn omni() -> QwenAsrProvider {
        let mut p = QwenAsrProvider::new();
        p.omni = true;
        p
    }

    fn feed(p: &mut QwenAsrProvider, json: serde_json::Value) -> Vec<AsrEvent> {
        p.parse_server_event(&json.to_string()).unwrap()
    }

    fn describe(events: &[AsrEvent]) -> Vec<String> {
        events
            .iter()
            .map(|e| match e {
                AsrEvent::Interim(t) => format!("interim:{t}"),
                AsrEvent::Definite(t) => format!("definite:{t}"),
                AsrEvent::FinalDelta(t) => format!("delta:{t}"),
                AsrEvent::Final(t) => format!("final:{t}"),
                AsrEvent::Closed(_) => "closed".into(),
                AsrEvent::Connected => "connected".into(),
                AsrEvent::Error(m) => format!("error:{m}"),
            })
            .collect()
    }

    #[test]
    fn omni_detection_is_case_insensitive() {
        assert!(QwenAsrProvider::is_omni_model("qwen3.8-omni-flash-realtime"));
        assert!(QwenAsrProvider::is_omni_model("Qwen-Omni-Flash"));
        assert!(!QwenAsrProvider::is_omni_model("qwen3-asr-flash-realtime"));
    }

    #[test]
    fn spoken_session_passes_deltas_and_final() {
        let mut p = omni();
        let mut out = Vec::new();
        out.extend(feed(
            &mut p,
            serde_json::json!({"type": "conversation.item.input_audio_transcription.text",
                               "text": "привет", "stash": ""}),
        ));
        out.extend(feed(
            &mut p,
            serde_json::json!({"type": "response.text.delta", "delta": "Привет"}),
        ));
        out.extend(feed(
            &mut p,
            serde_json::json!({"type": "response.text.done", "text": "Привет."}),
        ));
        assert_eq!(
            describe(&out),
            ["interim:привет", "delta:Привет", "definite:Привет.", "final:Привет."]
        );
    }

    #[test]
    fn silent_session_drops_reply_and_marks_empty() {
        let mut p = omni();
        let mut out = Vec::new();
        out.extend(feed(
            &mut p,
            serde_json::json!({"type": "response.text.delta", "delta": "Не расслышал"}),
        ));
        out.extend(feed(
            &mut p,
            serde_json::json!({"type": "conversation.item.input_audio_transcription.completed",
                               "transcript": "  "}),
        ));
        out.extend(feed(
            &mut p,
            serde_json::json!({"type": "response.text.done", "text": "Не расслышал, повторите."}),
        ));
        out.extend(feed(&mut p, serde_json::json!({"type": "response.done"})));
        assert_eq!(describe(&out), ["interim:  ", "final:", "closed"]);
    }

    #[test]
    fn punctuation_only_transcript_counts_as_silence() {
        let mut p = omni();
        let mut out = feed(
            &mut p,
            serde_json::json!({"type": "conversation.item.input_audio_transcription.completed",
                               "transcript": "..."}),
        );
        out.extend(feed(
            &mut p,
            serde_json::json!({"type": "response.text.done", "text": "Тишина."}),
        ));
        out.extend(feed(&mut p, serde_json::json!({"type": "response.done"})));
        assert!(describe(&out).contains(&"final:".to_string()));
        assert!(!describe(&out).iter().any(|e| e.contains("Тишина")));
    }

    #[test]
    fn late_transcript_releases_the_deferred_reply() {
        let mut p = omni();
        let mut out = Vec::new();
        out.extend(feed(
            &mut p,
            serde_json::json!({"type": "response.text.delta", "delta": "Да"}),
        ));
        out.extend(feed(
            &mut p,
            serde_json::json!({"type": "response.text.done", "text": "Да."}),
        ));
        assert!(out.is_empty());
        out.extend(feed(
            &mut p,
            serde_json::json!({"type": "conversation.item.input_audio_transcription.completed",
                               "transcript": "да"}),
        ));
        out.extend(feed(&mut p, serde_json::json!({"type": "response.done"})));
        assert_eq!(describe(&out), ["interim:да", "delta:Да", "final:Да.", "closed"]);
    }

    #[test]
    fn non_omni_sessions_are_not_gated() {
        let mut p = QwenAsrProvider::new();
        let out = feed(
            &mut p,
            serde_json::json!({"type": "conversation.item.input_audio_transcription.completed",
                               "transcript": "привет"}),
        );
        assert_eq!(describe(&out), ["definite:привет", "final:привет"]);
    }
}
