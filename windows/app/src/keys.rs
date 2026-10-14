//! DashScope keys are not kept in config.yaml in the clear. They are sealed
//! for the current user (DPAPI on Windows) under `windows.dashscope_keys`,
//! and `asr.qwen.api_keys` holds only `${VELIKIY_MOGUCHIY_DASHSCOPE_KEY_<n>}`
//! references. The core substitutes environment variables when it reads the
//! config, so the decrypted keys only ever live in this process's environment.

use velikiy_moguchiy_core::config;

pub const KEY_SEALED: &str = "windows.dashscope_keys";
pub const KEY_QWEN_KEY: &str = "asr.qwen.api_key";
pub const KEY_QWEN_KEYS: &str = "asr.qwen.api_keys";
const ENV_PREFIX: &str = "VELIKIY_MOGUCHIY_DASHSCOPE_KEY_";
/// Variables left from a longer earlier list are cleared up to this index.
const MAX_KEYS: usize = 16;

/// Encryption bound to the current user.
pub trait Vault {
    fn seal(&self, plain: &[u8]) -> Result<Vec<u8>, String>;
    fn open(&self, sealed: &[u8]) -> Result<Vec<u8>, String>;
}

fn env_ref(i: usize) -> String {
    format!("${{{ENV_PREFIX}{i}}}")
}

/// The keys as the user knows them: plaintext ones not yet moved into the
/// vault win over sealed ones, because they were written later by hand.
pub fn load(vault: &dyn Vault) -> Vec<String> {
    let plain = plaintext();
    if !plain.is_empty() {
        return plain;
    }
    sealed(vault).unwrap_or_else(|e| {
        log::warn!(
            "stored DashScope keys cannot be decrypted ({e}); they have to be entered again"
        );
        Vec::new()
    })
}

/// Seals plaintext keys found in config.yaml and puts the keys into this
/// process's environment for the core. Call before the core reads the config.
pub fn secure(vault: &dyn Vault) -> Result<(), String> {
    let plain = plaintext();
    if !plain.is_empty() {
        log::info!("moving {} DashScope key(s) out of plaintext", plain.len());
        return store(vault, &plain);
    }
    export(&load(vault));
    Ok(())
}

/// Replaces every stored key with `keys`.
pub fn store(vault: &dyn Vault, keys: &[String]) -> Result<(), String> {
    let set =
        |key: &str, value: &str| config::config_set(key, value).map_err(|e| format!("{key}: {e}"));
    let set_list = |refs: &[String]| {
        let json = serde_json::to_string(refs).map_err(|e| e.to_string())?;
        config::config_set_json(KEY_QWEN_KEYS, &json).map_err(|e| format!("{KEY_QWEN_KEYS}: {e}"))
    };
    if keys.is_empty() {
        set(KEY_SEALED, "")?;
        set_list(&[])?;
        set(KEY_QWEN_KEY, "")?;
    } else {
        let json = serde_json::to_vec(keys).map_err(|e| e.to_string())?;
        let sealed = vault.seal(&json)?;
        set(KEY_SEALED, &base64_encode(&sealed))?;
        let refs: Vec<String> = (0..keys.len()).map(env_ref).collect();
        set_list(&refs)?;
        set(KEY_QWEN_KEY, &env_ref(0))?;
    }
    export(keys);
    Ok(())
}

/// Characters a key may have; anything else could break the YAML the core
/// reads after substituting the key into it.
pub fn valid_key(key: &str) -> bool {
    key.chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
}

fn export(keys: &[String]) {
    for i in 0..MAX_KEYS.max(keys.len()) {
        let name = format!("{ENV_PREFIX}{i}");
        match keys.get(i) {
            Some(key) => std::env::set_var(name, key),
            None => std::env::remove_var(name),
        }
    }
}

fn sealed(vault: &dyn Vault) -> Result<Vec<String>, String> {
    let stored = config::config_get(KEY_SEALED).unwrap_or_default();
    if stored.trim().is_empty() {
        return Ok(Vec::new());
    }
    let sealed = base64_decode(stored.trim()).ok_or("not base64")?;
    let json = vault.open(&sealed)?;
    serde_json::from_slice(&json).map_err(|e| e.to_string())
}

