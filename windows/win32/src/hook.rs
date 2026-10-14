//! System-wide keyboard hook on a thread of its own. Windows waits for the
//! hook on every key press of every program and silently removes hooks that
//! keep it waiting, so the hook thread does nothing else and the handler must
//! return within milliseconds.

use std::cell::RefCell;
use std::sync::mpsc;
use std::thread::JoinHandle;
use windows::Win32::Foundation::{LPARAM, LRESULT, WPARAM};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Threading::GetCurrentThreadId;
use windows::Win32::UI::WindowsAndMessaging::{
    CallNextHookEx, DispatchMessageW, GetMessageW, PostThreadMessageW, SetWindowsHookExW,
    TranslateMessage, UnhookWindowsHookEx, KBDLLHOOKSTRUCT, LLKHF_INJECTED, MSG, WH_KEYBOARD_LL,
    WM_KEYDOWN, WM_KEYUP, WM_QUIT, WM_SYSKEYDOWN, WM_SYSKEYUP,
};

#[derive(Debug, Clone, Copy)]
pub struct KeyEvent {
    pub vk: u32,
    pub down: bool,
    /// Synthesized input (SendInput), ours or another program's.
    pub injected: bool,
    /// Milliseconds since boot, from the event itself.
    pub time_ms: u32,
}

/// Returns true to hide the event from every other program. Runs on the hook
/// thread.
pub type KeyHandler = Box<dyn FnMut(KeyEvent) -> bool + Send>;

thread_local! {
    static HANDLER: RefCell<Option<KeyHandler>> = const { RefCell::new(None) };
}

pub struct KeyboardHook {
    thread_id: u32,
    thread: Option<JoinHandle<()>>,
}

impl KeyboardHook {
    pub fn install(handler: KeyHandler) -> Result<KeyboardHook, String> {
        let (ready_tx, ready_rx) = mpsc::channel::<Result<u32, String>>();
        let thread = std::thread::Builder::new()
            .name("keyboard-hook".into())
            .spawn(move || {
                HANDLER.with(|h| *h.borrow_mut() = Some(handler));
                let hook = unsafe {
                    GetModuleHandleW(None).and_then(|module| {
                        SetWindowsHookExW(WH_KEYBOARD_LL, Some(hook_proc), Some(module.into()), 0)
                    })
                };
                let hook = match hook {
                    Ok(hook) => hook,
                    Err(e) => {
                        let _ = ready_tx.send(Err(e.to_string()));
                        return;
                    }
                };
                let _ = ready_tx.send(Ok(unsafe { GetCurrentThreadId() }));
                let mut msg = MSG::default();
                unsafe {
                    while GetMessageW(&mut msg, None, 0, 0).as_bool() {
                        let _ = TranslateMessage(&msg);
                        DispatchMessageW(&msg);
                    }
                    let _ = UnhookWindowsHookEx(hook);
                }
            })
            .map_err(|e| e.to_string())?;
        match ready_rx.recv() {
            Ok(Ok(thread_id)) => Ok(KeyboardHook {
                thread_id,
                thread: Some(thread),
            }),
            Ok(Err(e)) => {
                let _ = thread.join();
                Err(e)
            }
            Err(_) => Err("поток клавиатуры завершился".into()),
        }
    }
}

impl Drop for KeyboardHook {
    fn drop(&mut self) {
        unsafe {
            let _ = PostThreadMessageW(self.thread_id, WM_QUIT, WPARAM(0), LPARAM(0));
        }
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

unsafe extern "system" fn hook_proc(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code >= 0 {
        let info = unsafe { &*(lparam.0 as *const KBDLLHOOKSTRUCT) };
        let down = match wparam.0 as u32 {
            WM_KEYDOWN | WM_SYSKEYDOWN => Some(true),
            WM_KEYUP | WM_SYSKEYUP => Some(false),
            _ => None,
        };
        if let Some(down) = down {
            let event = KeyEvent {
                vk: info.vkCode,
                down,
                injected: info.flags.contains(LLKHF_INJECTED),
                time_ms: info.time,
            };
            let swallow = HANDLER.with(|h| match h.try_borrow_mut() {
                Ok(mut h) => h.as_mut().is_some_and(|f| f(event)),
                Err(_) => false,
            });
            if swallow {
                return LRESULT(1);
            }
        }
    }
    unsafe { CallNextHookEx(None, code, wparam, lparam) }
}
