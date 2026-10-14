//! Typing text into the focused field with synthetic key events, and reading that
//! field back through the Accessibility API.
//!
//! Written for Velikiy Moguchiy from a description of the behaviour the callers
//! (`live_insert`, `app_context`) need; it contains no third-party code.
//!
//! Every keystroke is posted at the HID level from a fresh event source whose user
//! data is [`SYNTHETIC_EVENT_MARKER`], so the app's own hotkey monitor can tell
//! these events from the user's keys. Text goes in as Unicode key events, one
//! character per keystroke; a newline is Shift+Return (a soft line break in chat
//! apps instead of "send") except in terminals, which get a literal line feed.
//!
//! The macOS calls live in `sys`. On other platforms `sys` reports that typing is
//! unavailable and that no field is focused, so the platform-independent logic and
//! its tests build and run anywhere.

use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

/// User data of every synthetic event source: ASCII "VELIKIY1". Must equal
/// `SPSyntheticEventMarker` in `MacApp/VelikiyMoguchiy/Hotkey/SPHotkeyMonitor.h`.
pub const SYNTHETIC_EVENT_MARKER: i64 = 0x5645_4C49_4B49_5931;

/// Pause after each keystroke, so the target app keeps up.
const KEYSTROKE_PAUSE: Duration = Duration::from_millis(1);
/// `FocusAnchor::verify` looks this many times before giving up...
const VERIFY_ATTEMPTS: usize = 4;
/// ...waiting this long between looks for the field to catch up.
const VERIFY_PAUSE: Duration = Duration::from_millis(40);

const KEY_RETURN: u16 = 36;
const KEY_BACKSPACE: u16 = 51;

/// Bundle id prefixes (lowercase) of terminal emulators.
const TERMINAL_BUNDLE_PREFIXES: &[&str] = &[
    "com.apple.terminal",
    "com.googlecode.iterm2",
    "dev.warp.warp",
    "com.github.wez.wezterm",
    "io.alacritty",
    "org.alacritty",
    "net.kovidgoyal.kitty",
    "co.zeit.hyper",
    "org.tabby",
    "com.tabby",
    "com.mitchellh.ghostty",
];

/// Why typing could not start or did not finish.
#[derive(Debug)]
pub enum TypeError {
    /// The app has no Accessibility permission.
    NotTrusted,
    /// Secure event input is on (a password field somewhere has the keyboard).
    SecureInputActive,
    /// macOS could not create the event source or a key event.
    EventAllocFailed,
    /// The caller asked to stop.
    Interrupted,
}

/// How far an operation got before it stopped.
#[derive(Debug)]
pub struct Partial {
    /// Characters typed (or keys pressed) before the error.
    pub done: usize,
    pub error: TypeError,
}

/// The focused field's text and selection, in UTF-16 code units (the units
/// Accessibility ranges count in).
pub struct CaretContext {
    pub value: Vec<u16>,
    pub selection_start: usize,
    pub selection_len: usize,
}

/// Result of checking that typed text landed where it was meant to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verdict {
    Ok,
    FocusMoved,
    TextMismatch,
}

/// What a newline in the text becomes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NewlineMode {
    /// Shift+Return: a line break that does not send the message.
    ShiftReturn,
    /// A literal U+000A, for terminals (Shift+Return would run the command there).
    LineFeed,
}

impl NewlineMode {
    pub fn for_bundle_id(bundle_id: Option<&str>) -> Self {
        match bundle_id {
            Some(id) if is_terminal_bundle_id(id) => NewlineMode::LineFeed,
            _ => NewlineMode::ShiftReturn,
        }
    }
}

/// Whether the app with this bundle id is a terminal emulator.
pub fn is_terminal_bundle_id(bundle_id: &str) -> bool {
    let id = bundle_id.to_ascii_lowercase();
    TERMINAL_BUNDLE_PREFIXES
        .iter()
        .any(|prefix| id.starts_with(prefix))
}

/// Whether the text right before the caret is exactly `typed`, with nothing
/// selected. An app that autocorrected or reformatted the text fails the check.
pub fn caret_text_matches(context: &CaretContext, typed: &str) -> bool {
    if context.selection_len != 0 {
        return false;
    }
    let Some(before_caret) = context.value.get(..context.selection_start) else {
        return false;
    };
    let typed: Vec<u16> = typed.encode_utf16().collect();
    before_caret.ends_with(&typed)
}

