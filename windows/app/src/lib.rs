//! «Великий & Могучий» for Windows, the parts that do not touch Win32:
//! hotkey gestures, the dictation session, audio conversion, settings.
//! They build and are tested on any OS; `src/win_app.rs` wires them to the
//! system on Windows.

pub mod app_id;
pub mod audio;
pub mod controller;
pub mod core_bridge;
pub mod hotkey;
pub mod keys;
pub mod logfile;
pub mod settings;
