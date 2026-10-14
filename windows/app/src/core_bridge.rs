//! The shared Rust core, driven through the same `sp_core_*` entry points the
//! Mac app calls from Objective-C. Core callbacks arrive on its worker threads
//! and are forwarded to one sink, which hands them to the UI thread.

use crate::controller::CoreEvent;
use std::ffi::{c_char, c_void, CStr, CString};
use std::sync::Mutex;
use velikiy_moguchiy_core::ffi::{SPCallbacks, SPSessionContext, SPSessionMode};
use velikiy_moguchiy_core::{config, model_manager};

#[derive(Debug, Clone, PartialEq)]
pub enum DownloadEvent {
    /// Bytes of the current file.
    Progress {
        file_index: u32,
        file_count: u32,
        done: u64,
        total: u64,
    },
    Finished,
    Failed(String),
}

#[derive(Debug, Clone, PartialEq)]
pub enum BridgeEvent {
    Core(CoreEvent),
    Download(DownloadEvent),
}

type Sink = Box<dyn Fn(BridgeEvent) + Send>;

static SINK: Mutex<Option<Sink>> = Mutex::new(None);

fn emit(event: BridgeEvent) {
    if let Some(sink) = SINK.lock().unwrap_or_else(|e| e.into_inner()).as_ref() {
        sink(event);
    }
}

fn text(ptr: *const c_char) -> String {
    if ptr.is_null() {
        return String::new();
    }
    unsafe { CStr::from_ptr(ptr) }
        .to_string_lossy()
        .into_owned()
}

extern "C" fn on_session_ready(token: u64) {
    emit(BridgeEvent::Core(CoreEvent::Ready(token)));
}

extern "C" fn on_session_error(token: u64, message: *const c_char) {
    emit(BridgeEvent::Core(CoreEvent::Error(token, text(message))));
}

extern "C" fn on_session_warning(token: u64, message: *const c_char) {
    emit(BridgeEvent::Core(CoreEvent::Warning(token, text(message))));
}

extern "C" fn on_final_text_ready(token: u64, t: *const c_char) {
    emit(BridgeEvent::Core(CoreEvent::Final(token, text(t))));
}

extern "C" fn on_log_event(level: i32, message: *const c_char) {
    let level = match level {
        0 => log::Level::Error,
        1 => log::Level::Warn,
        2 => log::Level::Info,
        _ => log::Level::Debug,
    };
    log::log!(level, "core: {}", text(message));
}

extern "C" fn on_state_changed(token: u64, state: *const c_char) {
    emit(BridgeEvent::Core(CoreEvent::State(token, text(state))));
}

extern "C" fn on_interim_text(token: u64, t: *const c_char) {
    emit(BridgeEvent::Core(CoreEvent::Interim(token, text(t))));
}

extern "C" fn on_text_delivery(token: u64, kind: u8, remainder: *const c_char) {
    emit(BridgeEvent::Core(CoreEvent::Delivery {
        token,
        kind,
        remainder: text(remainder),
    }));
}

/// Starts the core and routes its callbacks to `sink`. Returns false when the
/// core could not start (no async runtime, no HTTP client).
pub fn start(sink: impl Fn(BridgeEvent) + Send + 'static) -> bool {
    *SINK.lock().unwrap_or_else(|e| e.into_inner()) = Some(Box::new(sink));
    let created = unsafe { velikiy_moguchiy_core::sp_core_create(std::ptr::null()) };
    velikiy_moguchiy_core::sp_core_register_callbacks(SPCallbacks {
        on_session_ready: Some(on_session_ready),
        on_session_error: Some(on_session_error),
        on_session_warning: Some(on_session_warning),
        on_final_text_ready: Some(on_final_text_ready),
        on_log_event: Some(on_log_event),
        on_state_changed: Some(on_state_changed),
        on_interim_text: Some(on_interim_text),
        on_asr_final_text: None,
        on_rewrite_text_ready: None,
        on_session_result_meta: None,
        on_text_delivery: Some(on_text_delivery),
    });
    created == 0
}

pub fn shutdown() {
    velikiy_moguchiy_core::sp_core_destroy();
    *SINK.lock().unwrap_or_else(|e| e.into_inner()) = None;
}

pub fn reload_config() {
    if velikiy_moguchiy_core::sp_core_reload_config() != 0 {
        log::warn!("config reload failed; the next session reads it again");
    }
}

pub fn begin_session(token: u64, hands_free: bool, app_id: Option<&str>) -> bool {
    let app_id = app_id.and_then(|s| CString::new(s).ok());
    let context = SPSessionContext {
        mode: if hands_free {
            SPSessionMode::Toggle
        } else {
            SPSessionMode::Hold
        },
        frontmost_bundle_id: app_id.as_ref().map_or(std::ptr::null(), |s| s.as_ptr()),
        frontmost_pid: 0,
        session_token: token,
    };
    velikiy_moguchiy_core::sp_core_session_begin(context) >= 0
}

pub fn end_session() {
    velikiy_moguchiy_core::sp_core_session_end();
}

pub fn cancel_session() {
    velikiy_moguchiy_core::sp_core_session_cancel();
}

