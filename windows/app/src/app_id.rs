//! The core tells apps apart by macOS bundle id (messengers, mail, code
//! editors get different output modes). On Windows the focused app is known by
//! its executable, so well-known programs are mapped to the bundle id of their
//! Mac version; everything else is passed as `win:<exe>`, which matches no
//! category and gets the default mode.

const KNOWN: &[(&str, &str)] = &[
    ("telegram.exe", "org.telegram.desktop"),
    ("ayugram.exe", "org.telegram.desktop"),
    ("whatsapp.exe", "desktop.WhatsApp"),
    ("whatsapp.root.exe", "desktop.WhatsApp"),
    ("discord.exe", "com.hnc.Discord"),
    ("slack.exe", "com.tinyspeck.slackmacgap"),
    ("viber.exe", "com.viber.osx"),
    ("outlook.exe", "com.microsoft.Outlook"),
    ("olk.exe", "com.microsoft.Outlook"),
    ("code.exe", "com.microsoft.VSCode"),
    ("cursor.exe", "com.todesktop.230313mzl4w4u92"),
    ("zed.exe", "dev.zed.Zed"),
    ("windowsterminal.exe", "com.apple.Terminal"),
    ("wezterm-gui.exe", "com.github.wez.wezterm"),
    ("idea64.exe", "com.jetbrains.intellij"),
    ("pycharm64.exe", "com.jetbrains.pycharm"),
    ("rider64.exe", "com.jetbrains.rider"),
    ("clion64.exe", "com.jetbrains.CLion"),
    ("webstorm64.exe", "com.jetbrains.WebStorm"),
    ("goland64.exe", "com.jetbrains.goland"),
    ("chatgpt.exe", "com.openai.chat"),
    ("claude.exe", "com.anthropic.claudefordesktop"),
    ("chrome.exe", "com.google.Chrome"),
    ("msedge.exe", "com.microsoft.edgemac"),
    ("firefox.exe", "org.mozilla.firefox"),
    ("brave.exe", "com.brave.Browser"),
    ("browser.exe", "ru.yandex.desktop.yandex-browser"),
    ("arc.exe", "company.thebrowser.Browser"),
];

/// `exe` is a file name or a full path.
pub fn app_id_for_exe(exe: &str) -> Option<String> {
    let name = exe.rsplit(['\\', '/']).next()?.trim();
    if name.is_empty() {
        return None;
    }
    let lower = name.to_lowercase();
    Some(match KNOWN.iter().find(|(e, _)| *e == lower) {
        Some((_, id)) => (*id).to_string(),
        None => format!("win:{lower}"),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use velikiy_moguchiy_core::app_context::{app_category, AppCategory};

    #[test]
    fn known_programs_get_the_mac_category() {
        let category = |exe| app_category(app_id_for_exe(exe).as_deref());
        assert_eq!(
            category(r"C:\Users\u\AppData\Roaming\Telegram Desktop\Telegram.exe"),
            AppCategory::Messenger
        );
        assert_eq!(category("OUTLOOK.EXE"), AppCategory::Mail);
        assert_eq!(category("Code.exe"), AppCategory::Dev);
        assert_eq!(category("idea64.exe"), AppCategory::Dev);
        assert_eq!(category("msedge.exe"), AppCategory::Browser);
        assert_eq!(category("notepad.exe"), AppCategory::Other);
    }

    #[test]
    fn unknown_programs_are_prefixed_and_empty_names_are_none() {
        assert_eq!(
            app_id_for_exe("C:/Tools/Notepad.exe").unwrap(),
            "win:notepad.exe"
        );
        assert_eq!(app_id_for_exe(r"C:\Tools\"), None);
        assert_eq!(app_id_for_exe(""), None);
    }
}
