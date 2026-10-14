use std::collections::VecDeque;

/// A ring buffer for PCM audio frames to prevent first-word truncation.
/// Pre-captures audio during the hotkey decision window so that
/// audio recorded before the session officially starts is not lost.
pub struct AudioBuffer {
    frames: VecDeque<Vec<u8>>,
    max_frames: usize,
}

impl AudioBuffer {
    /// Create a new audio buffer.
    /// `max_duration_ms` - maximum buffered duration in milliseconds
    /// `frame_ms` - duration of each frame in milliseconds
    pub fn new(max_duration_ms: u32, frame_ms: u32) -> Self {
        let max_frames = if frame_ms > 0 {
            (max_duration_ms / frame_ms) as usize
        } else {
            0
        };
        Self {
            frames: VecDeque::with_capacity(max_frames),
            max_frames,
        }
    }

    /// Push a new frame into the buffer, evicting the oldest if full.
    pub fn push(&mut self, frame: Vec<u8>) {
        if self.max_frames == 0 {
            return;
        }
        if self.frames.len() >= self.max_frames {
            self.frames.pop_front();
        }
        self.frames.push_back(frame);
    }

    /// Drain all buffered frames in order (oldest first).
    pub fn drain(&mut self) -> Vec<Vec<u8>> {
        self.frames.drain(..).collect()
    }

    /// Clear all buffered frames without returning them.
    pub fn clear(&mut self) {
        self.frames.clear();
    }

    pub fn len(&self) -> usize {
        self.frames.len()
    }

    pub fn is_empty(&self) -> bool {
        self.frames.is_empty()
    }
}
