//! What the settings window edits, read from and written to the same
//! `config.yaml` the Mac app uses. Windows-only keys live under `windows:`,
//! because the core rewrites `hotkey.trigger_key` to a Mac key name.

use crate::hotkey::{TriggerKey, TriggerMode};
use velikiy_moguchiy_core::config;

pub const KEY_TRIGGER: &str = "windows.trigger_key";
pub const KEY_TRIGGER_MODE: &str = "hotkey.trigger_mode";
pub const KEY_PROVIDER: &str = "asr.provider";
pub const KEY_QWEN_KEY: &str = "asr.qwen.api_key";
pub const KEY_QWEN_KEYS: &str = "asr.qwen.api_keys";
pub const KEY_QWEN_MODEL: &str = "asr.qwen.model";
pub const KEY_QWEN_LANGUAGE: &str = "asr.qwen.language";
pub const KEY_LOCAL_MODEL: &str = "asr.sherpa-onnx.model";

pub const PROVIDER_QWEN: &str = "qwen";
pub const PROVIDER_LOCAL: &str = "sherpa-onnx";

/// The streaming sherpa-onnx model that knows Russian; the core's default
/// (`bilingual-zh-en`) does not.
pub const LOCAL_MODEL: &str = "sherpa-onnx/multilingual-8lang";

/// Qwen realtime models offered in the picker, default first (same list as
/// the Mac settings).
pub const QWEN_MODELS: &[(&str, &str)] = &[
    (
        "qwen3.8-omni-flash-realtime",
        "Qwen Omni — понимает команды и чистит речь",
    ),
    (
        "qwen3-asr-flash-realtime",
        "Qwen-ASR — дословно, без правок",
    ),
];

pub const LANGUAGES: &[(&str, &str)] = &[
    ("ru", "Русский"),
    ("zh", "Как на Mac (zh)"),
    ("en", "Английский"),
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Settings {
    /// `asr.provider` as stored; providers the window does not offer are kept.
    pub provider: String,
    pub qwen_key: String,
    pub qwen_model: String,
    pub qwen_language: String,
    pub trigger_key: TriggerKey,
    pub trigger_mode: TriggerMode,
}

impl Settings {
    pub fn load() -> Settings {
        let get = |key: &str| config::config_get(key).unwrap_or_default();
        let provider = non_empty(get(KEY_PROVIDER)).unwrap_or_else(|| PROVIDER_QWEN.into());
        let qwen_key = qwen_keys()
            .into_iter()
            .next()
            .or_else(|| non_empty(get(KEY_QWEN_KEY)))
            .unwrap_or_default();
        Settings {
            provider,
            qwen_key,
            qwen_model: non_empty(get(KEY_QWEN_MODEL)).unwrap_or_else(|| QWEN_MODELS[0].0.into()),
            qwen_language: non_empty(get(KEY_QWEN_LANGUAGE)).unwrap_or_else(|| "zh".into()),
            trigger_key: TriggerKey::parse(&get(KEY_TRIGGER)).unwrap_or(TriggerKey::DEFAULT),
            trigger_mode: TriggerMode::parse(&get(KEY_TRIGGER_MODE)),
        }
    }

    /// Writes only what changed, so a hand-edited config.yaml keeps everything
    /// the window does not know about.
    pub fn save(&self, before: &Settings) -> Result<(), String> {
        let set = |key: &str, value: &str| {
            config::config_set(key, value).map_err(|e| format!("{key}: {e}"))
        };
        if self.provider != before.provider {
            set(KEY_PROVIDER, &self.provider)?;
        }
        if self.provider == PROVIDER_LOCAL && before.provider != PROVIDER_LOCAL {
            let model = config::config_get(KEY_LOCAL_MODEL).unwrap_or_default();
            if model.is_empty() || model == "sherpa-onnx/bilingual-zh-en" {
                set(KEY_LOCAL_MODEL, LOCAL_MODEL)?;
            }
        }
        let key = self.qwen_key.trim();
        if key != before.qwen_key.trim() {
            // The first key of the list is the one shown; the rest stay.
            let mut keys = qwen_keys();
            if keys.is_empty() {
                keys.push(String::new());
            }
            keys[0] = key.to_string();
            keys.retain(|k| !k.is_empty());
            let json = serde_json::to_string(&keys).map_err(|e| e.to_string())?;
            config::config_set_json(KEY_QWEN_KEYS, &json)
                .map_err(|e| format!("{KEY_QWEN_KEYS}: {e}"))?;
            set(KEY_QWEN_KEY, key)?;
        }
        if self.qwen_model.trim() != before.qwen_model.trim() && !self.qwen_model.trim().is_empty()
        {
            set(KEY_QWEN_MODEL, self.qwen_model.trim())?;
        }
        if self.qwen_language != before.qwen_language {
            set(KEY_QWEN_LANGUAGE, &self.qwen_language)?;
        }
        if self.trigger_key != before.trigger_key {
            set(KEY_TRIGGER, &self.trigger_key.config_value())?;
        }
        if self.trigger_mode != before.trigger_mode {
            set(KEY_TRIGGER_MODE, self.trigger_mode.config_value())?;
        }
        Ok(())
    }

    /// Why dictation cannot work yet, in words for the user; `None` when ready.
    pub fn problem(&self) -> Option<&'static str> {
        if self.provider == PROVIDER_QWEN && self.qwen_key.trim().is_empty() {
            return Some("Нужен ключ DashScope: откройте настройки в меню значка в трее.");
        }
        None
    }
}

