#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

#[cfg(all(windows, feature = "smoke"))]
mod smoke;
#[cfg(windows)]
mod win_app;

fn main() {
    #[cfg(windows)]
    win_app::run();
    #[cfg(not(windows))]
    eprintln!("Эта программа — версия «Великого & Могучего» для Windows. Для Mac есть приложение из папки mac/.");
}
