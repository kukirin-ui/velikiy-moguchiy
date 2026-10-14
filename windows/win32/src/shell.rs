//! A hidden window that owns the message loop: wake-ups from other threads,
//! timers and tray clicks all arrive here and go to one handler.

use crate::wide::Wide;
use std::cell::{Cell, RefCell};
use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, POINT, WPARAM};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::WindowsAndMessaging::{
    AppendMenuW, CreatePopupMenu, CreateWindowExW, DefWindowProcW, DestroyMenu, DispatchMessageW,
    GetCursorPos, GetMessageW, KillTimer, PostMessageW, PostQuitMessage, RegisterClassExW,
    RegisterWindowMessageW, SetForegroundWindow, SetTimer, TrackPopupMenu, TranslateMessage,
    MF_GRAYED, MF_SEPARATOR, MF_STRING, MSG, TPM_BOTTOMALIGN, TPM_NONOTIFY, TPM_RETURNCMD,
    TPM_RIGHTBUTTON, WM_APP, WM_CLOSE, WM_LBUTTONUP, WM_NULL, WM_RBUTTONUP, WM_TIMER, WNDCLASSEXW,
    WS_EX_TOOLWINDOW, WS_POPUP,
};

const WM_WAKE: u32 = WM_APP + 1;
/// The tray icon's callback message (see `tray.rs`).
pub(crate) const WM_TRAY: u32 = WM_APP + 2;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ShellEvent {
    /// Something was queued for the UI thread.
    Wake,
    Timer(usize),
    TrayLeftClick,
    /// The handler may answer with [`Shell::show_menu`].
    TrayRightClick,
    /// An item of the menu requested with [`Shell::show_menu`] was chosen.
    MenuCommand(u32),
    /// Explorer restarted; the tray icon has to be added again.
    TaskbarCreated,
    /// Another program sent `WM_CLOSE` to the hidden window (the smoke test
    /// does): quit the way the tray menu does.
    CloseRequested,
}

pub enum MenuItem {
    Item {
        id: u32,
        title: String,
        enabled: bool,
    },
    Separator,
}

pub type ShellHandler = Box<dyn FnMut(ShellEvent)>;

thread_local! {
    static HANDLER: RefCell<Option<ShellHandler>> = const { RefCell::new(None) };
    static TASKBAR_CREATED: Cell<u32> = const { Cell::new(0) };
    static WAKE_PENDING: Cell<bool> = const { Cell::new(false) };
    static PENDING_MENU: RefCell<Option<Vec<MenuItem>>> = const { RefCell::new(None) };
}

/// Posts a wake-up to the UI thread. Cheap to copy, usable from any thread.
#[derive(Clone, Copy)]
pub struct Waker(isize);

impl Waker {
    pub fn wake(&self) {
        unsafe {
            let _ = PostMessageW(Some(HWND(self.0 as *mut _)), WM_WAKE, WPARAM(0), LPARAM(0));
        }
    }
}

#[derive(Clone, Copy)]
pub struct Shell {
    hwnd: HWND,
}

impl Shell {
    pub fn create() -> windows::core::Result<Shell> {
        let class = Wide::new("VelikiyMoguchiyShell");
        unsafe {
            let instance = GetModuleHandleW(None)?;
            let wc = WNDCLASSEXW {
                cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
                lpfnWndProc: Some(wnd_proc),
                hInstance: instance.into(),
                lpszClassName: class.pcwstr(),
                ..Default::default()
            };
            RegisterClassExW(&wc);
            TASKBAR_CREATED
                .with(|c| c.set(RegisterWindowMessageW(Wide::new("TaskbarCreated").pcwstr())));
            // A real top-level window, never shown: message-only windows miss
            // the TaskbarCreated broadcast.
            let hwnd = CreateWindowExW(
                WS_EX_TOOLWINDOW,
                class.pcwstr(),
                Wide::new("«Великий & Могучий»").pcwstr(),
                WS_POPUP,
                0,
                0,
                0,
                0,
                None,
                None,
                Some(instance.into()),
                None,
            )?;
            crate::clipboard::set_owner(hwnd);
            Ok(Shell { hwnd })
        }
    }

    pub fn hwnd(&self) -> HWND {
        self.hwnd
    }

    pub fn waker(&self) -> Waker {
        Waker(self.hwnd.0 as isize)
    }

    pub fn set_handler(&self, handler: ShellHandler) {
        HANDLER.with(|h| *h.borrow_mut() = Some(handler));
    }