fn qwen_keys() -> Vec<String> {
    let json = config::config_get_json(KEY_QWEN_KEYS).unwrap_or_default();
    parse_json_list(&json)
}

fn non_empty(s: String) -> Option<String> {
    let t = s.trim();
    (!t.is_empty()).then(|| t.to_string())
}

/// The non-empty strings of a JSON array; anything else gives an empty list.
fn parse_json_list(json: &str) -> Vec<String> {
    serde_json::from_str::<Vec<serde_json::Value>>(json)
        .unwrap_or_default()
        .iter()
        .filter_map(|v| v.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect()
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::path::PathBuf;
    use std::sync::Mutex;

    /// Tests that point HOME at a temporary data folder run one at a time.
    pub(crate) static HOME_LOCK: Mutex<()> = Mutex::new(());

    pub(crate) struct TempHome {
        pub dir: PathBuf,
        old_home: Option<std::ffi::OsString>,
        _guard: std::sync::MutexGuard<'static, ()>,
    }

    impl TempHome {
        pub(crate) fn new(tag: &str) -> TempHome {
            let guard = HOME_LOCK.lock().unwrap_or_else(|e| e.into_inner());
            let dir = std::env::temp_dir().join(format!("vm-windows-{tag}-{}", std::process::id()));
            let _ = std::fs::remove_dir_all(&dir);
            std::fs::create_dir_all(&dir).unwrap();
            let old_home = std::env::var_os("HOME");
            std::env::set_var("HOME", &dir);
            config::ensure_defaults().unwrap();
            TempHome {
                dir,
                old_home,
                _guard: guard,
            }
        }
    }

    impl Drop for TempHome {
        fn drop(&mut self) {
            match &self.old_home {
                Some(h) => std::env::set_var("HOME", h),
                None => std::env::remove_var("HOME"),
            }
            let _ = std::fs::remove_dir_all(&self.dir);
        }
    }

    #[test]
    fn fresh_config_needs_a_key() {
        let _home = TempHome::new("fresh");
        let s = Settings::load();
        assert_eq!(s.provider, PROVIDER_QWEN);
        assert_eq!(s.qwen_key, "");
        assert_eq!(s.qwen_model, QWEN_MODELS[0].0);
        assert_eq!(s.trigger_key, TriggerKey::DEFAULT);
        assert!(s.problem().is_some());
    }

    #[test]
    fn save_round_trips_and_core_sees_the_key() {
        let _home = TempHome::new("roundtrip");
        let before = Settings::load();
        let mut after = before.clone();
        after.qwen_key = "  sk-test \"1\"  ".into();
        after.qwen_model = QWEN_MODELS[1].0.into();
        after.qwen_language = "ru".into();
        after.trigger_key = TriggerKey::F(9);
        after.trigger_mode = TriggerMode::Auto;
        after.save(&before).unwrap();

        let loaded = Settings::load();
        assert_eq!(loaded.qwen_key, "sk-test \"1\"");
        assert_eq!(loaded.qwen_model, QWEN_MODELS[1].0);
        assert_eq!(loaded.qwen_language, "ru");
        assert_eq!(loaded.trigger_key, TriggerKey::F(9));
        assert_eq!(loaded.trigger_mode, TriggerMode::Auto);
        assert!(loaded.problem().is_none());

        let cfg = config::load_config().unwrap();
        assert_eq!(
            cfg.asr.qwen.effective_api_keys(),
            vec!["sk-test \"1\"".to_string()]
        );
        assert_eq!(cfg.asr.qwen.model, QWEN_MODELS[1].0);
        // The Mac key name must survive: the core normalizes it on load.
        assert_eq!(cfg.hotkey.trigger_key, "fn");
    }

    #[test]
    fn changing_the_key_keeps_spare_keys() {
        let _home = TempHome::new("spare");
        config::config_set_json(KEY_QWEN_KEYS, r#"["old","spare"]"#).unwrap();
        let before = Settings::load();
        assert_eq!(before.qwen_key, "old");
        let mut after = before.clone();
        after.qwen_key = "new".into();
        after.save(&before).unwrap();
        assert_eq!(qwen_keys(), vec!["new".to_string(), "spare".to_string()]);
    }

    #[test]
    fn switching_to_local_picks_a_model_that_knows_russian() {
        let _home = TempHome::new("local");
        let before = Settings::load();
        let mut after = before.clone();
        after.provider = PROVIDER_LOCAL.into();
        after.save(&before).unwrap();
        let cfg = config::load_config().unwrap();
        assert_eq!(cfg.asr.provider, PROVIDER_LOCAL);
        assert_eq!(cfg.asr.sherpa_onnx.model, LOCAL_MODEL);
        assert!(Settings::load().problem().is_none());
    }

    #[test]
    fn json_lists_keep_only_non_empty_strings() {
        assert_eq!(
            parse_json_list(r#"["\u0041", " ", 3, "к\\люч"]"#),
            vec!["A".to_string(), "к\\люч".to_string()]
        );
        assert!(parse_json_list("").is_empty());
        assert!(parse_json_list("null").is_empty());
    }
}