/// One key press (down and up).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
enum Keystroke {
    /// A key with no text, optionally with Shift.
    Key { code: u16, shift: bool },
    /// A character delivered as the event's Unicode string.
    Text(char),
}

/// The keystroke that types `ch`, or `None` for a character that is dropped.
fn keystroke_for(ch: char, newline: NewlineMode) -> Option<Keystroke> {
    match ch {
        // Windows line ends: the '\n' that follows carries the line break.
        '\r' => None,
        '\n' if newline == NewlineMode::ShiftReturn => Some(Keystroke::Key {
            code: KEY_RETURN,
            shift: true,
        }),
        other => Some(Keystroke::Text(other)),
    }
}

pub fn is_secure_input_enabled() -> bool {
    sys::secure_input_enabled()
}

/// Typing needs the Accessibility permission and no secure input.
pub fn check_typing_available() -> Result<(), TypeError> {
    if !sys::process_is_trusted() {
        return Err(TypeError::NotTrusted);
    }
    if is_secure_input_enabled() {
        return Err(TypeError::SecureInputActive);
    }
    Ok(())
}

/// Types `text` into the focused field, one keystroke per character, calling
/// `on_char` for every character that was typed. Returns how many were typed;
/// dropped '\r' characters are not counted.
pub fn type_unicode_chunk(
    text: &str,
    newline: NewlineMode,
    interrupted: &AtomicBool,
    on_char: &mut dyn FnMut(char),
) -> Result<usize, Partial> {
    if text.is_empty() {
        return Ok(0);
    }
    check_typing_available().map_err(|error| Partial { done: 0, error })?;
    let mut typed = 0;
    for ch in text.chars() {
        if interrupted.load(Ordering::SeqCst) {
            return Err(Partial {
                done: typed,
                error: TypeError::Interrupted,
            });
        }
        let Some(keystroke) = keystroke_for(ch, newline) else {
            continue;
        };
        sys::post_keystroke(keystroke).map_err(|error| Partial { done: typed, error })?;
        typed += 1;
        on_char(ch);
        std::thread::sleep(KEYSTROKE_PAUSE);
    }
    Ok(typed)
}

/// Presses Backspace `count` times, calling `on_key` after each press.
pub fn press_backspace(
    count: usize,
    interrupted: &AtomicBool,
    on_key: &mut dyn FnMut(),
) -> Result<(), Partial> {
    if count == 0 {
        return Ok(());
    }
    check_typing_available().map_err(|error| Partial { done: 0, error })?;
    for pressed in 0..count {
        if interrupted.load(Ordering::SeqCst) {
            return Err(Partial {
                done: pressed,
                error: TypeError::Interrupted,
            });
        }
        let backspace = Keystroke::Key {
            code: KEY_BACKSPACE,
            shift: false,
        };
        sys::post_keystroke(backspace).map_err(|error| Partial {
            done: pressed,
            error,
        })?;
        on_key();
        std::thread::sleep(KEYSTROKE_PAUSE);
    }
    Ok(())
}

/// Presses Return once (no modifiers).
pub fn press_return() -> Result<(), TypeError> {
    check_typing_available()?;
    sys::post_keystroke(Keystroke::Key {
        code: KEY_RETURN,
        shift: false,
    })
}

/// Process id of the frontmost application, as Accessibility sees it.
pub fn focused_app_pid() -> Option<i32> {
    sys::focused_app_pid()
}

/// Title of the focused window of the frontmost application.
pub fn focused_window_title() -> Option<String> {
    sys::focused_window_title()
}

/// The focused UI element, retained until dropped.
pub struct FocusedElement {
    element: sys::Element,
}

impl FocusedElement {
    pub fn capture() -> Option<Self> {
        sys::focused_element().map(|element| FocusedElement { element })
    }

    pub fn is_same(&self, other: &FocusedElement) -> bool {
        sys::same_element(&self.element, &other.element)
    }

    /// The field's text and selection; `None` when the element has no text value
    /// or no readable selection.
    pub fn caret_context(&self) -> Option<CaretContext> {
        let value = sys::string_attribute(&self.element, "AXValue")?;
        let (start, len) = sys::selected_range(&self.element)?;
        if start < 0 || len < 0 {
            return None;
        }
        Some(CaretContext {
            value,
            selection_start: start as usize,
            selection_len: len as usize,
        })
    }

