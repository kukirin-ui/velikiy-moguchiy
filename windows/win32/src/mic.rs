//! The default microphone, captured on a thread of its own: building a WASAPI
//! stream makes COM calls that can pump the UI thread's messages and re-enter
//! the keyboard hook.

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{Data, SampleFormat, SizedSample};
use std::sync::mpsc;
use std::thread::JoinHandle;

/// Interleaved samples in -1.0..=1.0, with the device's rate and channel count.
pub type SampleSink = Box<dyn FnMut(&[f32], u32, u16) + Send>;
/// The stream broke after it started (device unplugged).
pub type ErrorSink = Box<dyn Fn(String) + Send>;

pub struct Mic {
    stop: mpsc::Sender<()>,
    thread: Option<JoinHandle<()>>,
}

impl Mic {
    /// Starts capturing; returns once the stream is running or has failed.
    pub fn start(on_samples: SampleSink, on_error: ErrorSink) -> Result<Mic, String> {
        let (ready_tx, ready_rx) = mpsc::channel::<Result<(), String>>();
        let (stop_tx, stop_rx) = mpsc::channel::<()>();
        let thread = std::thread::Builder::new()
            .name("mic".into())
            .spawn(move || {
                let stream = match open(on_samples, on_error) {
                    Ok(stream) => stream,
                    Err(e) => {
                        let _ = ready_tx.send(Err(e));
                        return;
                    }
                };
                let _ = ready_tx.send(Ok(()));
                let _ = stop_rx.recv();
                drop(stream);
            })
            .map_err(|e| e.to_string())?;
        match ready_rx.recv() {
            Ok(Ok(())) => Ok(Mic {
                stop: stop_tx,
                thread: Some(thread),
            }),
            Ok(Err(e)) => {
                let _ = thread.join();
                Err(e)
            }
            Err(_) => Err("поток микрофона завершился".into()),
        }
    }

    /// Stops capturing. No sample callback runs after this returns.
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

impl Drop for Mic {
    fn drop(&mut self) {
        self.shutdown();
    }
}

fn open(mut on_samples: SampleSink, on_error: ErrorSink) -> Result<cpal::Stream, String> {
    let host = cpal::default_host();
    let device = host
        .default_input_device()
        .ok_or_else(|| "в системе нет микрофона".to_string())?;
    let supported = device.default_input_config().map_err(|e| e.to_string())?;
    let format = supported.sample_format();
    let config = supported.config();
    let rate = config.sample_rate;
    let channels = config.channels;
    log::info!("microphone: {rate} Hz, {channels} ch, {format:?}");
    let mut scratch: Vec<f32> = Vec::new();
    let stream = device
        .build_input_stream_raw(
            config,
            format,
            move |data: &Data, _| {
                scratch.clear();
                if convert(data, format, &mut scratch) {
                    on_samples(&scratch, rate, channels);
                }
            },
            move |e| on_error(e.to_string()),
            None,
        )
        .map_err(|e| e.to_string())?;
    stream.play().map_err(|e| e.to_string())?;
    Ok(stream)
}

fn convert(data: &Data, format: SampleFormat, out: &mut Vec<f32>) -> bool {
    fn extend<T: SizedSample>(data: &Data, out: &mut Vec<f32>) -> bool
    where
        f32: cpal::FromSample<T>,
    {
        match data.as_slice::<T>() {
            Some(s) => {
                out.extend(s.iter().map(|&v| v.to_sample::<f32>()));
                true
            }
            None => false,
        }
    }
    match format {
        SampleFormat::F32 => extend::<f32>(data, out),
        SampleFormat::I16 => extend::<i16>(data, out),
        SampleFormat::I32 => extend::<i32>(data, out),
        SampleFormat::U16 => extend::<u16>(data, out),
        SampleFormat::U8 => extend::<u8>(data, out),
        SampleFormat::F64 => extend::<f64>(data, out),
        _ => false,
    }
}
