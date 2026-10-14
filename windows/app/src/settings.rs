//! What the settings window edits, read from and written to the same
//! `config.yaml` the Mac app uses. Windows-only keys live under `windows:`,
//! because the core rewrites `hotkey.trigger_key` to a Mac key name.

use crate::hotkey::{TriggerKey, TriggerMode};
use crate::keys::{self, Vault};
use velikiy_moguchiy_core::config;

pub const KEY_TRIGGER: &str = "windows.trigger_key";
pub const KEY_TRIGGER_MODE: &str = "hotkey.trigger_mode";
pub const KEY_PROVIDER: &str = "asr.provider";
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

pub const LANGUAGES: &[(&str, &str)] = &[("ru", "Русский"), ("en", "Английский")];
pub const DEFAULT_LANGUAGE: &str = "ru";

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
    pub fn load(vault: &dyn Vault) -> Settings {
        let get = |key: &str| config::config_get(key).unwrap_or_default();
        let provider = non_empty(get(KEY_PROVIDER)).unwrap_or_else(|| PROVIDER_QWEN.into());
        let qwen_key = keys::load(vault).into_iter().next().unwrap_or_default();
        Settings {
            provider,
            qwen_key,
            qwen_model: non_empty(get(KEY_QWEN_MODEL)).unwrap_or_else(|| QWEN_MODELS[0].0.into()),
            qwen_language: non_empty(get(KEY_QWEN_LANGUAGE))
                .unwrap_or_else(|| DEFAULT_LANGUAGE.into()),
            trigger_key: TriggerKey::parse(&get(KEY_TRIGGER)).unwrap_or(TriggerKey::DEFAULT),
            trigger_mode: TriggerMode::parse(&get(KEY_TRIGGER_MODE)),
        }
    }

    /// Writes only what changed, so a hand-edited config.yaml keeps everything
    /// the window does not know about.
    pub fn save(&self, before: &Settings, vault: &dyn Vault) -> Result<(), String> {
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
            if !keys::valid_key(key) {
                return Err(
                    "в ключе есть недопустимые символы (пробел, кавычки, буквы не латиницей)"
                        .into(),
                );
            }
            // The first key of the list is the one shown; the rest stay.
            let mut list = keys::load(vault);
            if list.is_empty() {
                list.push(String::new());
            }
            list[0] = key.to_string();
            list.retain(|k| !k.is_empty());
            keys::store(vault, &list)?;
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

/// First start on Windows (no `windows.trigger_key` yet): the dictation key
/// and Russian as the recognition language instead of the core's `zh`.
pub fn apply_windows_defaults() -> Result<(), String> {
    if !config::config_get(KEY_TRIGGER)
        .unwrap_or_default()
        .trim()
        .is_empty()
    {
        return Ok(());
    }
    let set =
        |key: &str, value: &str| config::config_set(key, value).map_err(|e| format!("{key}: {e}"));
    let language = config::config_get(KEY_QWEN_LANGUAGE).unwrap_or_default();
    if matches!(language.trim(), "" | "zh") {
        set(KEY_QWEN_LANGUAGE, DEFAULT_LANGUAGE)?;
    }
    set(KEY_TRIGGER, &TriggerKey::DEFAULT.config_value())
}

fn non_empty(s: String) -> Option<String> {
    let t = s.trim();
    (!t.is_empty()).then(|| t.to_string())
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

    const VAULT: crate::keys::tests::FakeVault = crate::keys::tests::FakeVault(1);

    #[test]
    fn fresh_config_needs_a_key() {
        let _home = TempHome::new("fresh");
        let s = Settings::load(&VAULT);
        assert_eq!(s.provider, PROVIDER_QWEN);
        assert_eq!(s.qwen_key, "");
        assert_eq!(s.qwen_model, QWEN_MODELS[0].0);
        assert_eq!(s.trigger_key, TriggerKey::DEFAULT);
        assert!(s.problem().is_some());
    }

    #[test]
    fn first_start_on_windows_switches_the_language_to_russian_once() {
        let _home = TempHome::new("defaults");
        assert_eq!(config::config_get(KEY_QWEN_LANGUAGE).unwrap(), "zh");
        apply_windows_defaults().unwrap();
        assert_eq!(Settings::load(&VAULT).qwen_language, "ru");
        assert_eq!(config::config_get(KEY_TRIGGER).unwrap(), "right_ctrl");
        config::config_set(KEY_QWEN_LANGUAGE, "en").unwrap();
        apply_windows_defaults().unwrap();
        assert_eq!(Settings::load(&VAULT).qwen_language, "en");
    }

    #[test]
    fn save_round_trips_and_core_sees_the_key() {
        let _home = TempHome::new("roundtrip");
        let before = Settings::load(&VAULT);
        let mut after = before.clone();
        after.qwen_key = "  sk-test-1  ".into();
        after.qwen_model = QWEN_MODELS[1].0.into();
        after.qwen_language = "en".into();
        after.trigger_key = TriggerKey::F(9);
        after.trigger_mode = TriggerMode::Auto;
        after.save(&before, &VAULT).unwrap();

        let loaded = Settings::load(&VAULT);
        assert_eq!(loaded.qwen_key, "sk-test-1");
        assert_eq!(loaded.qwen_model, QWEN_MODELS[1].0);
        assert_eq!(loaded.qwen_language, "en");
        assert_eq!(loaded.trigger_key, TriggerKey::F(9));
        assert_eq!(loaded.trigger_mode, TriggerMode::Auto);
        assert!(loaded.problem().is_none());

        let raw = std::fs::read_to_string(config::config_dir().join("config.yaml")).unwrap();
        assert!(
            !raw.contains("sk-test-1"),
            "the key must not be stored in the clear"
        );
        let cfg = config::load_config().unwrap();
        assert_eq!(
            cfg.asr.qwen.effective_api_keys(),
            vec!["sk-test-1".to_string()]
        );
        assert_eq!(cfg.asr.qwen.model, QWEN_MODELS[1].0);
        // The Mac key name must survive: the core normalizes it on load.
        assert_eq!(cfg.hotkey.trigger_key, "fn");
    }

    #[test]
    fn a_key_that_would_break_the_config_is_refused() {
        let _home = TempHome::new("badkey");
        let before = Settings::load(&VAULT);
        let mut after = before.clone();
        after.qwen_key = "sk 'x'".into();
        assert!(after.save(&before, &VAULT).is_err());
        assert_eq!(Settings::load(&VAULT).qwen_key, "");
    }

    #[test]
    fn changing_the_key_keeps_spare_keys() {
        let _home = TempHome::new("spare");
        crate::keys::store(&VAULT, &["old".to_string(), "spare".to_string()]).unwrap();
        let before = Settings::load(&VAULT);
        assert_eq!(before.qwen_key, "old");
        let mut after = before.clone();
        after.qwen_key = "new".into();
        after.save(&before, &VAULT).unwrap();
        assert_eq!(
            crate::keys::load(&VAULT),
            vec!["new".to_string(), "spare".to_string()]
        );
    }

    #[test]
    fn switching_to_local_picks_a_model_that_knows_russian() {
        let _home = TempHome::new("local");
        let before = Settings::load(&VAULT);
        let mut after = before.clone();
        after.provider = PROVIDER_LOCAL.into();
        after.save(&before, &VAULT).unwrap();
        let cfg = config::load_config().unwrap();
        assert_eq!(cfg.asr.provider, PROVIDER_LOCAL);
        assert_eq!(cfg.asr.sherpa_onnx.model, LOCAL_MODEL);
        assert!(Settings::load(&VAULT).problem().is_none());
    }
}