    /// Whether the element is a password field.
    pub fn is_secure_field(&self) -> bool {
        sys::string_attribute(&self.element, "AXSubrole").is_some_and(|subrole| {
            subrole
                .iter()
                .copied()
                .eq("AXSecureTextField".encode_utf16())
        })
    }

    /// Up to `max_units` UTF-16 units of the text before the caret (the selection
    /// start). `None` when the caret is at the very beginning or unreadable.
    pub fn text_before_caret(&self, max_units: usize) -> Option<String> {
        let (caret, _) = sys::selected_range(&self.element)?;
        if caret <= 0 {
            return None;
        }
        let value = sys::string_attribute(&self.element, "AXValue")?;
        Some(text_before(&value, caret as usize, max_units))
    }
}

/// The text of `value` that ends at `caret` and is at most `max_units` long. A
/// window that starts in the middle of a surrogate pair loses the broken half.
fn text_before(value: &[u16], caret: usize, max_units: usize) -> String {
    let end = caret.min(value.len());
    let start = end.saturating_sub(max_units);
    let text = String::from_utf16_lossy(&value[start..end]);
    text.trim_start_matches(char::REPLACEMENT_CHARACTER)
        .to_string()
}

/// Where typing started: the frontmost app and, when Accessibility exposes it,
/// the focused element. Typing continues only while focus stays there.
pub struct FocusAnchor {
    pid: i32,
    element: Option<FocusedElement>,
}

impl FocusAnchor {
    pub fn capture() -> Option<Self> {
        let pid = focused_app_pid()?;
        Some(FocusAnchor {
            pid,
            element: FocusedElement::capture(),
        })
    }

    pub fn pid(&self) -> i32 {
        self.pid
    }

    /// Checks that focus is still on the anchor and that the text before the
    /// caret ends with `typed`. Looks a few times, since apps update their
    /// Accessibility value a little after the keystrokes arrive.
    pub fn verify(&self, typed: &str, interrupted: &AtomicBool) -> Verdict {
        let mut verdict = self.check(typed);
        for _ in 1..VERIFY_ATTEMPTS {
            if verdict == Verdict::Ok {
                break;
            }
            std::thread::sleep(VERIFY_PAUSE);
            if interrupted.load(Ordering::SeqCst) {
                break;
            }
            verdict = self.check(typed);
        }
        verdict
    }

    fn check(&self, typed: &str) -> Verdict {
        let current = FocusedElement::capture();
        let focus_kept = match (&self.element, &current) {
            (Some(anchor), Some(now)) => anchor.is_same(now),
            (Some(_), None) => false,
            (None, _) => focused_app_pid() == Some(self.pid),
        };
        if !focus_kept {
            return Verdict::FocusMoved;
        }
        if typed.is_empty() {
            return Verdict::Ok;
        }
        match current.as_ref().and_then(FocusedElement::caret_context) {
            Some(context) if !caret_text_matches(&context, typed) => Verdict::TextMismatch,
            _ => Verdict::Ok,
        }
    }
}

#[cfg(target_os = "macos")]
mod sys {
    use super::{Keystroke, TypeError, SYNTHETIC_EVENT_MARKER};
    use std::ffi::{c_char, c_void, CString};
    use std::ptr;

    type CFTypeRef = *const c_void;

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct CFRange {
        location: isize,
        length: isize,
    }

    const K_CG_EVENT_SOURCE_STATE_HID_SYSTEM_STATE: i32 = 1;
    const K_CG_HID_EVENT_TAP: u32 = 0;
    const K_CG_EVENT_FLAG_MASK_SHIFT: u64 = 0x0002_0000;
    const K_AX_VALUE_TYPE_CF_RANGE: u32 = 4;
    const K_CF_STRING_ENCODING_UTF8: u32 = 0x0800_0100;
    const AX_MESSAGING_TIMEOUT_SECONDS: f32 = 1.5;
    const AX_SUCCESS: i32 = 0;

    #[link(name = "CoreFoundation", kind = "framework")]
    extern "C" {
        fn CFRelease(cf: CFTypeRef);
        fn CFEqual(cf1: CFTypeRef, cf2: CFTypeRef) -> u8;
        fn CFGetTypeID(cf: CFTypeRef) -> usize;
        fn CFStringGetTypeID() -> usize;
        fn CFStringGetLength(string: CFTypeRef) -> isize;
        fn CFStringGetCharacters(string: CFTypeRef, range: CFRange, buffer: *mut u16);
        fn CFStringCreateWithCString(
            allocator: CFTypeRef,
            c_str: *const c_char,
            encoding: u32,
        ) -> CFTypeRef;
    }

