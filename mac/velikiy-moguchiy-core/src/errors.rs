use std::fmt;

#[derive(Debug)]
pub enum CoreError {
    Config(String),
    LlmFailed(String),
    LlmTimeout,
    SessionInvalidState { from: String, action: String },
    PermissionDenied(String),
    PasteFailed(String),
    AudioBuffer(String),
    Internal(String),
}

impl fmt::Display for CoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CoreError::Config(msg) => write!(f, "config error: {msg}"),
            CoreError::LlmFailed(msg) => write!(f, "LLM correction failed: {msg}"),
            CoreError::LlmTimeout => write!(f, "LLM correction timed out"),
            CoreError::SessionInvalidState { from, action } => {
                write!(f, "invalid state transition: {action} from {from}")
            }
            CoreError::PermissionDenied(msg) => write!(f, "permission denied: {msg}"),
            CoreError::PasteFailed(msg) => write!(f, "paste failed: {msg}"),
            CoreError::AudioBuffer(msg) => write!(f, "audio buffer error: {msg}"),
            CoreError::Internal(msg) => write!(f, "internal error: {msg}"),
        }
    }
}

impl std::error::Error for CoreError {}

pub type Result<T> = std::result::Result<T, CoreError>;
