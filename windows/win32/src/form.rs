//! A plain window of labelled fields with Save / Cancel, built from standard
//! controls. The app describes the fields; the form reports what the user did
//! through a sink that must only queue the event (it runs inside the window
//! procedure).

use crate::wide::Wide;
use std::cell::Cell;
use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::{
    CreateFontW, DeleteObject, CLEARTYPE_QUALITY, CLIP_DEFAULT_PRECIS, COLOR_BTNFACE,
    DEFAULT_CHARSET, FF_DONTCARE, FW_NORMAL, HBRUSH, HFONT, OUT_DEFAULT_PRECIS,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::HiDpi::{AdjustWindowRectExForDpi, GetDpiForSystem};
use windows::Win32::UI::Input::KeyboardAndMouse::SetFocus;
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DestroyWindow, GetSystemMetrics, GetWindowLongPtrW,
    GetWindowTextLengthW, GetWindowTextW, IsDialogMessageW, IsWindow, LoadCursorW,
    RegisterClassExW, SendMessageW, SetForegroundWindow, SetWindowLongPtrW, SetWindowTextW,
    ShowWindow, BS_DEFPUSHBUTTON, BS_PUSHBUTTON, CBS_DROPDOWNLIST, CB_ADDSTRING, CB_GETCURSEL,
    CB_SETCURSEL, CREATESTRUCTW, ES_AUTOHSCROLL, ES_PASSWORD, GWLP_USERDATA, HMENU, IDC_ARROW, MSG,
    SM_CXSCREEN, SM_CYSCREEN, SW_SHOW, WINDOW_EX_STYLE, WINDOW_STYLE, WM_CLOSE, WM_COMMAND,
    WM_CREATE, WM_DESTROY, WM_SETFONT, WNDCLASSEXW, WS_BORDER, WS_CAPTION, WS_CHILD,
    WS_EX_CLIENTEDGE, WS_EX_DLGMODALFRAME, WS_MINIMIZEBOX, WS_SYSMENU, WS_TABSTOP, WS_VISIBLE,
    WS_VSCROLL,
};