    #[link(name = "CoreGraphics", kind = "framework")]
    extern "C" {
        fn CGEventSourceCreate(state_id: i32) -> CFTypeRef;
        fn CGEventSourceSetUserData(source: CFTypeRef, user_data: i64);
        fn CGEventCreateKeyboardEvent(
            source: CFTypeRef,
            key_code: u16,
            key_down: bool,
        ) -> CFTypeRef;
        fn CGEventSetFlags(event: CFTypeRef, flags: u64);
        fn CGEventKeyboardSetUnicodeString(event: CFTypeRef, length: usize, string: *const u16);
        fn CGEventPost(tap: u32, event: CFTypeRef);
    }

    #[link(name = "ApplicationServices", kind = "framework")]
    extern "C" {
        fn AXIsProcessTrusted() -> u8;
        fn AXUIElementCreateSystemWide() -> CFTypeRef;
        fn AXUIElementSetMessagingTimeout(element: CFTypeRef, timeout_seconds: f32) -> i32;
        fn AXUIElementCopyAttributeValue(
            element: CFTypeRef,
            attribute: CFTypeRef,
            value: *mut CFTypeRef,
        ) -> i32;
        fn AXUIElementGetPid(element: CFTypeRef, pid: *mut i32) -> i32;
        fn AXValueGetValue(value: CFTypeRef, value_type: u32, value_out: *mut c_void) -> u8;
    }

    #[link(name = "Carbon", kind = "framework")]
    extern "C" {
        fn IsSecureEventInputEnabled() -> u8;
    }

    /// A Core Foundation object this code owns (a +1 reference), released on drop.
    pub struct Element(CFTypeRef);

    // AXUIElement and the other CF objects held here are immutable references
    // to system objects; retaining, releasing and querying them is thread-safe.
    unsafe impl Send for Element {}
    unsafe impl Sync for Element {}

    impl Element {
        /// Takes ownership of a +1 reference; NULL (an absent attribute, a failed
        /// create) gives `None`, so no `Element` ever wraps NULL.
        fn adopt(raw: CFTypeRef) -> Option<Self> {
            if raw.is_null() {
                None
            } else {
                Some(Element(raw))
            }
        }
    }

    impl Drop for Element {
        fn drop(&mut self) {
            // CFRelease(NULL) aborts the process; adopt() never lets NULL in, and
            // this guard keeps it that way.
            if !self.0.is_null() {
                unsafe { CFRelease(self.0) };
            }
        }
    }

    pub fn process_is_trusted() -> bool {
        unsafe { AXIsProcessTrusted() != 0 }
    }

    pub fn secure_input_enabled() -> bool {
        unsafe { IsSecureEventInputEnabled() != 0 }
    }

    pub fn post_keystroke(keystroke: Keystroke) -> Result<(), TypeError> {
        let (code, flags, text) = match keystroke {
            Keystroke::Key { code, shift } => (
                code,
                if shift { K_CG_EVENT_FLAG_MASK_SHIFT } else { 0 },
                None,
            ),
            Keystroke::Text(ch) => {
                let mut units = [0u16; 2];
                let len = ch.encode_utf16(&mut units).len();
                (0, 0, Some((units, len)))
            }
        };
        unsafe {
            let source = Element::adopt(CGEventSourceCreate(
                K_CG_EVENT_SOURCE_STATE_HID_SYSTEM_STATE,
            ))
            .ok_or(TypeError::EventAllocFailed)?;
            CGEventSourceSetUserData(source.0, SYNTHETIC_EVENT_MARKER);
            let down = Element::adopt(CGEventCreateKeyboardEvent(source.0, code, true))
                .ok_or(TypeError::EventAllocFailed)?;
            let up = Element::adopt(CGEventCreateKeyboardEvent(source.0, code, false))
                .ok_or(TypeError::EventAllocFailed)?;
            for event in [&down, &up] {
                // Set, not add: modifiers the user is holding must not change the key.
                CGEventSetFlags(event.0, flags);
                if let Some((units, len)) = &text {
                    CGEventKeyboardSetUnicodeString(event.0, *len, units.as_ptr());
                }
            }
            CGEventPost(K_CG_HID_EVENT_TAP, down.0);
            CGEventPost(K_CG_HID_EVENT_TAP, up.0);
        }
        Ok(())
    }

