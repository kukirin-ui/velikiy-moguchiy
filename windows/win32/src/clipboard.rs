//! Unicode text on the clipboard.

use crate::wide::Wide;
use std::sync::atomic::{AtomicIsize, Ordering};
use windows::Win32::Foundation::{GlobalFree, HANDLE, HGLOBAL, HWND};
use windows::Win32::System::DataExchange::{
    CloseClipboard, EmptyClipboard, GetClipboardData, IsClipboardFormatAvailable, OpenClipboard,
    RegisterClipboardFormatW, SetClipboardData,
};
use windows::Win32::System::Memory::{
    GlobalAlloc, GlobalLock, GlobalSize, GlobalUnlock, GMEM_MOVEABLE,
};
use windows::Win32::System::Ole::CF_UNICODETEXT;

/// SetClipboardData fails after EmptyClipboard unless the clipboard was
/// opened by a window, which then owns the data.
static OWNER: AtomicIsize = AtomicIsize::new(0);

pub(crate) fn set_owner(hwnd: HWND) {
    OWNER.store(hwnd.0 as isize, Ordering::Relaxed);
}

struct Open;

impl Open {
    /// Another program may hold the clipboard for a moment; retry briefly.
    fn new() -> Option<Open> {
        let owner = match OWNER.load(Ordering::Relaxed) {
            0 => None,
            h => Some(HWND(h as *mut _)),
        };
        for _ in 0..10 {
            if unsafe { OpenClipboard(owner) }.is_ok() {
                return Some(Open);
            }
            std::thread::sleep(std::time::Duration::from_millis(15));
        }
        log::warn!("clipboard is busy");
        None
    }
}

impl Drop for Open {
    fn drop(&mut self) {
        unsafe {
            let _ = CloseClipboard();
        }
    }
}

pub fn text() -> Option<String> {
    let _open = Open::new()?;
    unsafe {
        IsClipboardFormatAvailable(u32::from(CF_UNICODETEXT.0)).ok()?;
        let handle = GetClipboardData(u32::from(CF_UNICODETEXT.0)).ok()?;
        let global = HGLOBAL(handle.0);
        let ptr = GlobalLock(global) as *const u16;
        if ptr.is_null() {
            return None;
        }
        let max = GlobalSize(global) / 2;
        let units = std::slice::from_raw_parts(ptr, max);
        let len = units.iter().position(|&c| c == 0).unwrap_or(max);
        let s = String::from_utf16_lossy(&units[..len]);
        let _ = GlobalUnlock(global);
        Some(s)
    }
}

fn global_from(bytes: &[u8]) -> Option<HGLOBAL> {
    unsafe {
        let global = GlobalAlloc(GMEM_MOVEABLE, bytes.len()).ok()?;
        let ptr = GlobalLock(global) as *mut u8;
        if ptr.is_null() {
            let _ = GlobalFree(Some(global));
            return None;
        }
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), ptr, bytes.len());
        let _ = GlobalUnlock(global);
        Some(global)
    }
}

/// Hands `global` to the clipboard, which owns it from then on; frees it when
/// the clipboard refuses.
unsafe fn put(format: u32, global: HGLOBAL) -> bool {
    if unsafe { SetClipboardData(format, Some(HANDLE(global.0))) }.is_ok() {
        return true;
    }
    let _ = unsafe { GlobalFree(Some(global)) };
    false
}

/// `transient`: keep the text out of clipboard history and cloud sync
/// (Win+V), because it is only the vehicle for a paste.
pub fn set_text(s: &str, transient: bool) -> bool {
    let Some(_open) = Open::new() else {
        return false;
    };
    let units: Vec<u16> = s.encode_utf16().chain(std::iter::once(0)).collect();
    let bytes: Vec<u8> = units.iter().flat_map(|u| u.to_le_bytes()).collect();
    unsafe {
        if EmptyClipboard().is_err() {
            return false;
        }
        let Some(data) = global_from(&bytes) else {
            return false;
        };
        if !put(u32::from(CF_UNICODETEXT.0), data) {
            return false;
        }
        if transient {
            // https://learn.microsoft.com/windows/win32/dataxchg/clipboard-formats#cloud-clipboard-and-clipboard-history-formats
            for name in [
                "ExcludeClipboardContentFromMonitorProcessing",
                "CanIncludeInClipboardHistory",
                "CanUploadToCloudClipboard",
            ] {
                let format = RegisterClipboardFormatW(Wide::new(name).pcwstr());
                if format != 0 {
                    if let Some(zero) = global_from(&0u32.to_le_bytes()) {
                        put(format, zero);
                    }
                }
            }
        }
    }
    true
}
