use std::ffi::{c_char, c_void, CStr, CString};

use crate::config::AsrConfig;
use crate::error::{AsrError, Result};
use crate::event::AsrEvent;

// ─── C FFI declarations (implemented in Swift MLXBridge package, resolved at link time) ──

#[allow(dead_code)]
extern "C" {
    fn sp_mlx_load_model(model_path: *const c_char) -> i32;
    /// Returns session generation (>0) on success, 0 on failure.
    fn sp_mlx_start_session(
        language: *const c_char,
        delay_preset: *const c_char,
        callback: extern "C" fn(ctx: *mut c_void, event_type: i32, text: *const c_char),
        ctx: *mut c_void,
    ) -> u64;
    fn sp_mlx_feed_audio(samples: *const f32, count: u32, generation: u64);
    fn sp_mlx_stop(generation: u64);
    fn sp_mlx_cancel(generation: u64);
    fn sp_mlx_unload_model();
}

// ─── Event callback trampoline ───────────────────────────────────────

struct MlxEventSenders {
    events: tokio::sync::mpsc::Sender<AsrEvent>,
    terminal_events: tokio::sync::mpsc::UnboundedSender<AsrEvent>,
}

/// C callback that receives events from the Swift layer and forwards them
/// into tokio mpsc channels. Terminal events use an unbounded side channel so
/// interim traffic can never prevent Final/Error/Closed from reaching the
/// consumer and turning a successful recognition into a timeout.
extern "C" fn mlx_event_trampoline(ctx: *mut c_void, event_type: i32, text: *const c_char) {
    let senders = unsafe { &*(ctx as *const MlxEventSenders) };
    let text_str = if text.is_null() {
        String::new()
    } else {
        unsafe { CStr::from_ptr(text) }
            .to_str()
            .unwrap_or("")
            .to_string()
    };
    let event = match event_type {
        0 => AsrEvent::Interim(text_str),
        1 => AsrEvent::Definite(text_str),
        2 => AsrEvent::Final(text_str),
        3 => AsrEvent::Error(text_str),
        4 => AsrEvent::Connected,
        5 => AsrEvent::Closed(None),
        _ => return,
    };
    let is_terminal = matches!(
        &event,
        AsrEvent::Final(_) | AsrEvent::Error(_) | AsrEvent::Closed(_)
    );
    let send_result = if is_terminal {
        senders
            .terminal_events
            .send(event)
            .map_err(|e| e.to_string())
    } else {
        senders.events.try_send(event).map_err(|e| e.to_string())
    };
    if let Err(e) = send_result {
        log::warn!("MLX event delivery failed: {e}");
    }
}

// ─── Provider ────────────────────────────────────────────────────────

/// Configuration for the MLX ASR provider.
#[derive(Debug, Clone)]
pub struct MlxConfig {
    /// Local model path (e.g. ~/.velikiy-moguchiy/models/mlx/Qwen3-ASR-0.6B-4bit)
    pub model_path: String,
    /// Language: "auto", "zh", "en"
    pub language: String,
    /// Delay preset: "realtime", "agent", "subtitle"
    pub delay_preset: String,
}

/// Local streaming ASR provider using Apple MLX.
///
/// The actual MLX inference runs in Swift (MLXBridge package). This Rust
/// provider bridges to it via C FFI functions exposed by `@_cdecl`.
pub struct MlxProvider {
    config: MlxConfig,
    event_rx: Option<tokio::sync::mpsc::Receiver<AsrEvent>>,
    terminal_event_rx: Option<tokio::sync::mpsc::UnboundedReceiver<AsrEvent>>,
    /// Leaked sender bundle passed as callback context.
    /// Reclaimed in close()/drop.
    event_tx_ptr: Option<*mut c_void>,
    /// Session generation returned by the Swift singleton.
    /// Passed to all subsequent FFI calls so stale operations from an old
    /// provider are ignored when a new session has already started.
    session_generation: u64,
}

// Safety: The raw pointer is only accessed from the callback (which is Send)
// and from close()/drop (which takes &mut self).
unsafe impl Send for MlxProvider {}

impl MlxProvider {
    pub fn new(config: MlxConfig) -> Self {
        Self {
            config,
            event_rx: None,
            terminal_event_rx: None,
            event_tx_ptr: None,
            session_generation: 0,
        }
    }

    /// Reclaim the leaked sender to avoid memory leak.
    fn reclaim_sender(&mut self) {
        if let Some(ptr) = self.event_tx_ptr.take() {
            unsafe {
                drop(Box::from_raw(ptr as *mut MlxEventSenders));
            }
        }
    }