    fn system_wide() -> Option<Element> {
        let element = Element::adopt(unsafe { AXUIElementCreateSystemWide() })?;
        unsafe { AXUIElementSetMessagingTimeout(element.0, AX_MESSAGING_TIMEOUT_SECONDS) };
        Some(element)
    }

    /// The value of an attribute, owned; `None` on any error.
    fn copy_attribute(element: &Element, name: &str) -> Option<Element> {
        let name = CString::new(name).ok()?;
        let key = Element::adopt(unsafe {
            CFStringCreateWithCString(ptr::null(), name.as_ptr(), K_CF_STRING_ENCODING_UTF8)
        })?;
        let mut raw: CFTypeRef = ptr::null();
        let status = unsafe { AXUIElementCopyAttributeValue(element.0, key.0, &mut raw) };
        let value = Element::adopt(raw);
        if status != AX_SUCCESS {
            return None;
        }
        value
    }

    fn utf16_of(string: &Element) -> Option<Vec<u16>> {
        unsafe {
            if CFGetTypeID(string.0) != CFStringGetTypeID() {
                return None;
            }
            let length = CFStringGetLength(string.0);
            let mut units = vec![0u16; usize::try_from(length).ok()?];
            if !units.is_empty() {
                CFStringGetCharacters(
                    string.0,
                    CFRange {
                        location: 0,
                        length,
                    },
                    units.as_mut_ptr(),
                );
            }
            Some(units)
        }
    }

    pub fn string_attribute(element: &Element, name: &str) -> Option<Vec<u16>> {
        utf16_of(&copy_attribute(element, name)?)
    }

    /// `AXSelectedTextRange` as (location, length).
    pub fn selected_range(element: &Element) -> Option<(isize, isize)> {
        let value = copy_attribute(element, "AXSelectedTextRange")?;
        let mut range = CFRange {
            location: 0,
            length: 0,
        };
        let ok = unsafe {
            AXValueGetValue(
                value.0,
                K_AX_VALUE_TYPE_CF_RANGE,
                &mut range as *mut CFRange as *mut c_void,
            )
        };
        (ok != 0).then_some((range.location, range.length))
    }

    fn focused_application() -> Option<Element> {
        let app = copy_attribute(&system_wide()?, "AXFocusedApplication")?;
        unsafe { AXUIElementSetMessagingTimeout(app.0, AX_MESSAGING_TIMEOUT_SECONDS) };
        Some(app)
    }

    pub fn focused_app_pid() -> Option<i32> {
        let app = focused_application()?;
        let mut pid = 0;
        let status = unsafe { AXUIElementGetPid(app.0, &mut pid) };
        (status == AX_SUCCESS).then_some(pid)
    }

    pub fn focused_window_title() -> Option<String> {
        let window = copy_attribute(&focused_application()?, "AXFocusedWindow")?;
        let title = string_attribute(&window, "AXTitle")?;
        Some(String::from_utf16_lossy(&title))
    }

    pub fn focused_element() -> Option<Element> {
        copy_attribute(&system_wide()?, "AXFocusedUIElement")
    }

    pub fn same_element(a: &Element, b: &Element) -> bool {
        unsafe { CFEqual(a.0, b.0) != 0 }
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn null_is_never_adopted() {
            assert!(Element::adopt(ptr::null()).is_none());
        }
    }
}

/// Off macOS there is nothing to type into: typing reports `NotTrusted` and no
/// application or element is ever focused.
#[cfg(not(target_os = "macos"))]
mod sys {
    use super::{Keystroke, TypeError};

    pub enum Element {}

    pub fn process_is_trusted() -> bool {
        false
    }

    pub fn secure_input_enabled() -> bool {
        false
    }

    pub fn post_keystroke(_keystroke: Keystroke) -> Result<(), TypeError> {
        Err(TypeError::EventAllocFailed)
    }

    pub fn string_attribute(element: &Element, _name: &str) -> Option<Vec<u16>> {
        match *element {}
    }

    pub fn selected_range(element: &Element) -> Option<(isize, isize)> {
        match *element {}
    }

    pub fn focused_app_pid() -> Option<i32> {
        None
    }

    pub fn focused_window_title() -> Option<String> {
        None
    }

    pub fn focused_element() -> Option<Element> {
        None
    }

