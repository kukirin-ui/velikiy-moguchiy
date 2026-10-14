//! «Проверить ключ» for DashScope: one key, the configured endpoint and model,
//! connected up to the point where the session is set up and closed before any
//! audio is sent, so a check costs nothing. A key the endpoint refuses is tried
//! on the other region's endpoint too, to tell a wrong key from a wrong region.

use std::time::Duration;
use velikiy_moguchiy_asr::{AsrConfig, AsrProvider, QwenAsrProvider};

pub const CHINA_URL: &str = "wss://dashscope.aliyuncs.com/api-ws/v1/realtime";
pub const INTERNATIONAL_URL: &str = "wss://dashscope-intl.aliyuncs.com/api-ws/v1/realtime";

const CHECK_CONNECT_TIMEOUT_MS: u64 = 8000;

/// The same endpoint in the other region, for the two DashScope hosts.
pub fn other_region_url(url: &str) -> Option<&'static str> {
    if url.contains("dashscope-intl.aliyuncs.com") {
        Some(CHINA_URL)
    } else if url.contains("dashscope.aliyuncs.com") {
        Some(INTERNATIONAL_URL)
    } else {
        None
    }
}

/// Whether a failure may come from asking the wrong region: the key was refused,
/// not the network or the balance.
pub fn may_be_wrong_region(message: &str) -> bool {
    let text = message.to_ascii_lowercase();
    ["401", "invalidapikey", "invalid api", "invalid_api", "incorrect api", "unauthorized"]
        .iter()
        .any(|marker| text.contains(marker))
}

/// Ok when DashScope accepted `key` for `model` at `url`; the provider's error otherwise.
pub async fn check_key(url: &str, key: &str, model: &str) -> Result<(), String> {
    let config = AsrConfig {
        url: url.to_string(),
        app_key: model.to_string(),
        access_key: key.to_string(),
        access_keys: vec![key.to_string()],
        resource_id: String::new(),
        connect_timeout_ms: CHECK_CONNECT_TIMEOUT_MS,
        enable_ddc: false,
        enable_itn: false,
        enable_punc: false,
        enable_nonstream: false,
        ..AsrConfig::default()
    };
    let mut provider = QwenAsrProvider::new();
    let result = tokio::time::timeout(
        Duration::from_millis(CHECK_CONNECT_TIMEOUT_MS * 2),
        provider.connect(&config),
    )
    .await
    .unwrap_or_else(|_| Err(velikiy_moguchiy_asr::AsrError::Timeout));
    let _ = provider.close().await;
    result.map_err(|e| e.to_string())
}

#[derive(Debug, PartialEq, Eq, serde::Serialize)]
pub struct KeyCheck {
    pub ok: bool,
    /// The provider's message when the key failed at `url`.
    pub message: String,
    /// The other region's endpoint when the key works there instead.
    pub works_at: Option<String>,
}

pub async fn check_key_and_region(url: &str, key: &str, model: &str) -> KeyCheck {
    match check_key(url, key, model).await {
        Ok(()) => KeyCheck {
            ok: true,
            message: String::new(),
            works_at: None,
        },
        Err(message) => {
            let mut works_at = None;
            if may_be_wrong_region(&message) {
                if let Some(other) = other_region_url(url) {
                    if check_key(other, key, model).await.is_ok() {
                        works_at = Some(other.to_string());
                    }
                }
            }
            KeyCheck {
                ok: false,
                message,
                works_at,
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn regions_swap() {
        assert_eq!(other_region_url(CHINA_URL), Some(INTERNATIONAL_URL));
        assert_eq!(other_region_url(INTERNATIONAL_URL), Some(CHINA_URL));
        assert_eq!(other_region_url("wss://proxy.example.com/realtime"), None);
    }

    #[test]
    fn only_a_refused_key_suggests_another_region() {
        assert!(may_be_wrong_region("ASR connection failed: HTTP error: 401 Unauthorized"));
        assert!(may_be_wrong_region("ASR connection failed: Invalid API-key provided."));
        assert!(!may_be_wrong_region("ASR connection failed: connection timed out"));
        assert!(!may_be_wrong_region("ASR protocol error: Arrearage"));
    }
}
