//! The window that has the keyboard focus, and the program it belongs to.

use windows::core::PWSTR;
use windows::Win32::Foundation::CloseHandle;
use windows::Win32::System::Threading::{
    OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION,
};
use windows::Win32::UI::WindowsAndMessaging::{GetForegroundWindow, GetWindowThreadProcessId};

pub struct Foreground {
    pub window: isize,
    /// Full path of the program's executable, when Windows tells us.
    pub exe: Option<String>,
}

pub fn foreground() -> Option<Foreground> {
    let hwnd = unsafe { GetForegroundWindow() };
    if hwnd.0.is_null() {
        return None;
    }
    let mut pid = 0u32;
    unsafe { GetWindowThreadProcessId(hwnd, Some(&mut pid)) };
    Some(Foreground {
        window: hwnd.0 as isize,
        exe: exe_path(pid),
    })
}

fn exe_path(pid: u32) -> Option<String> {
    if pid == 0 {
        return None;
    }
    unsafe {
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;
        let mut buf = [0u16; 1024];
        let mut len = buf.len() as u32;
        let ok = QueryFullProcessImageNameW(
            process,
            PROCESS_NAME_WIN32,
            PWSTR(buf.as_mut_ptr()),
            &mut len,
        );
        let _ = CloseHandle(process);
        ok.ok()?;
        Some(String::from_utf16_lossy(&buf[..len as usize]))
    }
}

/// False when another copy of the program already holds `name`.
pub fn claim_single_instance(name: &str) -> bool {
    use windows::Win32::Foundation::{GetLastError, ERROR_ALREADY_EXISTS};
    use windows::Win32::System::Threading::CreateMutexW;
    let name = crate::wide::Wide::new(name);
    match unsafe { CreateMutexW(None, true, name.pcwstr()) } {
        // The handle stays open for the life of the process on purpose.
        Ok(_) => (unsafe { GetLastError() }) != ERROR_ALREADY_EXISTS,
        Err(_) => true,
    }
}

/// Opens a folder or file the way Explorer would.
pub fn open_path(path: &str) {
    use windows::Win32::UI::Shell::ShellExecuteW;
    use windows::Win32::UI::WindowsAndMessaging::SW_SHOWNORMAL;
    let op = crate::wide::Wide::new("open");
    let file = crate::wide::Wide::new(path);
    unsafe {
        ShellExecuteW(None, op.pcwstr(), file.pcwstr(), None, None, SW_SHOWNORMAL);
    }
}

/// A blocking message box, for the moments before the tray icon exists.
pub fn message_box(title: &str, text: &str) {
    use windows::Win32::UI::WindowsAndMessaging::{MessageBoxW, MB_ICONINFORMATION, MB_OK};
    let title = crate::wide::Wide::new(title);
    let text = crate::wide::Wide::new(text);
    unsafe {
        MessageBoxW(
            None,
            text.pcwstr(),
            title.pcwstr(),
            MB_OK | MB_ICONINFORMATION,
        );
    }
}