    /// Fires `ShellEvent::Timer(id)` every `ms` until stopped; starting a
    /// running id again replaces its period.
    pub fn start_timer(&self, id: usize, ms: u32) {
        unsafe {
            SetTimer(Some(self.hwnd), id, ms, None);
        }
    }

    pub fn stop_timer(&self, id: usize) {
        unsafe {
            let _ = KillTimer(Some(self.hwnd), id);
        }
    }

    /// Shows a menu at the cursor once the running handler returns; the
    /// choice comes back as `ShellEvent::MenuCommand`.
    pub fn show_menu(&self, items: Vec<MenuItem>) {
        PENDING_MENU.with(|m| *m.borrow_mut() = Some(items));
    }

    /// Runs until [`quit`] is called.
    pub fn run(&self) {
        let mut msg = MSG::default();
        unsafe {
            while GetMessageW(&mut msg, None, 0, 0).as_bool() {
                if crate::form::handle_dialog_message(&msg) {
                    continue;
                }
                let _ = TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        }
        HANDLER.with(|h| *h.borrow_mut() = None);
    }
}

pub fn quit() {
    unsafe { PostQuitMessage(0) };
}

fn call(event: ShellEvent) -> bool {
    HANDLER.with(|h| match h.try_borrow_mut() {
        Ok(mut h) => {
            if let Some(f) = h.as_mut() {
                f(event);
            }
            true
        }
        Err(_) => false,
    })
}

fn dispatch(hwnd: HWND, event: ShellEvent) {
    if !call(event) {
        // Re-entered from a nested message loop inside the handler: a wake-up
        // is replayed when the handler returns, anything else is dropped.
        if event == ShellEvent::Wake {
            WAKE_PENDING.with(|w| w.set(true));
        }
        return;
    }
    while WAKE_PENDING.with(|w| w.replace(false)) {
        call(ShellEvent::Wake);
    }
    if let Some(items) = PENDING_MENU.with(|m| m.borrow_mut().take()) {
        if let Some(id) = track_menu(hwnd, &items) {
            dispatch(hwnd, ShellEvent::MenuCommand(id));
        }
    }
}

fn track_menu(owner: HWND, items: &[MenuItem]) -> Option<u32> {
    unsafe {
        let menu = CreatePopupMenu().ok()?;
        for item in items {
            match item {
                MenuItem::Item { id, title, enabled } => {
                    let flags = if *enabled {
                        MF_STRING
                    } else {
                        MF_STRING | MF_GRAYED
                    };
                    let title = Wide::new(title);
                    let _ = AppendMenuW(menu, flags, *id as usize, title.pcwstr());
                }
                MenuItem::Separator => {
                    let _ = AppendMenuW(menu, MF_SEPARATOR, 0, windows::core::PCWSTR::null());
                }
            }
        }
        let mut pt = POINT::default();
        let _ = GetCursorPos(&mut pt);
        // Without this the menu does not close when the user clicks elsewhere.
        let _ = SetForegroundWindow(owner);
        let chosen = TrackPopupMenu(
            menu,
            TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON | TPM_BOTTOMALIGN,
            pt.x,
            pt.y,
            None,
            owner,
            None,
        );
        let _ = PostMessageW(Some(owner), WM_NULL, WPARAM(0), LPARAM(0));
        let _ = DestroyMenu(menu);
        let id = chosen.0 as u32;
        (id != 0).then_some(id)
    }
}

unsafe extern "system" fn wnd_proc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    match msg {
        WM_WAKE => {
            dispatch(hwnd, ShellEvent::Wake);
            LRESULT(0)
        }
        WM_TIMER => {
            dispatch(hwnd, ShellEvent::Timer(wparam.0));
            LRESULT(0)
        }
        WM_CLOSE => {
            dispatch(hwnd, ShellEvent::CloseRequested);
            LRESULT(0)
        }
        WM_TRAY => {
            match (lparam.0 & 0xFFFF) as u32 {
                WM_LBUTTONUP => dispatch(hwnd, ShellEvent::TrayLeftClick),
                WM_RBUTTONUP => dispatch(hwnd, ShellEvent::TrayRightClick),
                _ => {}
            }
            LRESULT(0)
        }
        _ if msg != 0 && msg == TASKBAR_CREATED.with(|c| c.get()) => {
            dispatch(hwnd, ShellEvent::TaskbarCreated);
            LRESULT(0)
        }
        _ => unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) },
    }
}
