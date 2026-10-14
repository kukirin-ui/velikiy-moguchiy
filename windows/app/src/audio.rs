//! Microphone samples in whatever format the device gives, turned into what
//! the core expects: 16 kHz mono PCM16, pushed in 100 ms frames.

pub const TARGET_RATE: u32 = 16_000;
pub const FRAME_SAMPLES: usize = 1_600;

/// Streaming downmix + resampler to 16 kHz.
///
/// Downsampling averages over one output period before interpolating: a
/// boxcar that puts its nulls at 16 kHz and its multiples, which is enough
/// anti-aliasing for speech recognition and costs nothing.
pub struct Resampler {
    channels: usize,
    step: f64,
    window: Vec<f32>,
    window_pos: usize,
    window_sum: f32,
    prev: f32,
    /// Position of the next output sample, in input samples after `prev`.
    next: f64,
}

impl Resampler {
    pub fn new(input_rate: u32, channels: u16) -> Self {
        let step = f64::from(input_rate.max(1)) / f64::from(TARGET_RATE);
        let taps = (step.floor() as usize).max(1);
        Self {
            channels: usize::from(channels.max(1)),
            step,
            window: vec![0.0; taps],
            window_pos: 0,
            window_sum: 0.0,
            prev: 0.0,
            next: 1.0,
        }
    }

    /// Converts interleaved samples in -1.0..=1.0; appends PCM16 to `out`.
    pub fn process(&mut self, interleaved: &[f32], out: &mut Vec<i16>) {
        for frame in interleaved.chunks_exact(self.channels) {
            let mono = frame.iter().sum::<f32>() / self.channels as f32;
            self.window_sum += mono - self.window[self.window_pos];
            self.window[self.window_pos] = mono;
            self.window_pos = (self.window_pos + 1) % self.window.len();
            let y = self.window_sum / self.window.len() as f32;
            while self.next <= 1.0 {
                let v = self.prev + (y - self.prev) * self.next as f32;
                out.push(to_pcm16(v));
                self.next += self.step;
            }
            self.next -= 1.0;
            self.prev = y;
        }
    }
}

pub fn to_pcm16(sample: f32) -> i16 {
    (sample.clamp(-1.0, 1.0) * 32767.0).round() as i16
}

/// Collects samples into fixed-size frames.
pub struct Framer {
    buf: Vec<i16>,
    frame: usize,
}

impl Framer {
    pub fn new(frame: usize) -> Self {
        Self {
            buf: Vec::with_capacity(frame * 2),
            frame: frame.max(1),
        }
    }

    pub fn push(&mut self, samples: &[i16], mut emit: impl FnMut(&[i16])) {
        self.buf.extend_from_slice(samples);
        let full = self.buf.len() / self.frame * self.frame;
        for chunk in self.buf[..full].chunks_exact(self.frame) {
            emit(chunk);
        }
        self.buf.drain(..full);
    }

    /// Emits what is left (a short last frame) and empties the buffer.
    pub fn flush(&mut self, mut emit: impl FnMut(&[i16])) {
        if !self.buf.is_empty() {
            emit(&self.buf);
            self.buf.clear();
        }
    }
}

/// Little-endian bytes, as `sp_core_push_audio` takes them.
pub fn pcm_bytes(samples: &[i16]) -> Vec<u8> {
    samples.iter().flat_map(|s| s.to_le_bytes()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sine(rate: u32, freq: f32, seconds: f32, channels: u16) -> Vec<f32> {
        let n = (rate as f32 * seconds) as usize;
        (0..n)
            .flat_map(|i| {
                let v = (2.0 * std::f32::consts::PI * freq * i as f32 / rate as f32).sin() * 0.5;
                std::iter::repeat_n(v, channels as usize)
            })
            .collect()
    }

    fn rms(samples: &[i16]) -> f32 {
        let sum: f64 = samples.iter().map(|&s| f64::from(s) * f64::from(s)).sum();
        (sum / samples.len() as f64).sqrt() as f32 / 32767.0
    }

    #[test]
    fn output_length_follows_the_rate_ratio() {
        for (rate, channels) in [(48_000, 2), (44_100, 1), (16_000, 1), (8_000, 1)] {
            let mut r = Resampler::new(rate, channels);
            let mut out = Vec::new();
            r.process(&sine(rate, 440.0, 1.0, channels), &mut out);
            let diff = out.len() as i64 - i64::from(TARGET_RATE);
            assert!(
                diff.abs() <= 2,
                "{rate} Hz x{channels}: {} samples",
                out.len()
            );
        }
    }

    #[test]
    fn chunking_does_not_change_the_result() {
        let input = sine(48_000, 300.0, 0.5, 2);
        let mut whole = Vec::new();
        Resampler::new(48_000, 2).process(&input, &mut whole);
        let mut pieces = Vec::new();
        let mut r = Resampler::new(48_000, 2);
        for chunk in input.chunks(2 * 37) {
            r.process(chunk, &mut pieces);
        }
        assert_eq!(whole, pieces);
    }

    #[test]
    fn speech_band_passes_and_ultrasound_is_damped() {
        let mut voice = Vec::new();
        Resampler::new(48_000, 1).process(&sine(48_000, 500.0, 1.0, 1), &mut voice);
        assert!(
            rms(&voice[100..]) > 0.33,
            "500 Hz kept: {}",
            rms(&voice[100..])
        );
        // Without the averaging, 17 kHz would fold down to 1 kHz at full strength.
        let mut high = Vec::new();
        Resampler::new(48_000, 1).process(&sine(48_000, 17_000.0, 1.0, 1), &mut high);
        assert!(
            rms(&high[100..]) < 0.05,
            "17 kHz damped: {}",
            rms(&high[100..])
        );
    }

    #[test]
    fn stereo_is_averaged_to_mono() {
        let mut r = Resampler::new(16_000, 2);
        let mut out = Vec::new();
        r.process(&[1.0, 0.0, 1.0, 0.0, 0.5, 0.5], &mut out);
        assert_eq!(out.len(), 3);
        assert!(out.iter().skip(1).all(|&s| s == to_pcm16(0.5)), "{out:?}");
    }

    #[test]
    fn framer_emits_whole_frames_then_the_rest_on_flush() {
        let mut f = Framer::new(4);
        let mut frames: Vec<Vec<i16>> = Vec::new();
        f.push(&[1, 2, 3], |c| frames.push(c.to_vec()));
        assert!(frames.is_empty());
        f.push(&[4, 5, 6, 7, 8, 9], |c| frames.push(c.to_vec()));
        assert_eq!(frames, vec![vec![1, 2, 3, 4], vec![5, 6, 7, 8]]);
        f.flush(|c| frames.push(c.to_vec()));
        assert_eq!(frames.last().unwrap(), &vec![9]);
        f.flush(|c| frames.push(c.to_vec()));
        assert_eq!(frames.len(), 3);
    }

    #[test]
    fn pcm_is_little_endian_and_clamped() {
        assert_eq!(pcm_bytes(&[0x0102, -1]), vec![0x02, 0x01, 0xFF, 0xFF]);
        assert_eq!(to_pcm16(2.0), 32767);
        assert_eq!(to_pcm16(-2.0), -32767);
    }
}
