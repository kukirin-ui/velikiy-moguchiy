use windows::core::PCWSTR;

/// A NUL-terminated UTF-16 copy of `s` that stays alive with the value.
pub struct Wide(Vec<u16>);

impl Wide {
    pub fn new(s: &str) -> Wide {
        Wide(s.encode_utf16().chain(std::iter::once(0)).collect())
    }

    pub fn pcwstr(&self) -> PCWSTR {
        PCWSTR(self.0.as_ptr())
    }
}

/// Copies `s` into a fixed-size UTF-16 buffer (tray tooltips), truncating.
pub fn fill(dst: &mut [u16], s: &str) {
    let max = dst.len().saturating_sub(1);
    let mut n = 0;
    for (d, c) in dst.iter_mut().zip(s.encode_utf16().take(max)) {
        *d = c;
        n += 1;
    }
    if let Some(end) = dst.get_mut(n) {
        *end = 0;
    }
}
