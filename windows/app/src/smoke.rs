//! Test hooks for the smoke run in CI (`.github/workflows/smoke-windows.yml`),
//! compiled only with the `smoke` feature, never into a release build.
//!
//! - the microphone is replaced by a generated tone, since the runner has none;
//! - the dictation key may be pressed with `SendInput`;
//! - with `VM_SMOKE_REPORT=<path>` the program writes what it set up at start.

use std::sync::mpsc;
use std::thread::JoinHandle;
use std::time::Duration;
use velikiy_moguchiy_win32::mic::{ErrorSink, SampleSink};

const RATE: u32 = 16_000;
const CHUNK_MS: u32 = 20;

/// Stands in for [`velikiy_moguchiy_win32::mic::Mic`] with the same calls.
pub struct FakeMic {
    stop: mpsc::Sender<()>,
    thread: Option<JoinHandle<()>>,
}

impl FakeMic {
    pub fn start(mut on_samples: SampleSink, _on_error: ErrorSink) -> Result<FakeMic, String> {
        let (stop_tx, stop_rx) = mpsc::channel::<()>();
        let thread = std::thread::Builder::new()
            .name("fake-mic".into())
            .spawn(move || {
                let chunk = (RATE * CHUNK_MS / 1000) as usize;
                let mut buf = vec![0.0f32; chunk];
                let mut n: u64 = 0;
                loop {
                    for s in buf.iter_mut() {
                        let t = n as f32 / RATE as f32;
                        *s = 0.3 * (2.0 * std::f32::consts::PI * 440.0 * t).sin();
                        n += 1;
                    }
                    on_samples(&buf, RATE, 1);
                    let waited = stop_rx.recv_timeout(Duration::from_millis(CHUNK_MS.into()));
                    if !matches!(waited, Err(mpsc::RecvTimeoutError::Timeout)) {
                        break;
                    }
                }
            })
            .map_err(|e| e.to_string())?;
        log::info!("smoke: fake microphone, {RATE} Hz tone");
        Ok(FakeMic {
            stop: stop_tx,
            thread: Some(thread),
        })
    }

    pub fn stop(mut self) {
        self.shutdown();
    }

    fn shutdown(&mut self) {
        let _ = self.stop.send(());
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

impl Drop for FakeMic {
    fn drop(&mut self) {
        self.shutdown();
    }
}

/// Writes `report` to `$VM_SMOKE_REPORT`; renamed into place so that the
/// test never reads half a file.
pub fn write_report(report: &serde_json::Value) {
    let Some(path) = std::env::var_os("VM_SMOKE_REPORT") else {
        return;
    };
    let path = std::path::PathBuf::from(path);
    let tmp = path.with_extension("tmp");
    let written = std::fs::write(&tmp, report.to_string());
    match written.and_then(|()| std::fs::rename(&tmp, &path)) {
        Ok(()) => log::info!("smoke: report written to {}", path.display()),
        Err(e) => log::error!("smoke: report {}: {e}", path.display()),
    }
}
