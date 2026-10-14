//! The dictation key and how its presses become recording gestures.
//!
//! The low-level keyboard hook calls [`HotkeyFilter::on_key`] for every key
//! event and must answer within milliseconds, so the filter only does
//! bookkeeping; the gestures it returns are handled after the hook returns.

pub const VK_ESCAPE: u32 = 0x1B;
const VK_CAPITAL: u32 = 0x14;
const VK_PAUSE: u32 = 0x13;
const VK_INSERT: u32 = 0x2D;
const VK_F1: u32 = 0x70;
const VK_SCROLL: u32 = 0x91;
const VK_RCONTROL: u32 = 0xA3;
const VK_RMENU: u32 = 0xA5;

/// A press shorter than this starts a hands-free recording in `auto` mode.
pub const TAP_MAX_MS: u64 = 300;
/// Two taps closer than this start a recording in `double_tap` mode.
pub const DOUBLE_TAP_MS: u64 = 400;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TriggerKey {
    RightCtrl,
    RightAlt,
    CapsLock,
    ScrollLock,
    Pause,
    Insert,
    /// F1..=F24.
    F(u8),
}

impl TriggerKey {
    pub const DEFAULT: TriggerKey = TriggerKey::RightCtrl;

    /// Keys offered in the settings window, in display order.
    pub fn choices() -> Vec<TriggerKey> {
        let mut keys = vec![
            TriggerKey::RightCtrl,
            TriggerKey::RightAlt,
            TriggerKey::CapsLock,
            TriggerKey::ScrollLock,
            TriggerKey::Pause,
            TriggerKey::Insert,
        ];
        keys.extend((1..=12).map(TriggerKey::F));
        keys
    }

    /// Parses the `windows.trigger_key` config value; unknown values give `None`.
    pub fn parse(value: &str) -> Option<TriggerKey> {
        let v = value.trim().to_ascii_lowercase().replace(['-', ' '], "_");
        Some(match v.as_str() {
            "right_ctrl" | "right_control" | "rctrl" => TriggerKey::RightCtrl,
            "right_alt" | "ralt" | "altgr" => TriggerKey::RightAlt,
            "caps_lock" | "capslock" => TriggerKey::CapsLock,
            "scroll_lock" | "scrolllock" => TriggerKey::ScrollLock,
            "pause" => TriggerKey::Pause,
            "insert" => TriggerKey::Insert,
            _ => {
                let n: u8 = v.strip_prefix('f')?.parse().ok()?;
                if !(1..=24).contains(&n) {
                    return None;
                }
                TriggerKey::F(n)
            }
        })
    }

    pub fn config_value(self) -> String {
        match self {
            TriggerKey::RightCtrl => "right_ctrl".into(),
            TriggerKey::RightAlt => "right_alt".into(),
            TriggerKey::CapsLock => "caps_lock".into(),
            TriggerKey::ScrollLock => "scroll_lock".into(),
            TriggerKey::Pause => "pause".into(),
            TriggerKey::Insert => "insert".into(),
            TriggerKey::F(n) => format!("f{n}"),
        }
    }

    pub fn title(self) -> String {
        match self {
            TriggerKey::RightCtrl => "Правый Ctrl".into(),
            TriggerKey::RightAlt => "Правый Alt".into(),
            TriggerKey::CapsLock => "Caps Lock".into(),
            TriggerKey::ScrollLock => "Scroll Lock".into(),
            TriggerKey::Pause => "Pause".into(),
            TriggerKey::Insert => "Insert".into(),
            TriggerKey::F(n) => format!("F{n}"),
        }
    }

    /// The virtual-key code the low-level hook reports for this key.
    pub fn vk(self) -> u32 {
        match self {
            TriggerKey::RightCtrl => VK_RCONTROL,
            TriggerKey::RightAlt => VK_RMENU,
            TriggerKey::CapsLock => VK_CAPITAL,
            TriggerKey::ScrollLock => VK_SCROLL,
            TriggerKey::Pause => VK_PAUSE,
            TriggerKey::Insert => VK_INSERT,
            TriggerKey::F(n) => VK_F1 + u32::from(n) - 1,
        }
    }

    /// Modifiers keep working as modifiers: their events are never swallowed,
    /// and a chord such as RCtrl+C cancels the recording it started.
    pub fn is_modifier(self) -> bool {
        matches!(self, TriggerKey::RightCtrl | TriggerKey::RightAlt)
    }
}

/// `hotkey.trigger_mode`, shared with the Mac app.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TriggerMode {
    /// Record while the key is held.
    Hold,
    /// One press starts, the next press stops.
    Toggle,
    /// A double press starts, a single press stops.
    DoubleTap,
    /// Hold to record, or tap to record hands-free until the next press.
    Auto,
}