    pub fn same_element(a: &Element, _b: &Element) -> bool {
        match *a {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn field(text: &str, selection_start: usize, selection_len: usize) -> CaretContext {
        CaretContext {
            value: text.encode_utf16().collect(),
            selection_start,
            selection_len,
        }
    }

    #[test]
    fn terminals_are_recognised_by_bundle_id_prefix() {
        for id in [
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "com.mitchellh.ghostty",
            "dev.warp.Warp-Stable",
            "net.kovidgoyal.kitty",
            "com.github.wez.wezterm",
            "io.alacritty",
            "org.alacritty",
            "co.zeit.hyper",
            "org.tabby",
        ] {
            assert!(is_terminal_bundle_id(id), "{id}");
        }
    }

    #[test]
    fn ordinary_apps_are_not_terminals() {
        for id in [
            "com.apple.Safari",
            "com.tinyspeck.slackmacgap",
            "com.microsoft.VSCode",
            "com.todesktop.230313mzl4w4u92",
            "ru.keepcoder.Telegram",
            "",
        ] {
            assert!(!is_terminal_bundle_id(id), "{id}");
        }
    }

    #[test]
    fn newline_mode_follows_the_app() {
        assert_eq!(
            NewlineMode::for_bundle_id(Some("com.apple.Terminal")),
            NewlineMode::LineFeed
        );
        assert_eq!(
            NewlineMode::for_bundle_id(Some("com.apple.Safari")),
            NewlineMode::ShiftReturn
        );
        assert_eq!(NewlineMode::for_bundle_id(None), NewlineMode::ShiftReturn);
    }

    #[test]
    fn a_newline_never_becomes_a_plain_return() {
        assert_eq!(
            keystroke_for('\n', NewlineMode::ShiftReturn),
            Some(Keystroke::Key {
                code: KEY_RETURN,
                shift: true
            })
        );
        assert_eq!(
            keystroke_for('\n', NewlineMode::LineFeed),
            Some(Keystroke::Text('\n'))
        );
    }

    #[test]
    fn carriage_returns_are_dropped_and_other_chars_typed_as_text() {
        for mode in [NewlineMode::ShiftReturn, NewlineMode::LineFeed] {
            assert_eq!(keystroke_for('\r', mode), None);
            assert_eq!(keystroke_for('ы', mode), Some(Keystroke::Text('ы')));
            assert_eq!(keystroke_for('\t', mode), Some(Keystroke::Text('\t')));
        }
    }

    #[test]
    fn caret_check_accepts_the_typed_tail() {
        let ctx = field("было привет", 11, 0);
        assert!(caret_text_matches(&ctx, "привет"));
        assert!(caret_text_matches(&ctx, "было привет"));
        assert!(!caret_text_matches(&ctx, "приветик"));
    }

    #[test]
    fn caret_check_rejects_text_the_app_changed() {
        assert!(!caret_text_matches(
            &field("ну… ладно", 9, 0),
            "ну... ладно"
        ));
        assert!(!caret_text_matches(
            &field("он сказал «да»", 14, 0),
            "он сказал \"да\""
        ));
    }

    #[test]
    fn caret_check_rejects_a_selection_or_a_caret_out_of_range() {
        assert!(!caret_text_matches(&field("привет", 6, 2), "привет"));
        assert!(!caret_text_matches(&field("при", 3, 0), "привет"));
        assert!(!caret_text_matches(&field("привет", 9, 0), "т"));
    }

    #[test]
    fn caret_check_counts_utf16_units() {
        let ctx = field("a😀b", 4, 0);
        assert!(caret_text_matches(&ctx, "😀b"));
        assert!(!caret_text_matches(&ctx, "a😀b😀"));
    }

    #[test]
    fn nothing_typed_matches_any_valid_caret() {
        assert!(caret_text_matches(&field("abc", 1, 0), ""));
    }

    #[test]
    fn text_before_caret_window_drops_a_cut_surrogate() {
        let value: Vec<u16> = "x😀yz".encode_utf16().collect();
        assert_eq!(text_before(&value, 5, 10), "x😀yz");
        assert_eq!(text_before(&value, 5, 3), "yz");
        assert_eq!(text_before(&value, 3, 10), "x😀");
        assert_eq!(text_before(&value, 99, 2), "yz");
    }

    #[test]
    fn empty_text_and_zero_backspaces_need_no_permission() {
        let stop = AtomicBool::new(false);
        assert!(matches!(
            type_unicode_chunk("", NewlineMode::ShiftReturn, &stop, &mut |_| {}),
            Ok(0)
        ));
        assert!(press_backspace(0, &stop, &mut || {}).is_ok());
    }
}
