//! Synthesized keystrokes: Ctrl+V and Return into the focused window.

use windows::Win32::UI::Input::KeyboardAndMouse::{
    SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYBD_EVENT_FLAGS, KEYEVENTF_KEYUP,
    VIRTUAL_KEY, VK_CONTROL, VK_RETURN, VK_V,
};

/// Marks our own events so that our keyboard hook can recognize them.
pub const INJECTED_TAG: usize = 0x564D_4943; // "VMIC"

/// An unassigned virtual key. Tapping it while Alt is held keeps the Alt
/// release from opening the focused window's menu bar.
const VK_NONE: VIRTUAL_KEY = VIRTUAL_KEY(0xE8);

fn key(vk: VIRTUAL_KEY, up: bool) -> INPUT {
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: vk,
                wScan: 0,
                dwFlags: if up {
                    KEYEVENTF_KEYUP
                } else {
                    KEYBD_EVENT_FLAGS(0)
                },
                time: 0,
                dwExtraInfo: INJECTED_TAG,
            },
        },
    }
}

fn send(inputs: &[INPUT]) -> bool {
    let sent = unsafe { SendInput(inputs, std::mem::size_of::<INPUT>() as i32) };
    sent as usize == inputs.len()
}

pub fn paste() -> bool {
    send(&[
        key(VK_CONTROL, false),
        key(VK_V, false),
        key(VK_V, true),
        key(VK_CONTROL, true),
    ])
}

pub fn press_return() -> bool {
    send(&[key(VK_RETURN, false), key(VK_RETURN, true)])
}

pub fn mask_alt_release() -> bool {
    send(&[key(VK_NONE, false), key(VK_NONE, true)])
}
