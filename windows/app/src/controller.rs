//! The dictation session as the user sees it: hotkey gestures in, core
//! callbacks in, microphone / overlay / paste out. No Win32 here, so the whole
//! flow is tested on any OS with [`Host`] faked.

use crate::hotkey::Gesture;

/// The window that had focus when the recording began; the text goes there.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Target {
    /// Opaque window handle.
    pub window: isize,
    /// See [`crate::app_id::app_id_for_exe`].
    pub app_id: Option<String>,
}

/// Session callbacks of the core, already copied out of C strings.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CoreEvent {
    Ready(u64),
    State(u64, String),
    Interim(u64, String),
    Delivery {
        token: u64,
        kind: u8,
        remainder: String,
    },
    Final(u64, String),
    Error(u64, String),
    Warning(u64, String),
}

impl CoreEvent {
    fn token(&self) -> u64 {
        match self {
            CoreEvent::Ready(t)
            | CoreEvent::State(t, _)
            | CoreEvent::Interim(t, _)
            | CoreEvent::Delivery { token: t, .. }
            | CoreEvent::Final(t, _)
            | CoreEvent::Error(t, _)
            | CoreEvent::Warning(t, _) => *t,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OverlayMode {
    /// Recording; the shell draws the level meter.
    Listening,
    Recognizing,
    Correcting,
    /// The inserted text.
    Result,
    /// Something to read that is not an error (text left in the clipboard).
    Notice,
    Error,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OverlayView {
    pub mode: OverlayMode,
    pub text: String,
    /// Recording without the key held: the next press ends it.
    pub hands_free: bool,
}

/// Everything the controller does to the outside world.
pub trait Host {
    /// `sp_core_session_begin`; false when the core refused.
    fn begin_session(&mut self, token: u64, hands_free: bool, app_id: Option<&str>) -> bool;
    fn end_session(&mut self);
    fn cancel_session(&mut self);
    fn start_mic(&mut self) -> Result<(), String>;
    /// Stops capture after pushing the samples still buffered.
    fn stop_mic(&mut self);
    /// Arms (true) or disarms the core's end-of-speech detector.
    fn arm_silence_stop(&mut self, on: bool);
    fn silence_stop_fired(&mut self) -> bool;
    fn foreground(&mut self) -> Option<Target>;
    /// Puts `text` into the focused field via the clipboard, then presses
    /// Return when `press_return`.
    fn paste(&mut self, text: &str, press_return: bool);
    /// Leaves `text` on the clipboard without pasting.
    fn copy(&mut self, text: &str);
    fn show_overlay(&mut self, view: &OverlayView);
    fn hide_overlay(&mut self);
    fn set_tray_recording(&mut self, recording: bool);
    /// The recording ended without the hotkey: the next press starts anew.
    fn reset_hotkey(&mut self);
    /// Why a session cannot start (no API key), in words for the user.
    fn setup_problem(&mut self) -> Option<String>;
    fn config_flag(&mut self, key: &str) -> bool;
}

const RESULT_LINGER_MS: u64 = 1_200;
const NOTICE_LINGER_MS: u64 = 3_500;
const ERROR_LINGER_MS: u64 = 5_000;
/// Delivery kinds of `on_text_delivery`.
const DELIVERY_PASTE_ALL: u8 = 0;
const DELIVERY_TYPED: u8 = 1;
const DELIVERY_REMAINDER: u8 = 2;
const DELIVERY_CLIPBOARD_ONLY: u8 = 3;
const DELIVERY_SEND_FLAG: u8 = 0x80;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Phase {
    Idle,
    Recording {
        hands_free: bool,
    },
    /// Recording is over; waiting for the recognized (and corrected) text.
    Processing,
}

pub struct Controller {
    phase: Phase,
    token: u64,
    target: Option<Target>,
    delivery: Option<(u8, String)>,
    view: Option<OverlayView>,
    hide_at: Option<u64>,
}

impl Default for Controller {
    fn default() -> Self {
        Self::new()
    }
}

impl Controller {
    pub fn new() -> Self {
        Self {
            phase: Phase::Idle,
            token: 0,
            target: None,
            delivery: None,
            view: None,
            hide_at: None,
        }
    }

    pub fn is_recording(&self) -> bool {
        matches!(self.phase, Phase::Recording { .. })
    }

    /// The overlay needs redrawing at the timer rate (level meter).
    pub fn wants_ticks(&self) -> bool {
        self.view.is_some() || self.phase != Phase::Idle
    }

    pub fn on_gesture(&mut self, host: &mut dyn Host, gesture: Gesture, now_ms: u64) {
        match gesture {
            Gesture::Start { hands_free } => self.start(host, hands_free, now_ms),
            Gesture::BecameHandsFree => {
                if let Phase::Recording { .. } = self.phase {
                    self.phase = Phase::Recording { hands_free: true };
                    host.arm_silence_stop(true);
                    self.show(host, OverlayMode::Listening, String::new(), None, now_ms);
                }
            }
            Gesture::Stop => self.stop(host, now_ms),
            Gesture::Cancel => self.cancel(host),
        }
    }

    pub fn on_tick(&mut self, host: &mut dyn Host, now_ms: u64) {
        if let Phase::Recording { hands_free: true } = self.phase {
            if host.silence_stop_fired() {
                host.reset_hotkey();
                self.stop(host, now_ms);
            }
        }
        if self.hide_at.is_some_and(|t| now_ms >= t) {
            self.hide(host);
        }
    }

    /// The microphone stopped delivering on its own (device unplugged).
    pub fn on_mic_failed(&mut self, host: &mut dyn Host, message: &str, now_ms: u64) {
        if self.is_recording() {
            host.stop_mic();
            host.cancel_session();
            host.reset_hotkey();
            self.finish(host);
            self.show_error(host, format!("Микрофон отключился: {message}"), now_ms);
        }
    }

    pub fn on_core(&mut self, host: &mut dyn Host, event: CoreEvent, now_ms: u64) {
        if event.token() != self.token || self.phase == Phase::Idle {
            return;
        }
        match event {
            CoreEvent::Ready(_) => {}
            CoreEvent::State(_, state) => self.on_state(host, &state, now_ms),
            CoreEvent::Interim(_, text) => {
                if let Some(view) = &self.view {
                    let mode = view.mode;
                    self.show(host, mode, text, None, now_ms);
                }
            }
            CoreEvent::Delivery {
                kind, remainder, ..
            } => self.delivery = Some((kind, remainder)),
            CoreEvent::Final(_, text) => self.deliver(host, text, now_ms),
            CoreEvent::Error(_, message) => {
                if self.is_recording() {
                    host.stop_mic();
                    host.reset_hotkey();
                }
                self.finish(host);
                self.show_error(host, humanize_error(&message), now_ms);
            }
            CoreEvent::Warning(_, message) => log::warn!("core warning: {message}"),
        }
    }

    fn start(&mut self, host: &mut dyn Host, hands_free: bool, now_ms: u64) {
        if let Some(problem) = host.setup_problem() {
            host.reset_hotkey();
            self.show_error(host, problem, now_ms);
            return;
        }
        if self.is_recording() {
            host.stop_mic();
        }
        self.token += 1;
        self.delivery = None;
        self.target = host.foreground();
        let app_id = self.target.as_ref().and_then(|t| t.app_id.clone());
        if !host.begin_session(self.token, hands_free, app_id.as_deref()) {
            host.reset_hotkey();
            self.finish(host);
            self.show_error(
                host,
                "Не удалось начать запись: подробности в журнале.".into(),
                now_ms,
            );
            return;
        }
        if let Err(e) = host.start_mic() {
            host.cancel_session();
            host.reset_hotkey();
            self.finish(host);
            self.show_error(host, format!("Микрофон недоступен: {e}"), now_ms);
            return;
        }
        self.phase = Phase::Recording { hands_free };
        host.arm_silence_stop(hands_free);
        host.set_tray_recording(true);
        self.show(host, OverlayMode::Listening, String::new(), None, now_ms);
    }

    fn stop(&mut self, host: &mut dyn Host, now_ms: u64) {
        if !self.is_recording() {
            return;
        }
        host.arm_silence_stop(false);
        host.stop_mic();
        host.end_session();
        self.phase = Phase::Processing;
        host.set_tray_recording(false);
        let text = self
            .view
            .as_ref()
            .map(|v| v.text.clone())
            .unwrap_or_default();
        self.show(host, OverlayMode::Recognizing, text, None, now_ms);
    }

    fn cancel(&mut self, host: &mut dyn Host) {
        if self.phase == Phase::Idle {
            return;
        }
        if self.is_recording() {
            host.stop_mic();
        }
        host.cancel_session();
        self.finish(host);
        self.hide(host);
    }

    fn on_state(&mut self, host: &mut dyn Host, state: &str, now_ms: u64) {
        let text = self
            .view
            .as_ref()
            .map(|v| v.text.clone())
            .unwrap_or_default();
        match state {
            "finalizing_asr" if self.phase == Phase::Processing => {
                self.show(host, OverlayMode::Recognizing, text, None, now_ms)
            }
            "correcting" => self.show(host, OverlayMode::Correcting, text, None, now_ms),
            // The session is over without text: silence, or only voice commands.
            "idle" | "cancelled" => {
                if self.is_recording() {
                    host.stop_mic();
                    host.reset_hotkey();
                }
                self.finish(host);
                self.hide(host);
            }
            _ => {}
        }
    }

    fn deliver(&mut self, host: &mut dyn Host, text: String, now_ms: u64) {
        if self.is_recording() {
            host.stop_mic();
            host.reset_hotkey();
        }
        let (raw_kind, remainder) = self
            .delivery
            .take()
            .unwrap_or((DELIVERY_PASTE_ALL, String::new()));
        let target = self.target.take();
        self.finish(host);
        if text.trim().is_empty() {
            self.hide(host);
            return;
        }
        let press_return =
            raw_kind & DELIVERY_SEND_FLAG != 0 || host.config_flag("paste.auto_return");
        let paste_text = match raw_kind & !DELIVERY_SEND_FLAG {
            DELIVERY_TYPED => {
                self.show(
                    host,
                    OverlayMode::Result,
                    text,
                    Some(RESULT_LINGER_MS),
                    now_ms,
                );
                return;
            }
            DELIVERY_CLIPBOARD_ONLY => {
                host.copy(&text);
                self.show_notice(
                    host,
                    "Не вставилось целиком — текст в буфере, Ctrl+V",
                    now_ms,
                );
                return;
            }
            DELIVERY_REMAINDER if !remainder.is_empty() => remainder,
            _ => text.clone(),
        };
        let same_window = match (&target, host.foreground()) {
            (Some(t), Some(now)) => t.window == now.window,
            _ => false,
        };
        if !same_window {
            host.copy(&text);
            self.show_notice(host, "Окно сменилось — текст в буфере, Ctrl+V", now_ms);
            return;
        }
        host.paste(&paste_text, press_return);
        self.show(
            host,
            OverlayMode::Result,
            text,
            Some(RESULT_LINGER_MS),
            now_ms,
        );
    }

    /// Back to idle; the overlay is left to the caller.
    fn finish(&mut self, host: &mut dyn Host) {
        if self.is_recording() {
            host.arm_silence_stop(false);
        }
        self.phase = Phase::Idle;
        self.delivery = None;
        host.set_tray_recording(false);
    }

    fn show_notice(&mut self, host: &mut dyn Host, text: &str, now_ms: u64) {
        self.show(
            host,
            OverlayMode::Notice,
            text.into(),
            Some(NOTICE_LINGER_MS),
            now_ms,
        );
    }

    fn show_error(&mut self, host: &mut dyn Host, text: String, now_ms: u64) {
        self.show(
            host,
            OverlayMode::Error,
            text,
            Some(ERROR_LINGER_MS),
            now_ms,
        );
    }

    fn show(
        &mut self,
        host: &mut dyn Host,
        mode: OverlayMode,
        text: String,
        linger_ms: Option<u64>,
        now_ms: u64,
    ) {
        let view = OverlayView {
            mode,
            text,
            hands_free: matches!(self.phase, Phase::Recording { hands_free: true }),
        };
        self.hide_at = linger_ms.map(|ms| now_ms + ms);
        if self.view.as_ref() != Some(&view) {
            host.show_overlay(&view);
            self.view = Some(view);
        }
    }

    fn hide(&mut self, host: &mut dyn Host) {
        self.hide_at = None;
        if self.view.take().is_some() {
            host.hide_overlay();
        }
    }
}

/// Core errors are English and technical; the common ones get a Russian hint.
pub fn humanize_error(message: &str) -> String {
    let lower = message.to_lowercase();
    let hint = if lower.contains("401")
        || lower.contains("403")
        || lower.contains("unauthorized")
        || lower.contains("invalidapikey")
        || lower.contains("api key")
        || lower.contains("api-key")
        || lower.contains("api_key")
    {
        Some("Ключ не подошёл — проверьте его в настройках.")
    } else if lower.contains("timed out") || lower.contains("timeout") {
        Some("Сервер не ответил вовремя — проверьте интернет.")
    } else if lower.contains("dns") || lower.contains("connect") {
        Some("Не удалось подключиться к серверу распознавания.")
    } else if lower.contains("model") && (lower.contains("not found") || lower.contains("missing"))
    {
        Some("Локальная модель не скачана — скачайте её в настройках.")
    } else {
        None
    };
    match hint {
        Some(h) => format!("{h}\n{message}"),
        None => format!("Ошибка: {message}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Debug, Clone, PartialEq, Eq)]
    enum Call {
        Begin(u64, bool, Option<String>),
        End,
        Cancel,
        MicOn,
        MicOff,
        Silence(bool),
        Paste(String, bool),
        Copy(String),
        Overlay(OverlayMode, String),
        Hide,
        Tray(bool),
        ResetHotkey,
    }

    struct Fake {
        calls: Vec<Call>,
        window: isize,
        begin_ok: bool,
        mic: Result<(), String>,
        silence: bool,
        problem: Option<String>,
        auto_return: bool,
    }

    impl Fake {
        fn new() -> Fake {
            Fake {
                calls: Vec::new(),
                window: 7,
                begin_ok: true,
                mic: Ok(()),
                silence: false,
                problem: None,
                auto_return: false,
            }
        }

        fn take(&mut self) -> Vec<Call> {
            std::mem::take(&mut self.calls)
        }

        fn has(&self, call: &Call) -> bool {
            self.calls.contains(call)
        }
    }

    impl Host for Fake {
        fn begin_session(&mut self, token: u64, hands_free: bool, app_id: Option<&str>) -> bool {
            self.calls
                .push(Call::Begin(token, hands_free, app_id.map(str::to_string)));
            self.begin_ok
        }
        fn end_session(&mut self) {
            self.calls.push(Call::End);
        }
        fn cancel_session(&mut self) {
            self.calls.push(Call::Cancel);
        }
        fn start_mic(&mut self) -> Result<(), String> {
            self.calls.push(Call::MicOn);
            self.mic.clone()
        }
        fn stop_mic(&mut self) {
            self.calls.push(Call::MicOff);
        }
        fn arm_silence_stop(&mut self, on: bool) {
            self.calls.push(Call::Silence(on));
        }
        fn silence_stop_fired(&mut self) -> bool {
            self.silence
        }
        fn foreground(&mut self) -> Option<Target> {
            Some(Target {
                window: self.window,
                app_id: Some("org.telegram.desktop".into()),
            })
        }
        fn paste(&mut self, text: &str, press_return: bool) {
            self.calls.push(Call::Paste(text.into(), press_return));
        }
        fn copy(&mut self, text: &str) {
            self.calls.push(Call::Copy(text.into()));
        }
        fn show_overlay(&mut self, view: &OverlayView) {
            self.calls.push(Call::Overlay(view.mode, view.text.clone()));
        }
        fn hide_overlay(&mut self) {
            self.calls.push(Call::Hide);
        }
        fn set_tray_recording(&mut self, recording: bool) {
            self.calls.push(Call::Tray(recording));
        }
        fn reset_hotkey(&mut self) {
            self.calls.push(Call::ResetHotkey);
        }
        fn setup_problem(&mut self) -> Option<String> {
            self.problem.clone()
        }
        fn config_flag(&mut self, key: &str) -> bool {
            key == "paste.auto_return" && self.auto_return
        }
    }

    fn started(host: &mut Fake, hands_free: bool) -> Controller {
        let mut c = Controller::new();
        c.on_gesture(host, Gesture::Start { hands_free }, 0);
        c
    }

    #[test]
    fn hold_dictation_pastes_into_the_same_window() {
        let mut h = Fake::new();
        let mut c = started(&mut h, false);
        assert_eq!(
            h.take(),
            vec![
                Call::Begin(1, false, Some("org.telegram.desktop".into())),
                Call::MicOn,
                Call::Silence(false),
                Call::Tray(true),
                Call::Overlay(OverlayMode::Listening, String::new()),
            ]
        );
        c.on_core(&mut h, CoreEvent::Ready(1), 10);
        c.on_core(&mut h, CoreEvent::Interim(1, "привет".into()), 500);
        c.on_gesture(&mut h, Gesture::Stop, 900);
        assert!(h.has(&Call::MicOff));
        assert!(h.has(&Call::End));
        assert!(h.has(&Call::Overlay(OverlayMode::Recognizing, "привет".into())));
        h.take();
        c.on_core(&mut h, CoreEvent::State(1, "finalizing_asr".into()), 950);
        c.on_core(
            &mut h,
            CoreEvent::Delivery {
                token: 1,
                kind: 0,
                remainder: String::new(),
            },
            1000,
        );
        c.on_core(&mut h, CoreEvent::Final(1, "Привет!".into()), 1000);
        assert!(h.has(&Call::Paste("Привет!".into(), false)));
        assert!(h.has(&Call::Overlay(OverlayMode::Result, "Привет!".into())));
        h.take();
        c.on_tick(&mut h, 1000 + RESULT_LINGER_MS - 1);
        assert!(!h.has(&Call::Hide));
        c.on_tick(&mut h, 1000 + RESULT_LINGER_MS);
        assert!(h.has(&Call::Hide));
        assert!(!c.wants_ticks());
    }

    #[test]
    fn spoken_send_and_auto_return_press_return() {
        let mut h = Fake::new();
        let mut c = started(&mut h, false);
        c.on_gesture(&mut h, Gesture::Stop, 100);
        c.on_core(
            &mut h,
            CoreEvent::Delivery {
                token: 1,
                kind: DELIVERY_PASTE_ALL | DELIVERY_SEND_FLAG,
                remainder: String::new(),
            },
            200,
        );
        c.on_core(&mut h, CoreEvent::Final(1, "Привет".into()), 200);
        assert!(h.has(&Call::Paste("Привет".into(), true)));

        let mut h = Fake::new();
        h.auto_return = true;
        let mut c = started(&mut h, false);
        c.on_gesture(&mut h, Gesture::Stop, 100);
        c.on_core(&mut h, CoreEvent::Final(1, "Ок".into()), 200);
        assert!(h.has(&Call::Paste("Ок".into(), true)));
    }

    #[test]
    fn a_different_window_gets_the_clipboard_instead_of_a_paste() {
        let mut h = Fake::new();
        let mut c = started(&mut h, false);
        c.on_gesture(&mut h, Gesture::Stop, 100);
        h.window = 8;
        c.on_core(&mut h, CoreEvent::Final(1, "текст".into()), 200);
        assert!(h.has(&Call::Copy("текст".into())));
        assert!(!h.calls.iter().any(|c| matches!(c, Call::Paste(..))));
        assert!(h
            .calls
            .iter()
            .any(|c| matches!(c, Call::Overlay(OverlayMode::Notice, _))));
    }

    #[test]
    fn remainder_and_clipboard_only_deliveries() {
        let mut h = Fake::new();
        let mut c = started(&mut h, false);
        c.on_gesture(&mut h, Gesture::Stop, 100);
        c.on_core(
            &mut h,
            CoreEvent::Delivery {
                token: 1,
                kind: DELIVERY_REMAINDER,
                remainder: " дела".into(),
            },
            150,
        );
        c.on_core(&mut h, CoreEvent::Final(1, "как дела".into()), 150);
        assert!(h.has(&Call::Paste(" дела".into(), false)));

        let mut h = Fake::new();
        let mut c = started(&mut h, false);
        c.on_gesture(&mut h, Gesture::Stop, 100);
        c.on_core(
            &mut h,
            CoreEvent::Delivery {
                token: 1,
                kind: DELIVERY_CLIPBOARD_ONLY,
                remainder: String::new(),
            },
            150,
        );
        c.on_core(&mut h, CoreEvent::Final(1, "всё".into()), 150);
        assert!(h.has(&Call::Copy("всё".into())));
        assert!(!h.calls.iter().any(|c| matches!(c, Call::Paste(..))));
    }

    #[test]
    fn silence_ends_without_text_or_error() {
        let mut h = Fake::new();
        let mut c = started(&mut h, false);
        c.on_gesture(&mut h, Gesture::Stop, 100);
        h.take();
        c.on_core(&mut h, CoreEvent::State(1, "finalizing_asr".into()), 150);
        c.on_core(&mut h, CoreEvent::State(1, "idle".into()), 300);
        assert!(h.has(&Call::Hide));
        assert!(!h
            .calls
            .iter()
            .any(|c| matches!(c, Call::Paste(..) | Call::Copy(_))));
        assert!(!c.wants_ticks());
    }

    #[test]
    fn stale_tokens_are_ignored() {
        let mut h = Fake::new();
        let mut c = started(&mut h, true);
        c.on_gesture(&mut h, Gesture::Stop, 100);
        c.on_gesture(&mut h, Gesture::Start { hands_free: true }, 200);
        h.take();
        c.on_core(&mut h, CoreEvent::Final(1, "старое".into()), 300);
        assert!(h.calls.is_empty(), "{:?}", h.calls);
        assert!(c.is_recording());
    }

    #[test]
    fn hands_free_recording_stops_on_silence() {
        let mut h = Fake::new();
        let mut c = started(&mut h, false);
        c.on_gesture(&mut h, Gesture::BecameHandsFree, 150);
        assert!(h.has(&Call::Silence(true)));
        h.take();
        c.on_tick(&mut h, 1000);
        assert!(c.is_recording());
        h.silence = true;
        c.on_tick(&mut h, 2000);
        assert!(!c.is_recording());
        assert!(h.has(&Call::ResetHotkey));
        assert!(h.has(&Call::End));
    }

    #[test]
    fn cancel_throws_the_recording_away() {
        let mut h = Fake::new();
        let mut c = started(&mut h, false);
        h.take();
        c.on_gesture(&mut h, Gesture::Cancel, 100);
        assert_eq!(
            h.take(),
            vec![
                Call::MicOff,
                Call::Cancel,
                Call::Silence(false),
                Call::Tray(false),
                Call::Hide
            ]
        );
        c.on_core(&mut h, CoreEvent::Final(1, "поздно".into()), 200);
        assert!(h.calls.is_empty());
    }

    #[test]
    fn errors_stop_everything_and_are_shown() {
        let mut h = Fake::new();
        let mut c = started(&mut h, false);
        h.take();
        c.on_core(
            &mut h,
            CoreEvent::Error(1, "HTTP 401 Unauthorized".into()),
            100,
        );
        assert!(h.has(&Call::MicOff));
        assert!(h.has(&Call::ResetHotkey));
        assert!(h.calls.iter().any(|c| matches!(
            c,
            Call::Overlay(OverlayMode::Error, t) if t.starts_with("Ключ не подошёл")
        )));
        assert!(!c.is_recording());
        h.take();
        c.on_tick(&mut h, 100 + ERROR_LINGER_MS);
        assert!(h.has(&Call::Hide));
    }

    #[test]
    fn missing_key_or_mic_never_leaves_a_session_open() {
        let mut h = Fake::new();
        h.problem = Some("Нужен ключ".into());
        let c = started(&mut h, false);
        assert!(!h
            .calls
            .iter()
            .any(|c| matches!(c, Call::Begin(..) | Call::MicOn)));
        assert!(h.has(&Call::ResetHotkey));
        assert!(!c.is_recording());

        let mut h = Fake::new();
        h.mic = Err("нет устройства".into());
        let c = started(&mut h, false);
        assert!(h.has(&Call::Cancel));
        assert!(h.has(&Call::Overlay(
            OverlayMode::Error,
            "Микрофон недоступен: нет устройства".into()
        )));
        assert!(!c.is_recording());

        let mut h = Fake::new();
        h.begin_ok = false;
        let c = started(&mut h, false);
        assert!(!h.has(&Call::MicOn));
        assert!(!c.is_recording());
    }

    #[test]
    fn errors_get_russian_hints() {
        assert!(humanize_error("timed out waiting").starts_with("Сервер не ответил"));
        assert!(humanize_error("InvalidApiKey").starts_with("Ключ не подошёл"));
        assert_eq!(humanize_error("boom"), "Ошибка: boom");
    }
}