impl TriggerMode {
    pub fn choices() -> [TriggerMode; 4] {
        [
            TriggerMode::Auto,
            TriggerMode::Hold,
            TriggerMode::Toggle,
            TriggerMode::DoubleTap,
        ]
    }

    /// Unknown values fall back to `hold`, like on the Mac.
    pub fn parse(value: &str) -> TriggerMode {
        match value.trim().to_ascii_lowercase().as_str() {
            "toggle" => TriggerMode::Toggle,
            "double_tap" => TriggerMode::DoubleTap,
            "auto" => TriggerMode::Auto,
            _ => TriggerMode::Hold,
        }
    }

    pub fn config_value(self) -> &'static str {
        match self {
            TriggerMode::Hold => "hold",
            TriggerMode::Toggle => "toggle",
            TriggerMode::DoubleTap => "double_tap",
            TriggerMode::Auto => "auto",
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            TriggerMode::Hold => "Удерживать, пока говорю",
            TriggerMode::Toggle => "Нажать — начать, нажать ещё раз — закончить",
            TriggerMode::DoubleTap => "Двойное нажатие — начать, одно — закончить",
            TriggerMode::Auto => "Удерживать или коротко нажать",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Gesture {
    /// Begin recording. `hands_free`: the key is not held for the recording.
    Start {
        hands_free: bool,
    },
    /// A tap in `auto` mode: the recording that started on the press goes on
    /// without the key.
    BecameHandsFree,
    Stop,
    /// Throw the recording away without inserting anything.
    Cancel,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct KeyVerdict {
    /// Hide the event from the focused app.
    pub swallow: bool,
    pub gesture: Option<Gesture>,
}

pub struct HotkeyFilter {
    key: TriggerKey,
    mode: TriggerMode,
    recording: bool,
    hands_free: bool,
    trigger_down: bool,
    pressed_at: u64,
    /// The recording was started by the press that is still held.
    started_by_this_press: bool,
    last_tap_at: Option<u64>,
    escape_swallowed: bool,
}

impl HotkeyFilter {
    pub fn new(key: TriggerKey, mode: TriggerMode) -> Self {
        Self {
            key,
            mode,
            recording: false,
            hands_free: false,
            trigger_down: false,
            pressed_at: 0,
            started_by_this_press: false,
            last_tap_at: None,
            escape_swallowed: false,
        }
    }

    pub fn key(&self) -> TriggerKey {
        self.key
    }

    pub fn mode(&self) -> TriggerMode {
        self.mode
    }

    /// Applies new settings; a recording in progress is left to finish.
    pub fn configure(&mut self, key: TriggerKey, mode: TriggerMode) {
        if key != self.key {
            self.trigger_down = false;
        }
        self.key = key;
        self.mode = mode;
        self.last_tap_at = None;
    }

    /// The recording ended for another reason (error, silence, a new session).
    pub fn reset(&mut self) {
        self.recording = false;
        self.hands_free = false;
        self.started_by_this_press = false;
        self.last_tap_at = None;
    }

    /// `injected`: the event was synthesized (our own paste, other tools).
    pub fn on_key(&mut self, vk: u32, down: bool, now_ms: u64, injected: bool) -> KeyVerdict {
        if injected {
            return KeyVerdict::default();
        }
        if vk == self.key.vk() {
            return self.on_trigger(down, now_ms);
        }
        if vk == VK_ESCAPE {
            if down && self.recording {
                self.escape_swallowed = true;
                self.reset();
                return KeyVerdict {
                    swallow: true,
                    gesture: Some(Gesture::Cancel),
                };
            }
            if !down && self.escape_swallowed {
                self.escape_swallowed = false;
                return KeyVerdict {
                    swallow: true,
                    gesture: None,
                };
            }
            return KeyVerdict::default();
        }
        if down && self.trigger_down && self.key.is_modifier() {
            return self.on_chord();
        }
        KeyVerdict::default()
    }

    fn on_trigger(&mut self, down: bool, now_ms: u64) -> KeyVerdict {
        let swallow = !self.key.is_modifier();
        if down {
            if self.trigger_down {
                // Auto-repeat while the key is held.
                return KeyVerdict {
                    swallow,
                    gesture: None,
                };
            }
            self.trigger_down = true;
            self.pressed_at = now_ms;
            self.started_by_this_press = false;
            let gesture = self.on_press(now_ms);
            return KeyVerdict { swallow, gesture };
        }
        if !self.trigger_down {
            return KeyVerdict {
                swallow,
                gesture: None,
            };
        }
        self.trigger_down = false;
        let held_ms = now_ms.saturating_sub(self.pressed_at);
        let gesture = self.on_release(held_ms);
        self.started_by_this_press = false;
        KeyVerdict { swallow, gesture }
    }

    fn on_press(&mut self, now_ms: u64) -> Option<Gesture> {
        if self.recording {
            // Hold recordings end on release; every other recording ends on
            // the next press.
            if self.hands_free {
                self.reset();
                return Some(Gesture::Stop);
            }
            return None;
        }
        let hands_free = match self.mode {
            TriggerMode::Hold | TriggerMode::Auto => false,
            TriggerMode::Toggle => true,
            TriggerMode::DoubleTap => {
                let second = self
                    .last_tap_at
                    .is_some_and(|t| now_ms.saturating_sub(t) <= DOUBLE_TAP_MS);
                if !second {
                    self.last_tap_at = Some(now_ms);
                    return None;
                }
                self.last_tap_at = None;
                true
            }
        };
        self.recording = true;
        self.hands_free = hands_free;
        self.started_by_this_press = true;
        Some(Gesture::Start { hands_free })
    }

    fn on_release(&mut self, held_ms: u64) -> Option<Gesture> {
        if !self.recording || self.hands_free {
            return None;
        }
        if self.mode == TriggerMode::Auto && held_ms < TAP_MAX_MS {
            self.hands_free = true;
            return Some(Gesture::BecameHandsFree);
        }
        self.reset();
        Some(Gesture::Stop)
    }

    /// Another key went down while the modifier trigger is held: the user is
    /// typing a shortcut, not dictating.
    fn on_chord(&mut self) -> KeyVerdict {
        self.last_tap_at = None;
        if self.recording && self.started_by_this_press {
            self.reset();
            return KeyVerdict {
                swallow: false,
                gesture: Some(Gesture::Cancel),
            };
        }
        KeyVerdict::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const RCTRL: u32 = VK_RCONTROL;
    const F9: u32 = VK_F1 + 8;
    const KEY_C: u32 = 0x43;

    fn press(f: &mut HotkeyFilter, vk: u32, at: u64) -> KeyVerdict {
        f.on_key(vk, true, at, false)
    }

    fn release(f: &mut HotkeyFilter, vk: u32, at: u64) -> KeyVerdict {
        f.on_key(vk, false, at, false)
    }

    fn start(hands_free: bool) -> Option<Gesture> {
        Some(Gesture::Start { hands_free })
    }

    #[test]
    fn parses_and_prints_every_choice() {
        for key in TriggerKey::choices() {
            assert_eq!(TriggerKey::parse(&key.config_value()), Some(key));
        }
        assert_eq!(TriggerKey::parse("F24"), Some(TriggerKey::F(24)));
        assert_eq!(TriggerKey::parse("Right Ctrl"), Some(TriggerKey::RightCtrl));
        assert_eq!(TriggerKey::parse("f25"), None);
        assert_eq!(TriggerKey::parse("fn"), None);
        assert_eq!(TriggerKey::F(9).vk(), F9);
        for mode in TriggerMode::choices() {
            assert_eq!(TriggerMode::parse(mode.config_value()), mode);
        }
        assert_eq!(TriggerMode::parse("whatever"), TriggerMode::Hold);
    }

    #[test]
    fn hold_records_while_the_key_is_down() {
        let mut f = HotkeyFilter::new(TriggerKey::RightCtrl, TriggerMode::Hold);
        assert_eq!(press(&mut f, RCTRL, 0).gesture, start(false));
        assert_eq!(press(&mut f, RCTRL, 30).gesture, None, "auto-repeat");
        assert_eq!(release(&mut f, RCTRL, 2000).gesture, Some(Gesture::Stop));
        assert_eq!(release(&mut f, RCTRL, 2100).gesture, None);
    }

    #[test]
    fn modifier_trigger_is_never_swallowed_but_a_function_key_is() {
        let mut f = HotkeyFilter::new(TriggerKey::RightCtrl, TriggerMode::Hold);
        assert!(!press(&mut f, RCTRL, 0).swallow);
        assert!(!release(&mut f, RCTRL, 500).swallow);
        let mut f = HotkeyFilter::new(TriggerKey::F(9), TriggerMode::Hold);
        assert!(press(&mut f, F9, 0).swallow);
        assert!(press(&mut f, F9, 30).swallow);
        assert!(release(&mut f, F9, 500).swallow);
    }

    #[test]
    fn toggle_starts_and_stops_on_presses() {
        let mut f = HotkeyFilter::new(TriggerKey::F(9), TriggerMode::Toggle);
        assert_eq!(press(&mut f, F9, 0).gesture, start(true));
        assert_eq!(release(&mut f, F9, 100).gesture, None);
        assert_eq!(press(&mut f, F9, 3000).gesture, Some(Gesture::Stop));
        assert_eq!(release(&mut f, F9, 3100).gesture, None);
    }

    #[test]
    fn double_tap_needs_two_quick_presses() {
        let mut f = HotkeyFilter::new(TriggerKey::RightCtrl, TriggerMode::DoubleTap);
        assert_eq!(press(&mut f, RCTRL, 0).gesture, None);
        release(&mut f, RCTRL, 80);
        assert_eq!(press(&mut f, RCTRL, 1000).gesture, None, "too slow");
        release(&mut f, RCTRL, 1080);
        assert_eq!(press(&mut f, RCTRL, 1300).gesture, start(true));
        release(&mut f, RCTRL, 1380);
        assert_eq!(press(&mut f, RCTRL, 5000).gesture, Some(Gesture::Stop));
    }

    #[test]
    fn auto_tap_goes_hands_free_and_hold_stops_on_release() {
        let mut f = HotkeyFilter::new(TriggerKey::RightCtrl, TriggerMode::Auto);
        assert_eq!(press(&mut f, RCTRL, 0).gesture, start(false));
        assert_eq!(
            release(&mut f, RCTRL, TAP_MAX_MS - 1).gesture,
            Some(Gesture::BecameHandsFree)
        );
        assert_eq!(press(&mut f, RCTRL, 4000).gesture, Some(Gesture::Stop));
        assert_eq!(release(&mut f, RCTRL, 4050).gesture, None);

        assert_eq!(press(&mut f, RCTRL, 9000).gesture, start(false));
        assert_eq!(
            release(&mut f, RCTRL, 9000 + TAP_MAX_MS).gesture,
            Some(Gesture::Stop)
        );
    }

    #[test]
    fn escape_cancels_only_a_recording() {
        let mut f = HotkeyFilter::new(TriggerKey::RightCtrl, TriggerMode::Toggle);
        assert_eq!(press(&mut f, VK_ESCAPE, 0), KeyVerdict::default());
        assert_eq!(release(&mut f, VK_ESCAPE, 10), KeyVerdict::default());
        press(&mut f, RCTRL, 100);
        release(&mut f, RCTRL, 150);
        let v = press(&mut f, VK_ESCAPE, 1000);
        assert!(v.swallow);
        assert_eq!(v.gesture, Some(Gesture::Cancel));
        assert!(release(&mut f, VK_ESCAPE, 1050).swallow);
        assert_eq!(press(&mut f, RCTRL, 2000).gesture, start(true));
    }

    #[test]
    fn a_shortcut_with_the_modifier_cancels_its_recording() {
        let mut f = HotkeyFilter::new(TriggerKey::RightCtrl, TriggerMode::Hold);
        assert_eq!(press(&mut f, RCTRL, 0).gesture, start(false));
        let v = press(&mut f, KEY_C, 40);
        assert!(!v.swallow);
        assert_eq!(v.gesture, Some(Gesture::Cancel));
        assert_eq!(release(&mut f, RCTRL, 100).gesture, None);
    }

    #[test]
    fn a_shortcut_does_not_cancel_a_hands_free_recording_started_earlier() {
        let mut f = HotkeyFilter::new(TriggerKey::RightCtrl, TriggerMode::Auto);
        press(&mut f, RCTRL, 0);
        release(&mut f, RCTRL, 100);
        // Typing RCtrl+C during the recording: the press itself stops it.
        assert_eq!(press(&mut f, RCTRL, 2000).gesture, Some(Gesture::Stop));
        assert_eq!(press(&mut f, KEY_C, 2010).gesture, None);
    }

    #[test]
    fn injected_events_are_ignored() {
        let mut f = HotkeyFilter::new(TriggerKey::RightCtrl, TriggerMode::Hold);
        assert_eq!(f.on_key(RCTRL, true, 0, true), KeyVerdict::default());
        assert_eq!(f.on_key(RCTRL, false, 10, true), KeyVerdict::default());
        assert_eq!(press(&mut f, RCTRL, 20).gesture, start(false));
    }

    #[test]
    fn reset_after_an_error_lets_the_next_press_start_again() {
        let mut f = HotkeyFilter::new(TriggerKey::F(9), TriggerMode::Toggle);
        press(&mut f, F9, 0);
        release(&mut f, F9, 50);
        f.reset();
        assert_eq!(press(&mut f, F9, 1000).gesture, start(true));
    }
}
