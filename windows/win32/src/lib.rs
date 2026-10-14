//! The Windows side of «Великий & Могучий»: everything that talks to Win32.
//! The dictation logic itself lives in the app crate and does not know about
//! any of this.

#[cfg(windows)]
pub mod clipboard;
#[cfg(windows)]
pub mod form;
#[cfg(windows)]
pub mod hook;
#[cfg(windows)]
pub mod input;
#[cfg(windows)]
pub mod mic;
#[cfg(windows)]
pub mod overlay;
#[cfg(windows)]
pub mod secret;
#[cfg(windows)]
pub mod shell;
#[cfg(windows)]
pub mod tray;
#[cfg(windows)]
mod wide;
#[cfg(windows)]
pub mod window;
