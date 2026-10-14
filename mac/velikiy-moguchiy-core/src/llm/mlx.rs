use std::ffi::{c_char, c_float, c_int, CStr, CString};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use crate::errors::{CoreError, Result};
use crate::llm::{CorrectionRequest, LlmProvider};

/// True while a `sp_mlx_llm_generate` call is executing.
///
/// Global (not per-provider) because a fresh `MlxLlmProvider` is constructed
/// for every session, while the Swift `MLXLlmManager` behind the FFI is a
/// process-wide singleton.  A generation detached by timeout keeps running
/// inside Swift; without this gate the next session's request would overlap
/// it on the same model container.
static MLX_GENERATION_IN_FLIGHT: AtomicBool = AtomicBool::new(false);

/// Clears the in-flight flag when the generation closure finishes (normally,
/// by panic, or if the queued closure is dropped without running at runtime
/// shutdown) — including completion *after* the caller's timeout detached it.
struct InFlightGuard;

impl Drop for InFlightGuard {
    fn drop(&mut self) {
        MLX_GENERATION_IN_FLIGHT.store(false, Ordering::Release);
    }
}

// ─── C FFI declarations (implemented in Swift MLXBridge package) ───────

extern "C" {
    fn sp_mlx_llm_generate(
        model_path: *const c_char,
        system_prompt: *const c_char,
        user_prompt: *const c_char,
        temperature: c_float,
        top_p: c_float,
        max_tokens: c_int,
    ) -> *mut c_char;
    fn sp_mlx_llm_free_string(ptr: *mut c_char);
}

// ─── Provider ───────────────────────────────────────────────────────

/// Local LLM correction provider using Apple MLX.
///
/// The actual inference runs in Swift (MLXBridge package). This Rust
/// provider bridges to it via C FFI functions exposed by `@_cdecl`.
pub struct MlxLlmProvider {
    model_path: String,
    temperature: f32,
    top_p: f32,
    max_tokens: i32,
    timeout: Duration,
}

impl MlxLlmProvider {
    pub fn new(
        model_path: String,
        temperature: f64,
        top_p: f64,
        max_tokens: u32,
        timeout_ms: u64,
    ) -> Self {
        Self {
            model_path,
            temperature: temperature as f32,
            top_p: top_p as f32,
            max_tokens: max_tokens as i32,
            timeout: Duration::from_millis(timeout_ms),
        }
    }
}

#[async_trait::async_trait]
impl LlmProvider for MlxLlmProvider {
    async fn correct(&self, request: &CorrectionRequest) -> Result<String> {
        let model_path = self.model_path.clone();
        let system_prompt = request.system_prompt.clone();
        let user_prompt = request.user_prompt.clone();
        let temperature = self.temperature;
        let top_p = self.top_p;
        let max_tokens = self.max_tokens;

        // Overlap gate: fail fast if a previous (possibly timeout-detached)
        // generation is still running in the Swift singleton.  The caller
        // treats this like any other LLM failure and falls back to raw ASR
        // text instead of stacking a second generation on the same model.
        if MLX_GENERATION_IN_FLIGHT
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return Err(CoreError::LlmFailed(
                "previous MLX generation still running".into(),
            ));
        }
        let in_flight_guard = InFlightGuard;

        let blocking_future = tokio::task::spawn_blocking(move || {
            // Owns the flag: released when this closure ends, even if the
            // awaiting future timed out and detached long before.
            let _in_flight_guard = in_flight_guard;
            let c_model = CString::new(model_path)
                .map_err(|_| CoreError::LlmFailed("invalid model path".into()))?;
            let c_sys = CString::new(system_prompt)
                .map_err(|_| CoreError::LlmFailed("invalid system prompt".into()))?;
            let c_user = CString::new(user_prompt)
                .map_err(|_| CoreError::LlmFailed("invalid user prompt".into()))?;

            let ptr = unsafe {
                sp_mlx_llm_generate(
                    c_model.as_ptr(),
                    c_sys.as_ptr(),
                    c_user.as_ptr(),
                    temperature,
                    top_p,
                    max_tokens,
                )
            };

            if ptr.is_null() {
                return Err(CoreError::LlmFailed(
                    "MLX LLM generation returned null".into(),
                ));
            }

            let result = unsafe { CStr::from_ptr(ptr) }
                .to_str()
                .map(|s| s.to_string())
                .map_err(|e| CoreError::LlmFailed(format!("invalid UTF-8 from MLX LLM: {e}")));

            unsafe {
                sp_mlx_llm_free_string(ptr);
            }

            result
        });

        let result = tokio::time::timeout(self.timeout, blocking_future)
            .await
            .map_err(|_| CoreError::LlmTimeout)?
            .map_err(|e| CoreError::LlmFailed(format!("spawn_blocking: {e}")))?;

        // Apply the same output cleaning as the OpenAI provider
        let text = result?;

        // Strip any leading <think>...</think> reasoning block.  Must run
        // before the empty-content guard so an unterminated <think> returns ""
        // and triggers ASR fallback rather than pasting a partial monologue.
        let text = crate::llm::strip_reasoning(&text);

        // Basic output cleaning: trim whitespace, remove wrapping quotes
        let cleaned = text.trim();
        let cleaned = cleaned
            .strip_prefix('"')
            .and_then(|s| s.strip_suffix('"'))
            .unwrap_or(cleaned);
        let cleaned = cleaned
            .strip_prefix('\u{201c}')
            .and_then(|s| s.strip_suffix('\u{201d}'))
            .unwrap_or(cleaned);

        // Reject empty or whitespace-only output so callers fall back to raw
        // ASR text instead of silently erasing the user's utterance.
        if cleaned.trim().is_empty() {
            return Err(CoreError::LlmFailed("empty content in response".into()));
        }

        Ok(cleaned.to_string())
    }
}
