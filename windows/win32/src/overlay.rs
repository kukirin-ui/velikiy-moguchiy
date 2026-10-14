//! The pill at the bottom of the screen: recording level, recognized text,
//! errors. It never takes the focus and lets clicks through, so the text still
//! goes to the window the user is typing in.

use crate::wide::Wide;
use std::cell::RefCell;
use windows::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, POINT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::{
    BeginPaint, BitBlt, CreateCompatibleBitmap, CreateCompatibleDC, CreateFontW,
    CreateRoundRectRgn, CreateSolidBrush, DeleteDC, DeleteObject, DrawTextW, Ellipse, EndPaint,
    FillRect, GetMonitorInfoW, GetStockObject, InvalidateRect, MonitorFromPoint, SelectObject,
    SetBkMode, SetTextColor, SetWindowRgn, CLEARTYPE_QUALITY, CLIP_DEFAULT_PRECIS, DEFAULT_CHARSET,
    DT_CALCRECT, DT_END_ELLIPSIS, DT_LEFT, DT_NOPREFIX, DT_SINGLELINE, DT_VCENTER, DT_WORDBREAK,
    FF_DONTCARE, FW_NORMAL, FW_SEMIBOLD, HDC, HFONT, MONITORINFO, MONITOR_DEFAULTTONEAREST,
    NULL_PEN, OUT_DEFAULT_PRECIS, PAINTSTRUCT, SRCCOPY, TRANSPARENT,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::HiDpi::GetDpiForWindow;
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, GetCursorPos, GetForegroundWindow, GetWindowRect,
    RegisterClassExW, SetLayeredWindowAttributes, SetWindowPos, ShowWindow, HWND_TOPMOST,
    LWA_ALPHA, SWP_NOACTIVATE, SW_HIDE, SW_SHOWNOACTIVATE, WM_NCHITTEST, WM_PAINT, WNDCLASSEXW,
    WS_EX_LAYERED, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW, WS_EX_TOPMOST, WS_EX_TRANSPARENT, WS_POPUP,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Listening,
    Busy,
    Result,
    Notice,
    Error,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Content {
    pub mode: Mode,
    pub text: String,
    /// Small grey text after the main text ("Esc — отменить").
    pub hint: String,
    pub levels: [f32; 16],
}

thread_local! {
    static CONTENT: RefCell<Option<Content>> = const { RefCell::new(None) };
}

const BASE_WIDTH: i32 = 440;
const MAX_WIDTH: i32 = 640;
const LINE_HEIGHT: i32 = 20;
const PAD: i32 = 14;
const DOT: i32 = 10;
const BARS_WIDTH: i32 = 16 * 4;
const BOTTOM_MARGIN: i32 = 28;
const MAX_TEXT_CHARS: usize = 400;

fn rgb(r: u8, g: u8, b: u8) -> COLORREF {
    COLORREF(u32::from(r) | (u32::from(g) << 8) | (u32::from(b) << 16))
}

fn accent(mode: Mode) -> COLORREF {
    match mode {
        Mode::Listening => rgb(0xE5, 0x48, 0x4D),
        Mode::Busy => rgb(0xF5, 0xA5, 0x24),
        Mode::Result => rgb(0x3D, 0xB8, 0x6B),
        Mode::Notice => rgb(0x4C, 0x9A, 0xFF),
        Mode::Error => rgb(0xE5, 0x48, 0x4D),
    }
}

pub struct Overlay {
    hwnd: HWND,
}

impl Overlay {
    pub fn create() -> windows::core::Result<Overlay> {
        let class = Wide::new("VelikiyMoguchiyOverlay");
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
            let hwnd = CreateWindowExW(
                WS_EX_TOPMOST
                    | WS_EX_TOOLWINDOW
                    | WS_EX_NOACTIVATE
                    | WS_EX_LAYERED
                    | WS_EX_TRANSPARENT,
                class.pcwstr(),
                Wide::new("").pcwstr(),
                WS_POPUP,
                0,
                0,
                BASE_WIDTH,
                LINE_HEIGHT + 2 * PAD,
                None,
                None,
                Some(instance.into()),
                None,
            )?;
            SetLayeredWindowAttributes(hwnd, COLORREF(0), 238, LWA_ALPHA)?;
            Ok(Overlay { hwnd })
        }
    }

    pub fn show(&self, mut content: Content) {
        if content.text.chars().count() > MAX_TEXT_CHARS {
            // The end of a long dictation is what the user just said.
            let skip = content.text.chars().count() - MAX_TEXT_CHARS;
            content.text = format!("…{}", content.text.chars().skip(skip).collect::<String>());
        }
        CONTENT.with(|c| *c.borrow_mut() = Some(content));
        self.layout();
        unsafe {
            let _ = ShowWindow(self.hwnd, SW_SHOWNOACTIVATE);
            let _ = InvalidateRect(Some(self.hwnd), None, false);
        }
    }

    pub fn set_levels(&self, levels: [f32; 16]) {
        let changed = CONTENT.with(|c| match c.borrow_mut().as_mut() {
            Some(content) if content.mode == Mode::Listening && content.levels != levels => {
                content.levels = levels;
                true
            }
            _ => false,
        });
        if changed {
            unsafe {
                let _ = InvalidateRect(Some(self.hwnd), None, false);
            }
        }
    }

    pub fn hide(&self) {
        CONTENT.with(|c| *c.borrow_mut() = None);
        unsafe {
            let _ = ShowWindow(self.hwnd, SW_HIDE);
        }
    }

    fn scale(&self, v: i32) -> i32 {
        let dpi = unsafe { GetDpiForWindow(self.hwnd) };
        let dpi = if dpi == 0 { 96 } else { dpi as i32 };
        v * dpi / 96
    }

    /// Sizes the pill to its text and puts it above the taskbar of the
    /// monitor the user is working on.
    fn layout(&self) {
        let Some(content) = CONTENT.with(|c| c.borrow().clone()) else {
            return;
        };
        let work = work_area();
        let pad = self.scale(PAD);
        let lead = self.scale(DOT)
            + pad
            + if content.mode == Mode::Listening {
                self.scale(BARS_WIDTH) + pad
            } else {
                0
            };
        let max_width = self.scale(MAX_WIDTH).min(work.right - work.left - 2 * pad);
        let text = display_text(&content);
        let text_height = unsafe {
            let hdc = windows::Win32::Graphics::Gdi::GetDC(Some(self.hwnd));
            let font = self.font(false);
            let old = SelectObject(hdc, font.into());
            let mut rc = RECT {
                left: 0,
                top: 0,
                right: max_width - lead - 2 * pad,
                bottom: 0,
            };
            let mut buf: Vec<u16> = text.encode_utf16().collect();
            DrawTextW(
                hdc,
                &mut buf,
                &mut rc,
                DT_CALCRECT | DT_WORDBREAK | DT_NOPREFIX | DT_LEFT,
            );
            SelectObject(hdc, old);
            let _ = DeleteObject(font.into());
            windows::Win32::Graphics::Gdi::ReleaseDC(Some(self.hwnd), hdc);
            (rc.bottom - rc.top).clamp(self.scale(LINE_HEIGHT), self.scale(LINE_HEIGHT) * 3)
        };
        let width = self.scale(BASE_WIDTH).min(max_width).max(lead + 2 * pad);
        let width = if text_height > self.scale(LINE_HEIGHT) {
            max_width
        } else {
            width
        };
        let height = text_height + 2 * pad;
        let x = work.left + (work.right - work.left - width) / 2;
        let y = work.bottom - height - self.scale(BOTTOM_MARGIN);
        unsafe {
            let radius = if text_height > self.scale(LINE_HEIGHT) {
                self.scale(18)
            } else {
                height
            };
            let region = CreateRoundRectRgn(0, 0, width + 1, height + 1, radius, radius);
            SetWindowRgn(self.hwnd, Some(region), true);
            let _ = SetWindowPos(
                self.hwnd,
                Some(HWND_TOPMOST),
                x,
                y,
                width,
                height,
                SWP_NOACTIVATE,
            );
        }
    }

    fn font(&self, bold: bool) -> HFONT {
        unsafe {
            CreateFontW(
                -self.scale(15),
                0,
                0,
                0,
                if bold {
                    FW_SEMIBOLD.0 as i32
                } else {
                    FW_NORMAL.0 as i32
                },
                0,
                0,
                0,
                DEFAULT_CHARSET,
                OUT_DEFAULT_PRECIS,
                CLIP_DEFAULT_PRECIS,
                CLEARTYPE_QUALITY,
                FF_DONTCARE.0 as u32,
                Wide::new("Segoe UI").pcwstr(),
            )
        }
    }

    fn paint(&self, hdc: HDC, width: i32, height: i32) {
        let Some(content) = CONTENT.with(|c| c.borrow().clone()) else {
            return;
        };
        let pad = self.scale(PAD);
        unsafe {
            let bg = CreateSolidBrush(rgb(0x1F, 0x1F, 0x24));
            FillRect(
                hdc,
                &RECT {
                    left: 0,
                    top: 0,
                    right: width,
                    bottom: height,
                },
                bg,
            );
            let _ = DeleteObject(bg.into());

            let dot = self.scale(DOT);
            let mid = height / 2;
            let brush = CreateSolidBrush(accent(content.mode));
            let old_brush = SelectObject(hdc, brush.into());
            let old_pen = SelectObject(hdc, GetStockObject(NULL_PEN));
            let _ = Ellipse(hdc, pad, mid - dot / 2, pad + dot, mid + dot / 2);
            SelectObject(hdc, old_pen);
            SelectObject(hdc, old_brush);

            let mut left = pad + dot + pad;
            if content.mode == Mode::Listening {
                let bar = self.scale(3);
                let gap = self.scale(1);
                let max_h = self.scale(LINE_HEIGHT);
                for (i, level) in content.levels.iter().enumerate() {
                    let h = ((level.clamp(0.0, 1.0) * max_h as f32) as i32).max(self.scale(2));
                    let x = left + i as i32 * (bar + gap);
                    let rc = RECT {
                        left: x,
                        top: mid - h / 2,
                        right: x + bar,
                        bottom: mid + h / 2,
                    };
                    FillRect(hdc, &rc, brush);
                }
                left += self.scale(BARS_WIDTH) + pad;
            }
            let _ = DeleteObject(brush.into());

            let font = self.font(content.mode == Mode::Error);
            let old_font = SelectObject(hdc, font.into());
            SetBkMode(hdc, TRANSPARENT);
            let color = match content.mode {
                Mode::Error => rgb(0xFF, 0x9B, 0x9B),
                _ => rgb(0xF2, 0xF2, 0xF2),
            };
            SetTextColor(hdc, color);
            let mut rc = RECT {
                left,
                top: pad,
                right: width - pad,
                bottom: height - pad,
            };
            let text = display_text(&content);
            let mut buf: Vec<u16> = text.encode_utf16().collect();
            let single = height - 2 * pad <= self.scale(LINE_HEIGHT);
            let format = if single {
                DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS | DT_NOPREFIX | DT_LEFT
            } else {
                DT_WORDBREAK | DT_END_ELLIPSIS | DT_NOPREFIX | DT_LEFT
            };
            DrawTextW(hdc, &mut buf, &mut rc, format);
            SelectObject(hdc, old_font);
            let _ = DeleteObject(font.into());
        }
    }
}

