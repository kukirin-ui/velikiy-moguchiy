//! The app's data directory (config, keys, models, history, recordings).
//!
//! The app was renamed from its working name; data written by earlier builds
//! lives in `~/.koe`. That directory keeps being used while the new one does
//! not exist, so existing settings and API keys survive the rename.

use std::path::{Path, PathBuf};

/// Data directory name under the home folder.
pub const DIR_NAME: &str = ".velikiy-moguchiy";

/// Data directory name used before the rename.
pub const LEGACY_DIR_NAME: &str = ".koe";

/// `~/.velikiy-moguchiy`, or `~/.koe` when only that one exists.
/// Windows usually has no `HOME`; the profile folder takes its place there.
pub fn app_data_dir() -> PathBuf {
    let home = std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .unwrap_or_else(|| "/tmp".into());
    app_data_dir_in(Path::new(&home))
}

/// The data directory under `home`: the new one, unless only the legacy one exists.
pub fn app_data_dir_in(home: &Path) -> PathBuf {
    let current = home.join(DIR_NAME);
    let legacy = home.join(LEGACY_DIR_NAME);
    if !current.exists() && legacy.is_dir() {
        legacy
    } else {
        current
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn temp_home(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "velikiy-moguchiy-app-dir-{tag}-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn fresh_home_uses_the_new_directory() {
        let home = temp_home("fresh");
        assert_eq!(app_data_dir_in(&home), home.join(DIR_NAME));
        fs::remove_dir_all(&home).unwrap();
    }

    #[test]
    fn legacy_directory_is_kept_when_it_is_the_only_one() {
        let home = temp_home("legacy");
        fs::create_dir_all(home.join(LEGACY_DIR_NAME)).unwrap();
        assert_eq!(app_data_dir_in(&home), home.join(LEGACY_DIR_NAME));
        fs::remove_dir_all(&home).unwrap();
    }

    #[test]
    fn new_directory_wins_when_both_exist() {
        let home = temp_home("both");
        fs::create_dir_all(home.join(LEGACY_DIR_NAME)).unwrap();
        fs::create_dir_all(home.join(DIR_NAME)).unwrap();
        assert_eq!(app_data_dir_in(&home), home.join(DIR_NAME));
        fs::remove_dir_all(&home).unwrap();
    }

    #[test]
    fn legacy_file_instead_of_directory_is_ignored() {
        let home = temp_home("file");
        fs::write(home.join(LEGACY_DIR_NAME), b"").unwrap();
        assert_eq!(app_data_dir_in(&home), home.join(DIR_NAME));
        fs::remove_dir_all(&home).unwrap();
    }
}