pub enum Field {
    Choice {
        label: String,
        options: Vec<String>,
        selected: usize,
    },
    Text {
        label: String,
        value: String,
        /// Shown as dots (API keys).
        secret: bool,
    },
    /// Read-only text the app can change later with [`Form::set_note`].
    Note(String),
    Button(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Value {
    Choice(usize),
    Text(String),
    None,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FormEvent {
    /// One value per field, in field order.
    Save(Vec<Value>),
    /// The button field with this index was pressed.
    Button(usize),
    Closed,
}

pub type FormSink = Box<dyn Fn(FormEvent)>;

const WIDTH: i32 = 460;
const MARGIN: i32 = 16;
const GAP: i32 = 8;
const LABEL_H: i32 = 18;
const CONTROL_H: i32 = 26;
const NOTE_H: i32 = 38;
const ID_SAVE: usize = 1;
const ID_CANCEL: usize = 2;
const ID_FIELD_BASE: usize = 100;

enum Kind {
    Choice,
    Text,
    Note,
    Button,
}

struct State {
    controls: Vec<(Kind, HWND)>,
    sink: FormSink,
    font: HFONT,
}

thread_local! {
    /// The open form, for keyboard navigation in the message loop.
    static ACTIVE: Cell<isize> = const { Cell::new(0) };
}

/// Tab / Enter / Esc handling for the open form; call for every message the
/// loop gets and skip the message when this returns true.
pub fn handle_dialog_message(msg: &MSG) -> bool {
    let hwnd = ACTIVE.with(|a| a.get());
    if hwnd == 0 {
        return false;
    }
    unsafe { IsDialogMessageW(HWND(hwnd as *mut _), msg).as_bool() }
}

pub struct Form {
    hwnd: HWND,
}

impl Form {
    pub fn open(title: &str, fields: Vec<Field>, sink: FormSink) -> windows::core::Result<Form> {
        let class = Wide::new("VelikiyMoguchiyForm");
        unsafe {
            let instance = GetModuleHandleW(None)?;
            let wc = WNDCLASSEXW {
                cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
                lpfnWndProc: Some(wnd_proc),
                hInstance: instance.into(),
                hCursor: LoadCursorW(None, IDC_ARROW).unwrap_or_default(),
                hbrBackground: HBRUSH((COLOR_BTNFACE.0 + 1) as usize as *mut _),
                lpszClassName: class.pcwstr(),
                ..Default::default()
            };
            RegisterClassExW(&wc);

            let dpi = GetDpiForSystem().max(96) as i32;
            let s = |v: i32| v * dpi / 96;
            let content_h = fields
                .iter()
                .map(|f| match f {
                    Field::Choice { .. } | Field::Text { .. } => LABEL_H + CONTROL_H + GAP,
                    Field::Note(_) => NOTE_H + GAP,
                    Field::Button(_) => CONTROL_H + GAP,
                })
                .sum::<i32>()
                + MARGIN * 2
                + CONTROL_H
                + GAP;
            let style = WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;
            let ex = WS_EX_DLGMODALFRAME;
            let mut rc = RECT {
                left: 0,
                top: 0,
                right: s(WIDTH),
                bottom: s(content_h),
            };
            let _ = AdjustWindowRectExForDpi(&mut rc, style, false, ex, dpi as u32);
            let (w, h) = (rc.right - rc.left, rc.bottom - rc.top);
            let x = (GetSystemMetrics(SM_CXSCREEN) - w) / 2;
            let y = (GetSystemMetrics(SM_CYSCREEN) - h) / 3;

            let state = Box::new(State {
                controls: Vec::new(),
                sink,
                font: CreateFontW(
                    -s(14),
                    0,
                    0,
                    0,
                    FW_NORMAL.0 as i32,
                    0,
                    0,
                    0,
                    DEFAULT_CHARSET,
                    OUT_DEFAULT_PRECIS,
                    CLIP_DEFAULT_PRECIS,
                    CLEARTYPE_QUALITY,
                    FF_DONTCARE.0 as u32,
                    Wide::new("Segoe UI").pcwstr(),
                ),
            });
            let hwnd = CreateWindowExW(
                ex,
                class.pcwstr(),
                Wide::new(title).pcwstr(),
                style,
                x,
                y,
                w,
                h,
                None,
                None,
                Some(instance.into()),
                Some(Box::into_raw(state) as *const _),
            )?;
            build(hwnd, &fields, s);
            let _ = ShowWindow(hwnd, SW_SHOW);
            let _ = SetForegroundWindow(hwnd);
            ACTIVE.with(|a| a.set(hwnd.0 as isize));
            Ok(Form { hwnd })
        }
    }

    pub fn is_open(&self) -> bool {
        unsafe { IsWindow(Some(self.hwnd)).as_bool() }
    }

    pub fn focus(&self) {
        unsafe {
            let _ = ShowWindow(self.hwnd, SW_SHOW);
            let _ = SetForegroundWindow(self.hwnd);
        }
    }

    /// Replaces the text of the note field with this index.
    pub fn set_note(&self, index: usize, text: &str) {
        if let Some(control) =
            with_state(self.hwnd, |st| st.controls.get(index).map(|c| c.1)).flatten()
        {
            unsafe {
                let _ = SetWindowTextW(control, Wide::new(text).pcwstr());
            }
        }
    }

    pub fn close(&self) {
        if self.is_open() {
            unsafe {
                let _ = DestroyWindow(self.hwnd);
            }
        }
    }
}

fn with_state<R>(hwnd: HWND, f: impl FnOnce(&State) -> R) -> Option<R> {
    let ptr = unsafe { GetWindowLongPtrW(hwnd, GWLP_USERDATA) } as *const State;
    if ptr.is_null() {
        return None;
    }
    Some(f(unsafe { &*ptr }))
}

#[allow(clippy::too_many_arguments)]
unsafe fn child(
    parent: HWND,
    class: &str,
    text: &str,
    style: WINDOW_STYLE,
    ex: WINDOW_EX_STYLE,
    rect: (i32, i32, i32, i32),
    id: usize,
    font: HFONT,
) -> HWND {
    let hwnd = unsafe {
        CreateWindowExW(
            ex,
            Wide::new(class).pcwstr(),
            Wide::new(text).pcwstr(),
            WS_CHILD | WS_VISIBLE | style,
            rect.0,
            rect.1,
            rect.2,
            rect.3,
            Some(parent),
            Some(HMENU(id as *mut _)),
            None,
            None,
        )
    }
    .unwrap_or_default();
    unsafe {
        SendMessageW(
            hwnd,
            WM_SETFONT,
            Some(WPARAM(font.0 as usize)),
            Some(LPARAM(1)),
        );
    }
    hwnd
}

unsafe fn build(hwnd: HWND, fields: &[Field], s: impl Fn(i32) -> i32) {
    let ptr = unsafe { GetWindowLongPtrW(hwnd, GWLP_USERDATA) } as *mut State;
    if ptr.is_null() {
        return;
    }
    let state = unsafe { &mut *ptr };
    let font = state.font;
    let none = WINDOW_EX_STYLE(0);
    let (x, w) = (s(MARGIN), s(WIDTH - 2 * MARGIN));
    let mut y = s(MARGIN);
    for (i, field) in fields.iter().enumerate() {
        let id = ID_FIELD_BASE + i;
        unsafe {
            match field {
                Field::Choice {
                    label,
                    options,
                    selected,
                } => {
                    child(
                        hwnd,
                        "STATIC",
                        label,
                        WINDOW_STYLE(0),
                        none,
                        (x, y, w, s(LABEL_H)),
                        0,
                        font,
                    );
                    y += s(LABEL_H);
                    let combo = child(
                        hwnd,
                        "COMBOBOX",
                        "",
                        WINDOW_STYLE(CBS_DROPDOWNLIST as u32) | WS_TABSTOP | WS_VSCROLL,
                        none,
                        (x, y, w, s(CONTROL_H * 8)),
                        id,
                        font,
                    );
                    for option in options {
                        let text = Wide::new(option);
                        SendMessageW(
                            combo,
                            CB_ADDSTRING,
                            None,
                            Some(LPARAM(text.pcwstr().0 as isize)),
                        );
                    }
                    SendMessageW(combo, CB_SETCURSEL, Some(WPARAM(*selected)), None);
                    state.controls.push((Kind::Choice, combo));
                    y += s(CONTROL_H + GAP);
                }
                Field::Text {
                    label,
                    value,
                    secret,
                } => {
                    child(
                        hwnd,
                        "STATIC",
                        label,
                        WINDOW_STYLE(0),
                        none,
                        (x, y, w, s(LABEL_H)),
                        0,
                        font,
                    );
                    y += s(LABEL_H);
                    let mut style = WINDOW_STYLE(ES_AUTOHSCROLL as u32) | WS_TABSTOP | WS_BORDER;
                    if *secret {
                        style |= WINDOW_STYLE(ES_PASSWORD as u32);
                    }
                    let edit = child(
                        hwnd,
                        "EDIT",
                        value,
                        style,
                        WS_EX_CLIENTEDGE,
                        (x, y, w, s(CONTROL_H - 2)),
                        id,
                        font,
                    );
                    state.controls.push((Kind::Text, edit));
                    y += s(CONTROL_H + GAP);
                }
                Field::Note(text) => {
                    let note = child(
                        hwnd,
                        "STATIC",
                        text,
                        WINDOW_STYLE(0),
                        none,
                        (x, y, w, s(NOTE_H)),
                        id,
                        font,
                    );
                    state.controls.push((Kind::Note, note));
                    y += s(NOTE_H + GAP);
                }
                Field::Button(title) => {
                    let button = child(
                        hwnd,
                        "BUTTON",
                        title,
                        WINDOW_STYLE(BS_PUSHBUTTON as u32) | WS_TABSTOP,
                        none,
                        (x, y, s(220), s(CONTROL_H)),
                        id,
                        font,
                    );
                    state.controls.push((Kind::Button, button));
                    y += s(CONTROL_H + GAP);
                }
            }
        }
    }
    y += s(GAP);
    let bw = s(110);
    unsafe {
        child(
            hwnd,
            "BUTTON",
            "Сохранить",
            WINDOW_STYLE(BS_DEFPUSHBUTTON as u32) | WS_TABSTOP,
            none,
            (x + w - 2 * bw - s(GAP), y, bw, s(CONTROL_H)),
            ID_SAVE,
            font,
        );
        child(
            hwnd,
            "BUTTON",
            "Отмена",
            WINDOW_STYLE(BS_PUSHBUTTON as u32) | WS_TABSTOP,
            none,
            (x + w - bw, y, bw, s(CONTROL_H)),
            ID_CANCEL,
            font,
        );
        if let Some((_, first)) = state
            .controls
            .iter()
            .find(|(k, _)| matches!(k, Kind::Choice | Kind::Text))
        {
            let _ = SetFocus(Some(*first));
        }
    }
}

fn values(state: &State) -> Vec<Value> {
    state
        .controls
        .iter()
        .map(|(kind, hwnd)| unsafe {
            match kind {
                Kind::Choice => {
                    let sel = SendMessageW(*hwnd, CB_GETCURSEL, None, None).0;
                    Value::Choice(sel.max(0) as usize)
                }
                Kind::Text => {
                    let len = GetWindowTextLengthW(*hwnd).max(0) as usize;
                    let mut buf = vec![0u16; len + 1];
                    let n = GetWindowTextW(*hwnd, &mut buf).max(0) as usize;
                    Value::Text(String::from_utf16_lossy(&buf[..n]))
                }
                Kind::Note | Kind::Button => Value::None,
            }
        })
        .collect()
}

unsafe extern "system" fn wnd_proc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    match msg {
        WM_CREATE => {
            let cs = unsafe { &*(lparam.0 as *const CREATESTRUCTW) };
            unsafe { SetWindowLongPtrW(hwnd, GWLP_USERDATA, cs.lpCreateParams as isize) };
            LRESULT(0)
        }
        WM_COMMAND => {
            let id = wparam.0 & 0xFFFF;
            let notification = (wparam.0 >> 16) & 0xFFFF;
            const BN_CLICKED: usize = 0;
            if notification == BN_CLICKED {
                match id {
                    ID_SAVE => {
                        with_state(hwnd, |st| (st.sink)(FormEvent::Save(values(st))));
                    }
                    ID_CANCEL => unsafe {
                        let _ = DestroyWindow(hwnd);
                    },
                    _ if id >= ID_FIELD_BASE => {
                        let index = id - ID_FIELD_BASE;
                        with_state(hwnd, |st| {
                            if matches!(st.controls.get(index), Some((Kind::Button, _))) {
                                (st.sink)(FormEvent::Button(index));
                            }
                        });
                    }
                    _ => {}
                }
            }
            LRESULT(0)
        }
        WM_CLOSE => {
            unsafe {
                let _ = DestroyWindow(hwnd);
            }
            LRESULT(0)
        }
        WM_DESTROY => {
            ACTIVE.with(|a| {
                if a.get() == hwnd.0 as isize {
                    a.set(0);
                }
            });
            let ptr = unsafe { SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0) } as *mut State;
            if !ptr.is_null() {
                let state = unsafe { Box::from_raw(ptr) };
                (state.sink)(FormEvent::Closed);
                unsafe {
                    let _ = DeleteObject(state.font.into());
                }
            }
            LRESULT(0)
        }
        _ => unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) },
    }
}
