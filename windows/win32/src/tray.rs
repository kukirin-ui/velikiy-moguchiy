//! The notification-area icon and its menu.

use crate::shell::WM_TRAY;
use crate::wide::fill;
use windows::Win32::Foundation::HWND;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Shell::{
    Shell_NotifyIconW, NIF_ICON, NIF_INFO, NIF_MESSAGE, NIF_TIP, NIIF_INFO, NIM_ADD, NIM_DELETE,
    NIM_MODIFY, NOTIFYICONDATAW,
};
use windows::Win32::UI::WindowsAndMessaging::{LoadIconW, HICON, IDI_APPLICATION};

/// Icon resource ids in the executable (see `app/resources/app.rc`).
pub const ICON_IDLE: u16 = 1;
pub const ICON_RECORDING: u16 = 2;

pub struct Tray {
    data: NOTIFYICONDATAW,
    idle: HICON,
    recording: HICON,
}

fn load_icon(id: u16) -> HICON {
    unsafe {
        let instance = GetModuleHandleW(None).ok();
        // MAKEINTRESOURCE: the id travels in the pointer value.
        let name = windows::core::PCWSTR(id as usize as *const u16);
        LoadIconW(instance.map(Into::into), name)
            .or_else(|_| LoadIconW(None, IDI_APPLICATION))
            .unwrap_or_default()
    }
}

impl Tray {
    pub fn add(owner: HWND, tooltip: &str) -> Tray {
        let idle = load_icon(ICON_IDLE);
        let recording = load_icon(ICON_RECORDING);
        let mut data = NOTIFYICONDATAW {
            cbSize: std::mem::size_of::<NOTIFYICONDATAW>() as u32,
            hWnd: owner,
            uID: 1,
            uFlags: NIF_ICON | NIF_MESSAGE | NIF_TIP,
            uCallbackMessage: WM_TRAY,
            hIcon: idle,
            ..Default::default()
        };
        fill(&mut data.szTip, tooltip);
        let mut tray = Tray {
            data,
            idle,
            recording,
        };
        tray.readd();
        tray
    }

    /// Adds the icon again after Explorer restarted.
    pub fn readd(&mut self) {
        unsafe {
            if !Shell_NotifyIconW(NIM_ADD, &self.data).as_bool() {
                log::warn!("could not add the tray icon");
            }
        }
    }

    pub fn set_recording(&mut self, recording: bool, tooltip: &str) {
        self.data.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
        self.data.hIcon = if recording { self.recording } else { self.idle };
        fill(&mut self.data.szTip, tooltip);
        unsafe {
            let _ = Shell_NotifyIconW(NIM_MODIFY, &self.data);
        }
    }

    /// A balloon / toast next to the icon.
    pub fn notify(&mut self, title: &str, text: &str) {
        let mut data = self.data;
        data.uFlags = NIF_INFO;
        data.dwInfoFlags = NIIF_INFO;
        fill(&mut data.szInfoTitle, title);
        fill(&mut data.szInfo, text);
        unsafe {
            let _ = Shell_NotifyIconW(NIM_MODIFY, &data);
        }
    }
}

impl Drop for Tray {
    fn drop(&mut self) {
        unsafe {
            let _ = Shell_NotifyIconW(NIM_DELETE, &self.data);
        }
    }
}