/// One frame of 16 kHz mono PCM16 for recognition.
pub fn push_audio(samples: &[i16]) {
    if samples.is_empty() {
        return;
    }
    let bytes = crate::audio::pcm_bytes(samples);
    unsafe {
        velikiy_moguchiy_core::sp_core_push_audio(bytes.as_ptr(), bytes.len() as u32, 0);
    }
}

/// Feeds the level meter and the end-of-speech detector.
pub fn feed_levels(samples: &[i16]) {
    if samples.is_empty() {
        return;
    }
    unsafe {
        velikiy_moguchiy_core::sp_core_feed_mic_levels(samples.as_ptr(), samples.len() as u32);
    }
}

pub const LEVEL_BUCKETS: usize = 16;

pub fn mic_levels() -> [f32; LEVEL_BUCKETS] {
    let mut out = [0.0f32; LEVEL_BUCKETS];
    unsafe {
        velikiy_moguchiy_core::sp_core_get_mic_levels(out.as_mut_ptr(), LEVEL_BUCKETS as u32);
    }
    out
}

pub fn reset_mic_levels() {
    velikiy_moguchiy_core::sp_core_reset_mic_levels();
}

/// `recording.auto_stop_silence_s` decides the timeout; off when it is 0.
pub fn arm_silence_stop(on: bool) {
    let seconds = if on {
        velikiy_moguchiy_core::sp_core_silence_stop_seconds()
    } else {
        0.0
    };
    velikiy_moguchiy_core::sp_core_silence_stop_arm(seconds);
}

pub fn silence_stop_fired() -> bool {
    velikiy_moguchiy_core::sp_core_silence_stop_fired()
}

pub fn config_flag(key: &str) -> bool {
    config::config_flag(key)
}

/// How long to wait before putting the user's clipboard back after a paste;
/// `None` when the dictated text stays on the clipboard
/// (`clipboard.keep_last_dictation`, on unless set to false).
pub fn clipboard_restore_delay_ms() -> Option<u32> {
    let keep = config::config_get("clipboard.keep_last_dictation").unwrap_or_default();
    if keep.trim().is_empty() || config::config_flag("clipboard.keep_last_dictation") {
        return None;
    }
    Some(velikiy_moguchiy_core::sp_core_get_clipboard_config().restore_delay_ms)
}

/// 0 = not downloaded, 1 = incomplete, 2 = ready.
pub fn model_status(model: &str) -> i32 {
    let dir = config::resolve_model_dir(model);
    model_manager::model_status(&dir, model_manager::VerifyMode::CacheOnly) as i32
}

/// File index and percent last reported, so that the UI hears about whole
/// percents, not every network chunk.
static LAST_PROGRESS: Mutex<(u32, u64)> = Mutex::new((u32::MAX, u64::MAX));

extern "C" fn on_download_progress(
    _ctx: *mut c_void,
    file_index: u32,
    file_count: u32,
    done: u64,
    total: u64,
    _filename: *const c_char,
) {
    let percent = (done * 100).checked_div(total).unwrap_or(0);
    {
        let mut last = LAST_PROGRESS.lock().unwrap_or_else(|e| e.into_inner());
        if *last == (file_index, percent) {
            return;
        }
        *last = (file_index, percent);
    }
    emit(BridgeEvent::Download(DownloadEvent::Progress {
        file_index,
        file_count,
        done,
        total,
    }));
}

extern "C" fn on_download_status(_ctx: *mut c_void, status: i32, message: *const c_char) {
    match status {
        1 => emit(BridgeEvent::Download(DownloadEvent::Finished)),
        2 | 3 => emit(BridgeEvent::Download(DownloadEvent::Failed(text(message)))),
        _ => {}
    }
}

/// Starts downloading `model` (a path under the models folder). False when it
/// is already downloading or could not start.
pub fn download_model(model: &str) -> bool {
    let Ok(path) = CString::new(model) else {
        return false;
    };
    let started = unsafe {
        velikiy_moguchiy_core::sp_core_download_model(
            path.as_ptr(),
            on_download_progress,
            on_download_status,
            std::ptr::null_mut(),
        )
    };
    started == 0
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings::tests::TempHome;
    use std::sync::mpsc;
    use std::time::Duration;

    #[test]
    fn core_starts_and_reports_a_session_without_a_key_as_an_error() {
        let _home = TempHome::new("bridge");
        let (tx, rx) = mpsc::channel();
        let tx = Mutex::new(tx);
        assert!(start(move |e| {
            let _ = tx.lock().unwrap().send(e);
        }));
        assert!(begin_session(1, false, Some("win:notepad.exe")));
        push_audio(&[0i16; crate::audio::FRAME_SAMPLES]);
        end_session();
        let mut saw_error = false;
        while let Ok(event) = rx.recv_timeout(Duration::from_secs(10)) {
            if let BridgeEvent::Core(CoreEvent::Error(1, _)) = event {
                saw_error = true;
            }
            if let BridgeEvent::Core(CoreEvent::State(1, s)) = &event {
                if s == "failed" {
                    break;
                }
            }
        }
        assert!(saw_error);
        assert_eq!(clipboard_restore_delay_ms(), None);
        assert_eq!(model_status(crate::settings::LOCAL_MODEL), 0);
        shutdown();
    }
}