    /// Cancel the Swift session (if any) and reclaim the callback context.
    ///
    /// Idempotent: called from both `close()` and `Drop` — the generation is
    /// zeroed after the cancel and the context pointer is `Option::take`n, so
    /// a second call is a no-op.
    ///
    /// SAFETY: `sp_mlx_cancel()` synchronously clears the callback context on
    /// the Swift side under the callback lock, and callback invocation holds
    /// that same lock, so once it returns no further calls through the
    /// callback pointer can occur.  Only then is it safe to free the boxed
    /// senders.  The generation parameter makes a stale cancel a no-op if a
    /// new session has already started on the Swift singleton.
    fn shutdown_session(&mut self) {
        if self.session_generation != 0 {
            unsafe {
                sp_mlx_cancel(self.session_generation);
            }
            self.session_generation = 0;
        }
        self.event_rx = None;
        self.terminal_event_rx = None;
        self.reclaim_sender();
    }
}

#[async_trait::async_trait]
impl crate::provider::AsrProvider for MlxProvider {
    // Local provider: configuration is passed via `new()`, not through AsrConfig.
    // The `_config` parameter is unused here.
    async fn connect(&mut self, _config: &AsrConfig) -> Result<()> {
        let model_path = CString::new(self.config.model_path.clone())
            .map_err(|_| AsrError::Connection("invalid model path".into()))?;

        let ret = unsafe { sp_mlx_load_model(model_path.as_ptr()) };
        if ret != 0 {
            return Err(AsrError::Connection(format!(
                "failed to load MLX model (code {ret}): {}",
                self.config.model_path
            )));
        }

        // Create event channel
        let (tx, rx) = tokio::sync::mpsc::channel::<AsrEvent>(256);
        let (terminal_tx, terminal_rx) = tokio::sync::mpsc::unbounded_channel::<AsrEvent>();
        self.event_rx = Some(rx);
        self.terminal_event_rx = Some(terminal_rx);

        // Leak senders into a raw pointer for the C callback context.
        let tx_box = Box::new(MlxEventSenders {
            events: tx,
            terminal_events: terminal_tx,
        });
        let tx_ptr = Box::into_raw(tx_box) as *mut c_void;
        self.event_tx_ptr = Some(tx_ptr);

        // Start streaming session
        let language = CString::new(self.config.language.clone()).unwrap_or_default();
        let delay_preset = CString::new(self.config.delay_preset.clone()).unwrap_or_default();

        let gen = unsafe {
            sp_mlx_start_session(
                language.as_ptr(),
                delay_preset.as_ptr(),
                mlx_event_trampoline,
                tx_ptr,
            )
        };
        if gen == 0 {
            self.reclaim_sender();
            return Err(AsrError::Connection("failed to start MLX session".into()));
        }
        self.session_generation = gen;

        Ok(())
    }

    async fn send_audio(&mut self, frame: &[u8]) -> Result<()> {
        let samples: Vec<f32> = frame
            .chunks_exact(2)
            .map(|c| i16::from_le_bytes([c[0], c[1]]) as f32 / 32768.0)
            .collect();

        unsafe {
            sp_mlx_feed_audio(
                samples.as_ptr(),
                samples.len() as u32,
                self.session_generation,
            );
        }
        Ok(())
    }

    async fn finish_input(&mut self) -> Result<()> {
        unsafe {
            sp_mlx_stop(self.session_generation);
        }
        Ok(())
    }

    async fn next_event(&mut self) -> Result<AsrEvent> {
        match (&mut self.terminal_event_rx, &mut self.event_rx) {
            (Some(terminal_rx), Some(event_rx)) => tokio::select! {
                biased;
                event = terminal_rx.recv() => event,
                event = event_rx.recv() => event,
            }
            .ok_or(AsrError::Connection("event channel closed".into())),
            _ => Err(AsrError::Connection("not connected".into())),
        }
    }

    async fn close(&mut self) -> Result<()> {
        self.shutdown_session();
        Ok(())
    }
}

impl Drop for MlxProvider {
    fn drop(&mut self) {
        // Must cancel the Swift session before freeing the callback context:
        // if the provider is dropped without close() (e.g. the session task is
        // aborted at runtime shutdown), Swift still holds the raw context
        // pointer and its async tasks would otherwise call into freed memory.
        self.shutdown_session();
    }
}
