//! API-key rotation for providers that accept several interchangeable keys.
//!
//! Keys are identified by a hash so the pool never stores or logs them; callers
//! log the 1-based position in their list ("key #2") instead.

use std::collections::HashMap;
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

/// How long a key that hit an auth, quota or rate-limit failure is skipped.
pub const KEY_COOLDOWN: Duration = Duration::from_secs(10 * 60);

fn fingerprint(key: &str) -> u64 {
    let mut hasher = DefaultHasher::new();
    key.hash(&mut hasher);
    hasher.finish()
}

#[derive(Debug, Default)]
pub struct KeyPool {
    preferred: Option<u64>,
    cooldown_until: HashMap<u64, Instant>,
}

impl KeyPool {
    /// Indices into `keys` in the order they should be tried: the last working
    /// key first, then the rest in list order; keys on cooldown go last, as a
    /// final resort when everything else failed.
    pub fn order(&self, keys: &[String], now: Instant) -> Vec<usize> {
        let start = self
            .preferred
            .and_then(|p| keys.iter().position(|k| fingerprint(k) == p))
            .unwrap_or(0);
        let rotated = (0..keys.len()).map(|i| (start + i) % keys.len().max(1));
        let (ready, cooling): (Vec<usize>, Vec<usize>) =
            rotated.partition(|&i| !self.cooling(&keys[i], now));
        ready.into_iter().chain(cooling).collect()
    }

    pub fn cooling(&self, key: &str, now: Instant) -> bool {
        self.cooldown_until
            .get(&fingerprint(key))
            .is_some_and(|until| *until > now)
    }

    pub fn mark_failed(&mut self, key: &str, now: Instant) {
        let print = fingerprint(key);
        self.cooldown_until.insert(print, now + KEY_COOLDOWN);
        if self.preferred == Some(print) {
            self.preferred = None;
        }
    }

    pub fn mark_working(&mut self, key: &str) {
        let print = fingerprint(key);
        self.cooldown_until.remove(&print);
        self.preferred = Some(print);
    }
}

pub fn global() -> &'static Mutex<KeyPool> {
    static POOL: OnceLock<Mutex<KeyPool>> = OnceLock::new();
    POOL.get_or_init(|| Mutex::new(KeyPool::default()))
}

/// Whether an HTTP status (with the response body, if any) from the WebSocket
/// upgrade means "this key is unusable right now".
pub fn http_failure_is_key_problem(status: u16, body: &str) -> bool {
    matches!(status, 401 | 403 | 429) || (status == 400 && message_is_key_problem(body))
}

/// Whether a server error event (its `code` and `message`) means the key is
/// invalid, out of quota, overdue or throttled. DashScope codes: InvalidApiKey,
/// Arrearage, PostpaidBillOverdue, PrepaidBillOverdue, Throttling,
/// Throttling.RateQuota, Throttling.BurstRate, Throttling.AllocationQuota,
/// AllocationQuota.FreeTierOnly, BudgetLimitExceeded. Unknown errors are not
/// key problems; server-wide overload is not either, another key will not help.
pub fn error_event_is_key_problem(code: &str, message: &str) -> bool {
    message_is_key_problem(&format!("{code} {message}"))
}

fn message_is_key_problem(text: &str) -> bool {
    let text = text.to_ascii_lowercase();
    if text.contains("serviceoverloaded") || text.contains("resourceexhausted") {
        return false;
    }
    const MARKERS: &[&str] = &[
        "invalidapikey",
        "invalid_api_key",
        "invalid api-key",
        "invalid api key",
        "incorrect api key",
        "arrearage",
        "good standing",
        "overdue",
        "out_of_service",
        "quota",
        "throttling",
        "limit_requests",
        "limit_burst_rate",
        "budgetlimitexceeded",
        "rate limit",
        "request limit",
        "access denied",
        "accessdenied",
        "not authorized",
        "unauthorized",
    ];
    MARKERS.iter().any(|m| text.contains(m))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn keys() -> Vec<String> {
        vec!["k-a".into(), "k-b".into(), "k-c".into()]
    }

    #[test]
    fn fresh_pool_tries_keys_in_list_order() {
        let pool = KeyPool::default();
        assert_eq!(pool.order(&keys(), Instant::now()), [0, 1, 2]);
    }

    #[test]
    fn working_key_is_tried_first_next_time() {
        let mut pool = KeyPool::default();
        pool.mark_working("k-b");
        assert_eq!(pool.order(&keys(), Instant::now()), [1, 2, 0]);
    }

    #[test]
    fn failed_key_sinks_to_the_end_for_ten_minutes() {
        let mut pool = KeyPool::default();
        let t0 = Instant::now();
        pool.mark_failed("k-a", t0);
        assert_eq!(pool.order(&keys(), t0), [1, 2, 0]);
        assert_eq!(pool.order(&keys(), t0 + Duration::from_secs(599)), [1, 2, 0]);
        assert_eq!(pool.order(&keys(), t0 + KEY_COOLDOWN), [0, 1, 2]);
    }

    #[test]
    fn failing_the_preferred_key_moves_on_and_working_clears_cooldown() {
        let mut pool = KeyPool::default();
        let t0 = Instant::now();
        pool.mark_working("k-a");
        pool.mark_failed("k-a", t0);
        pool.mark_working("k-b");
        assert_eq!(pool.order(&keys(), t0), [1, 2, 0]);
        pool.mark_working("k-a");
        assert!(!pool.cooling("k-a", t0));
        assert_eq!(pool.order(&keys(), t0), [0, 1, 2]);
    }

    #[test]
    fn all_cooling_keys_are_still_returned_as_a_last_resort() {
        let mut pool = KeyPool::default();
        let t0 = Instant::now();
        for k in keys() {
            pool.mark_failed(&k, t0);
        }
        assert_eq!(pool.order(&keys(), t0).len(), 3);
    }

    #[test]
    fn removed_preferred_key_falls_back_to_list_start() {
        let mut pool = KeyPool::default();
        pool.mark_working("gone");
        assert_eq!(pool.order(&keys(), Instant::now()), [0, 1, 2]);
        assert!(pool.order(&[], Instant::now()).is_empty());
    }

    #[test]
    fn http_statuses() {
        assert!(http_failure_is_key_problem(401, ""));
        assert!(http_failure_is_key_problem(403, ""));
        assert!(http_failure_is_key_problem(429, ""));
        assert!(http_failure_is_key_problem(400, r#"{"code":"Arrearage"}"#));
        assert!(!http_failure_is_key_problem(400, "bad request"));
        assert!(!http_failure_is_key_problem(500, ""));
        assert!(!http_failure_is_key_problem(502, "Throttling"));
    }

    #[test]
    fn dashscope_error_codes() {
        assert!(error_event_is_key_problem("invalid_api_key", "Incorrect API key provided."));
        assert!(error_event_is_key_problem("InvalidApiKey", ""));
        assert!(error_event_is_key_problem(
            "Arrearage",
            "Access denied, please make sure your account is in good standing."
        ));
        assert!(error_event_is_key_problem("PostpaidBillOverdue", ""));
        assert!(error_event_is_key_problem("Throttling.RateQuota", "You have exceeded your request limit."));
        assert!(error_event_is_key_problem("", "Free allocated quota exceeded."));
        assert!(error_event_is_key_problem("AllocationQuota.FreeTierOnly", ""));
        assert!(!error_event_is_key_problem("Throttling.ServiceOverloaded", "Too many requests"));
        assert!(!error_event_is_key_problem("", "Unknown error"));
        assert!(!error_event_is_key_problem("invalid_request_error", "Unsupported voice"));
    }
}
