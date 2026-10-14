//! Silence detector behind the optional auto-stop of hands-free recordings.
//!
//! Fed with the raw 16 kHz mono PCM the overlay level meter also gets. The
//! timer starts only once speech was heard, so a recording that nobody has
//! spoken into yet never ends by itself. The speech threshold follows an
//! estimate of the room's noise floor, so a steady hum is not mistaken for a
//! voice. The shape (levels against a threshold, a timer that starts after
//! speech) is the one OpenLess' `silence_auto_stop.rs` describes; this is an
//! independent implementation on RMS.

const SAMPLE_RATE: u64 = 16_000;
/// RMS (0..1) frames are measured in: 20 ms.
const FRAME_SAMPLES: usize = 320;
/// Quietest RMS ever taken for speech (about -38 dBFS).
const MIN_SPEECH_RMS: f32 = 0.012;
/// Speech has to be this many times louder than the noise floor.
const FLOOR_RATIO: f32 = 3.0;
const FLOOR_MIN: f32 = 0.0005;
const FLOOR_MAX: f32 = 0.01;
/// Voiced time that must add up before a recording counts as having speech.
const SPEECH_CONFIRM_MS: u64 = 200;
/// A voiced stretch this long restarts the silence timer (a click does not).
const VOICED_RESET_MS: u64 = 80;

fn ms_to_samples(ms: u64) -> u64 {
    ms * SAMPLE_RATE / 1000
}

#[derive(Debug, Clone)]
pub struct SilenceDetector {
    timeout_samples: u64,
    floor: Option<f32>,
    voiced_total: u64,
    voiced_run: u64,
    silent: u64,
    speech_seen: bool,
    fired: bool,
    carry: Vec<i16>,
}

impl SilenceDetector {
    pub fn new(timeout_seconds: f32) -> Self {
        Self {
            timeout_samples: (timeout_seconds.max(0.0) as f64 * SAMPLE_RATE as f64) as u64,
            floor: None,
            voiced_total: 0,
            voiced_run: 0,
            silent: 0,
            speech_seen: false,
            fired: false,
            carry: Vec::new(),
        }
    }

    pub fn speech_seen(&self) -> bool {
        self.speech_seen
    }

    /// Feed PCM16 samples; true once the recording has been silent for the
    /// timeout after speech (stays true afterwards).
    pub fn feed(&mut self, pcm: &[i16]) -> bool {
        if self.fired || self.timeout_samples == 0 {
            return self.fired;
        }
        self.carry.extend_from_slice(pcm);
        let whole = self.carry.len() / FRAME_SAMPLES * FRAME_SAMPLES;
        let frames: Vec<i16> = self.carry.drain(..whole).collect();
        for frame in frames.chunks(FRAME_SAMPLES) {
            self.frame(rms(frame));
            if self.fired {
                break;
            }
        }
        self.fired
    }

    fn frame(&mut self, level: f32) {
        let floor = *self
            .floor
            .get_or_insert(level.clamp(FLOOR_MIN, FLOOR_MAX));
        let threshold = MIN_SPEECH_RMS.max(floor * FLOOR_RATIO);
        let voiced = level > threshold;

        let floor = if level < floor {
            floor * 0.9 + level * 0.1
        } else if !voiced {
            floor + (level - floor) * 0.02
        } else {
            floor
        };
        self.floor = Some(floor.clamp(FLOOR_MIN, FLOOR_MAX));

        let samples = FRAME_SAMPLES as u64;
        if voiced {
            self.voiced_run += samples;
            self.voiced_total += samples;
            if self.voiced_total >= ms_to_samples(SPEECH_CONFIRM_MS) {
                self.speech_seen = true;
            }
            if self.voiced_run >= ms_to_samples(VOICED_RESET_MS) {
                self.silent = 0;
            }
        } else {
            self.voiced_run = 0;
            if self.speech_seen {
                self.silent += samples;
                if self.silent >= self.timeout_samples {
                    self.fired = true;
                }
            }
        }
    }
}

fn rms(frame: &[i16]) -> f32 {
    if frame.is_empty() {
        return 0.0;
    }
    let sum: f64 = frame
        .iter()
        .map(|&s| {
            let v = s as f64 / 32768.0;
            v * v
        })
        .sum();
    (sum / frame.len() as f64).sqrt() as f32
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `ms` of a square wave whose RMS is `level` (0..1).
    fn tone(level: f32, ms: u64) -> Vec<i16> {
        let amplitude = (level * 32767.0) as i16;
        (0..ms_to_samples(ms))
            .map(|i| if i % 2 == 0 { amplitude } else { -amplitude })
            .collect()
    }

    fn feed_ms(detector: &mut SilenceDetector, level: f32, ms: u64) -> bool {
        let mut fired = false;
        // Odd chunk sizes: the detector must not depend on buffer boundaries.
        for chunk in tone(level, ms).chunks(1000) {
            fired = detector.feed(chunk);
        }
        fired
    }

    #[test]
    fn never_fires_before_speech() {
        let mut d = SilenceDetector::new(2.0);
        assert!(!feed_ms(&mut d, 0.001, 10_000));
        assert!(!d.speech_seen());
    }

    #[test]
    fn fires_after_the_timeout_following_speech() {
        let mut d = SilenceDetector::new(2.0);
        assert!(!feed_ms(&mut d, 0.1, 1000));
        assert!(d.speech_seen());
        assert!(!feed_ms(&mut d, 0.001, 1900));
        assert!(feed_ms(&mut d, 0.001, 200));
        assert!(feed_ms(&mut d, 0.1, 100), "stays fired");
    }

    #[test]
    fn speech_restarts_the_timer() {
        let mut d = SilenceDetector::new(2.0);
        feed_ms(&mut d, 0.1, 500);
        assert!(!feed_ms(&mut d, 0.001, 1500));
        assert!(!feed_ms(&mut d, 0.1, 300));
        assert!(!feed_ms(&mut d, 0.001, 1500));
        assert!(feed_ms(&mut d, 0.001, 600));
    }

    #[test]
    fn a_click_is_not_speech_and_does_not_reset_the_timer() {
        let mut d = SilenceDetector::new(2.0);
        assert!(!feed_ms(&mut d, 0.3, 40));
        assert!(!d.speech_seen());
        assert!(!feed_ms(&mut d, 0.001, 5000));

        let mut d = SilenceDetector::new(2.0);
        feed_ms(&mut d, 0.1, 500);
        feed_ms(&mut d, 0.001, 1500);
        feed_ms(&mut d, 0.3, 40);
        assert!(feed_ms(&mut d, 0.001, 600));
    }

    #[test]
    fn steady_room_noise_counts_as_silence() {
        let mut d = SilenceDetector::new(3.0);
        // A hum louder than the minimum speech level, but constant from the start.
        feed_ms(&mut d, 0.02, 500);
        assert!(!d.speech_seen());
        feed_ms(&mut d, 0.1, 500);
        assert!(d.speech_seen());
        assert!(feed_ms(&mut d, 0.02, 3200));
    }

    #[test]
    fn zero_timeout_never_fires() {
        let mut d = SilenceDetector::new(0.0);
        feed_ms(&mut d, 0.1, 500);
        assert!(!feed_ms(&mut d, 0.0, 60_000));
    }

    #[test]
    fn rms_of_silence_and_full_scale() {
        assert_eq!(rms(&[0; 320]), 0.0);
        assert!((rms(&[i16::MAX; 320]) - 1.0).abs() < 0.01);
        assert_eq!(rms(&[]), 0.0);
    }
}