fn display_text(content: &Content) -> String {
    let main = if content.text.is_empty() {
        match content.mode {
            Mode::Listening => "Говорите…",
            Mode::Busy => "Распознаю…",
            _ => "",
        }
        .to_string()
    } else {
        content.text.clone()
    };
    if content.hint.is_empty() {
        main
    } else {
        format!("{main}   {}", content.hint)
    }
}

/// The work area (screen minus taskbar) of the monitor with the focused
/// window, or with the cursor when nothing has focus.
fn work_area() -> RECT {
    unsafe {
        let mut pt = POINT::default();
        let fg = GetForegroundWindow();
        let mut rc = RECT::default();
        if !fg.0.is_null() && GetWindowRect(fg, &mut rc).is_ok() {
            pt = POINT {
                x: (rc.left + rc.right) / 2,
                y: (rc.top + rc.bottom) / 2,
            };
        } else {
            let _ = GetCursorPos(&mut pt);
        }
        let monitor = MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST);
        let mut info = MONITORINFO {
            cbSize: std::mem::size_of::<MONITORINFO>() as u32,
            ..Default::default()
        };
        if GetMonitorInfoW(monitor, &mut info).as_bool() {
            info.rcWork
        } else {
            RECT {
                left: 0,
                top: 0,
                right: 1280,
                bottom: 720,
            }
        }
    }
}

const HTTRANSPARENT: isize = -1;

unsafe extern "system" fn wnd_proc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    match msg {
        WM_PAINT => {
            let mut ps = PAINTSTRUCT::default();
            unsafe {
                let hdc = BeginPaint(hwnd, &mut ps);
                let mut rc = RECT::default();
                let _ = windows::Win32::UI::WindowsAndMessaging::GetClientRect(hwnd, &mut rc);
                let (w, h) = (rc.right - rc.left, rc.bottom - rc.top);
                let mem = CreateCompatibleDC(Some(hdc));
                let bitmap = CreateCompatibleBitmap(hdc, w, h);
                let old = SelectObject(mem, bitmap.into());
                Overlay { hwnd }.paint(mem, w, h);
                let _ = BitBlt(hdc, 0, 0, w, h, Some(mem), 0, 0, SRCCOPY);
                SelectObject(mem, old);
                let _ = DeleteObject(bitmap.into());
                let _ = DeleteDC(mem);
                let _ = EndPaint(hwnd, &ps);
            }
            LRESULT(0)
        }
        WM_NCHITTEST => LRESULT(HTTRANSPARENT),
        _ => unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) },
    }
}
