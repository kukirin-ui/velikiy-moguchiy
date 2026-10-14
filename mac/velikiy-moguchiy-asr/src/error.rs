use std::fmt;

#[derive(Debug)]
pub enum AsrError {
    /// WebSocket connection failed
    Connection(String),
    /// Timed out waiting for ASR result
    Timeout,
    /// Binary protocol or server-side error
    Protocol(String),
}

impl fmt::Display for AsrError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            AsrError::Connection(msg) => write!(f, "ASR connection failed: {msg}"),
            AsrError::Timeout => write!(f, "ASR result timed out"),
            AsrError::Protocol(msg) => write!(f, "ASR protocol error: {msg}"),
        }
    }
}

impl std::error::Error for AsrError {}

pub type Result<T> = std::result::Result<T, AsrError>;