/// Plaintext keys in `asr.qwen.api_keys` / `asr.qwen.api_key`, the way the core
/// picks them; references to environment variables are not plaintext.
fn plaintext() -> Vec<String> {
    let json = config::config_get_json(KEY_QWEN_KEYS).unwrap_or_default();
    let mut keys: Vec<String> = serde_json::from_str::<Vec<serde_json::Value>>(&json)
        .unwrap_or_default()
        .iter()
        .filter_map(|v| v.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();
    if keys.is_empty() {
        let single = config::config_get(KEY_QWEN_KEY).unwrap_or_default();
        if !single.trim().is_empty() {
            keys.push(single.trim().to_string());
        }
    }
    keys.retain(|k| !k.contains("${"));
    keys
}

fn base64_encode(data: &[u8]) -> String {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.encode(data)
}

fn base64_decode(text: &str) -> Option<Vec<u8>> {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.decode(text).ok()
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::settings::tests::TempHome;

    /// Reversible stand-in for DPAPI; `open` fails like DPAPI does for
    /// another user's data when the marker byte is wrong.
    pub(crate) struct FakeVault(pub u8);

    impl Vault for FakeVault {
        fn seal(&self, plain: &[u8]) -> Result<Vec<u8>, String> {
            let mut out = vec![self.0];
            out.extend(plain.iter().map(|b| b ^ 0x5A));
            Ok(out)
        }

        fn open(&self, sealed: &[u8]) -> Result<Vec<u8>, String> {
            match sealed.split_first() {
                Some((&m, rest)) if m == self.0 => Ok(rest.iter().map(|b| b ^ 0x5A).collect()),
                _ => Err("wrong user".into()),
            }
        }
    }

    fn raw_config() -> String {
        std::fs::read_to_string(config::config_dir().join("config.yaml")).unwrap()
    }

    #[test]
    fn plaintext_keys_are_sealed_and_the_core_still_sees_them() {
        let _home = TempHome::new("keys-migrate");
        config::config_set_json(KEY_QWEN_KEYS, r#"["sk-first","sk-spare"]"#).unwrap();
        config::config_set(KEY_QWEN_KEY, "sk-first").unwrap();
        secure(&FakeVault(1)).unwrap();

        let raw = raw_config();
        assert!(
            !raw.contains("sk-first") && !raw.contains("sk-spare"),
            "{raw}"
        );
        assert_eq!(
            load(&FakeVault(1)),
            vec!["sk-first".to_string(), "sk-spare".to_string()]
        );
        let cfg = config::load_config().unwrap();
        assert_eq!(
            cfg.asr.qwen.effective_api_keys(),
            vec!["sk-first".to_string(), "sk-spare".to_string()]
        );
    }

    #[test]
    fn a_single_plaintext_key_is_migrated_too() {
        let _home = TempHome::new("keys-single");
        config::config_set(KEY_QWEN_KEY, "sk-only").unwrap();
        secure(&FakeVault(1)).unwrap();
        assert!(!raw_config().contains("sk-only"));
        assert_eq!(load(&FakeVault(1)), vec!["sk-only".to_string()]);
    }

    #[test]
    fn keys_sealed_for_someone_else_read_as_none() {
        let _home = TempHome::new("keys-other");
        store(&FakeVault(1), &["sk-x".to_string()]).unwrap();
        assert!(load(&FakeVault(2)).is_empty());
        secure(&FakeVault(2)).unwrap();
        assert_eq!(std::env::var(format!("{ENV_PREFIX}0")).ok(), None);
    }

    #[test]
    fn storing_nothing_clears_keys_and_variables() {
        let _home = TempHome::new("keys-clear");
        store(&FakeVault(1), &["a".to_string(), "b".to_string()]).unwrap();
        store(&FakeVault(1), &[]).unwrap();
        assert!(load(&FakeVault(1)).is_empty());
        assert!(config::load_config()
            .unwrap()
            .asr
            .qwen
            .effective_api_keys()
            .is_empty());
        assert_eq!(std::env::var(format!("{ENV_PREFIX}1")).ok(), None);
    }

    #[test]
    fn only_yaml_safe_keys_are_accepted() {
        assert!(valid_key("sk-0123abcdEF_x.y"));
        assert!(!valid_key("sk 1"));
        assert!(!valid_key("sk'1"));
        assert!(!valid_key("ключ"));
    }
}
