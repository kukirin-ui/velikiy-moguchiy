use crate::app_context::AppCategory;
use crate::errors::{CoreError, Result};
use std::path::Path;

/// Starter list of IT terms and brands with spoken Russian variants, shipped
/// with the app and copied to the config dir on first run.
pub const STARTER_FILE_NAME: &str = "dictionary-it-ru.txt";
pub const STARTER_DICTIONARY: &str = include_str!("../resources/dictionary-it-ru.txt");

/// Most entries in the Omni instructions block.
pub const MAX_PROMPT_ENTRIES: usize = 120;
/// Most characters of entries in the Omni instructions block.
pub const MAX_PROMPT_CHARS: usize = 2500;
/// Spoken variants shown per starter entry.
const MAX_STARTER_VARIANTS: usize = 2;
/// Spoken variants shown per user entry.
const MAX_USER_VARIANTS: usize = 3;
/// Share of the character budget the app-specific sections may take before the
/// general core gets its turn.
const SPECIFIC_SHARE_PERCENT: usize = 70;

/// One dictionary line: `Correct | spoken1, spoken2`, or just `Correct`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DictEntry {
    pub term: String,
    pub variants: Vec<String>,
}

impl DictEntry {
    pub fn parse(line: &str) -> Option<Self> {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            return None;
        }
        let (term, variants) = match line.split_once('|') {
            Some((term, variants)) => (term.trim(), variants),
            None => (line, ""),
        };
        if term.is_empty() {
            return None;
        }
        let variants = variants
            .split(',')
            .map(str::trim)
            .filter(|v| !v.is_empty())
            .map(String::from)
            .collect();
        Some(Self {
            term: term.to_string(),
            variants,
        })
    }

    fn render(&self, max_variants: usize) -> String {
        if self.variants.is_empty() || max_variants == 0 {
            return self.term.clone();
        }
        let shown: Vec<&str> = self
            .variants
            .iter()
            .take(max_variants)
            .map(String::as_str)
            .collect();
        format!("{} ({})", self.term, shown.join(", "))
    }
}

/// A `# …` section of the starter list with its entries.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Section {
    pub title: String,
    pub entries: Vec<DictEntry>,
}

/// Dictionary entries, deduplicated by term, order kept. Accepts both plain
/// lines and `Correct | variants`.
pub fn parse_entries(content: &str) -> Vec<DictEntry> {
    let mut seen = std::collections::HashSet::new();
    content
        .lines()
        .filter_map(DictEntry::parse)
        .filter(|e| seen.insert(e.term.clone()))
        .collect()
}

/// Sections of the starter list. A run of comment lines directly above entries
/// starts a section, the first line of the run is its title; a comment run with
/// no entries after it (the file header) starts nothing.
pub fn parse_sections(content: &str) -> Vec<Section> {
    let mut sections: Vec<Section> = Vec::new();
    let mut title: Option<String> = None;
    let mut in_comment_run = false;
    for line in content.lines().map(str::trim) {
        if let Some(comment) = line.strip_prefix('#') {
            if !in_comment_run {
                title = Some(comment.trim().to_string());
            }
            in_comment_run = true;
        } else if line.is_empty() {
            in_comment_run = false;
        } else if let Some(entry) = DictEntry::parse(line) {
            in_comment_run = false;
            match sections.last_mut() {
                Some(section) if title.is_none() => section.entries.push(entry),
                _ => {
                    sections.push(Section {
                        title: title.take().unwrap_or_default(),
                        entries: vec![entry],
                    });
                }
            }
            title = None;
        }
    }
    sections
}

/// Which app categories a starter section is most useful for, by its title.
fn section_is_for(title: &str, category: AppCategory) -> bool {
    let title = title.to_lowercase();
    let has = |words: &[&str]| words.iter().any(|w| title.contains(w));
    match category {
        AppCategory::Dev => has(&[
            "git",
            "инфраструктур",
            "редактор",
            "язык",
            "фреймворк",
            "баз данных",
            "протокол",
            "командн",
            "ии и",
        ]),
        AppCategory::Messenger => has(&["мессенджер", "российск", "аббревиатур", "apple", "ии и"]),
        AppCategory::Mail => has(&["аббревиатур", "российск", "мессенджер", "редактор"]),
        AppCategory::Browser => has(&["ии и", "редактор", "российск", "мессенджер", "git"]),
        AppCategory::Other => false,
    }
}

fn is_homonym_section(title: &str) -> bool {
    title.to_lowercase().contains("омоним")
}

/// Round-robin over `pools`, taking one entry from each in turn, so that no
/// single section eats the budget.
fn interleave<'a>(pools: &[&'a Section]) -> Vec<&'a DictEntry> {
    let longest = pools.iter().map(|s| s.entries.len()).max().unwrap_or(0);
    let mut out = Vec::new();
    for i in 0..longest {
        for section in pools {
            if let Some(entry) = section.entries.get(i) {
                out.push(entry);
            }
        }
    }
    out
}

struct Budget {
    entries: usize,
    chars: usize,
}

impl Budget {
    fn new() -> Self {
        Self {
            entries: 0,
            chars: 0,
        }
    }

    /// Adds `text` if it still fits; the `"; "` separator counts.
    fn take(&mut self, text: &str) -> bool {
        let cost = text.chars().count() + if self.entries == 0 { 0 } else { 2 };
        if self.entries >= MAX_PROMPT_ENTRIES || self.chars + cost > MAX_PROMPT_CHARS {
            return false;
        }
        self.entries += 1;
        self.chars += cost;
        true
    }
}

/// The compact "correct spelling" block for the Omni session instructions, or
/// `None` when there is nothing to say. User entries go first and always win;
/// then starter sections matching the frontmost app's category, then the
/// general core. Homonym entries (terms that sound like ordinary Russian words)
/// are included only for developer tools, last, as bare terms.
pub fn build_prompt_block(
    user: &[DictEntry],
    starter: &[Section],
    category: AppCategory,
    developer_tool: bool,
) -> Option<String> {
    let mut budget = Budget::new();
    let mut items: Vec<String> = Vec::new();
    let mut seen = std::collections::HashSet::new();

    for entry in user {
        if seen.insert(entry.term.to_lowercase()) {
            let text = entry.render(MAX_USER_VARIANTS);
            if budget.take(&text) {
                items.push(text);
            }
        }
    }

    let regular: Vec<&Section> = starter
        .iter()
        .filter(|s| !is_homonym_section(&s.title))
        .collect();
    let (specific, core): (Vec<&Section>, Vec<&Section>) = regular
        .into_iter()
        .partition(|s| section_is_for(&s.title, category));

    let specific_limit = MAX_PROMPT_CHARS * SPECIFIC_SHARE_PERCENT / 100;
    'specific: for entry in interleave(&specific) {
        if !seen.insert(entry.term.to_lowercase()) {
            continue;
        }
        let text = entry.render(MAX_STARTER_VARIANTS);
        if budget.chars + text.chars().count() > specific_limit {
            break 'specific;
        }
        if budget.take(&text) {
            items.push(text);
        }
    }
    for entry in interleave(&core) {
        if !seen.insert(entry.term.to_lowercase()) {
            continue;
        }
        let text = entry.render(MAX_STARTER_VARIANTS);
        if budget.take(&text) {
            items.push(text);
        }
    }

    let mut homonyms: Vec<String> = Vec::new();
    if developer_tool {
        for section in starter.iter().filter(|s| is_homonym_section(&s.title)) {
            for entry in &section.entries {
                if seen.insert(entry.term.to_lowercase()) && budget.take(&entry.term) {
                    homonyms.push(entry.term.clone());
                }
            }
        }
    }

    if items.is_empty() && homonyms.is_empty() {
        return None;
    }
    let mut block = String::new();
    if !items.is_empty() {
        block.push_str(
            "Правильное написание терминов (если услышишь похожее по звучанию — пиши так): ",
        );
        block.push_str(&items.join("; "));
        block.push('.');
    }
    if !homonyms.is_empty() {
        if !block.is_empty() {
            block.push(' ');
        }
        block.push_str(
            "Названия программ и языков, которые звучат как обычные слова (пиши латиницей, \
             только если по смыслу речь о программе, языке или инструменте): ",
        );
        block.push_str(&homonyms.join(", "));
        block.push('.');
    }
    Some(block)
}

/// Load dictionary terms from a text file (the correct spelling of each line).
/// Skips empty lines and lines starting with '#'; for `Correct | variants`
/// lines only `Correct` is returned. Deduplicated, order preserved.
pub fn load_dictionary(path: &Path) -> Result<Vec<String>> {
    Ok(load_entries(path)?.into_iter().map(|e| e.term).collect())
}

/// Load dictionary entries, with spoken variants where the file has them.
pub fn load_entries(path: &Path) -> Result<Vec<DictEntry>> {
    if !path.exists() {
        log::info!("dictionary file not found: {}, using empty", path.display());
        return Ok(vec![]);
    }

    let content = std::fs::read_to_string(path)
        .map_err(|e| CoreError::Config(format!("read {}: {e}", path.display())))?;
    let entries = parse_entries(&content);

    log::info!(
        "loaded {} dictionary entries from {}",
        entries.len(),
        path.display()
    );
    Ok(entries)
}

/// Sections of the starter list file, falling back to the built-in copy when
/// the file is missing or unreadable.
pub fn load_starter_sections(path: &Path) -> Vec<Section> {
    match std::fs::read_to_string(path) {
        Ok(content) => parse_sections(&content),
        Err(_) => parse_sections(STARTER_DICTIONARY),
    }
}

/// Write the starter list next to the config unless it is already there.
pub fn ensure_starter_file(dir: &Path) -> Result<bool> {
    let path = dir.join(STARTER_FILE_NAME);
    if path.exists() {
        return Ok(false);
    }
    std::fs::write(&path, STARTER_DICTIONARY)
        .map_err(|e| CoreError::Config(format!("write {}: {e}", path.display())))?;
    log::info!("created default: {}", path.display());
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = "\
# Заголовок файла
# Формат: ...

# Git и платформы разработки
GitHub | гитхаб, гит хаб, гитхуб
Git | гит

# Мессенджеры и соцсети
Telegram | телеграм, телега
WhatsApp | вотсап

# Омонимы с обычными русскими словами
Cursor | курсор
Go | го
";

    fn user(lines: &str) -> Vec<DictEntry> {
        parse_entries(lines)
    }

    #[test]
    fn parses_plain_and_variant_lines() {
        let entries = parse_entries("# c\nKubernetes | кубер, кубернетис\nPlain\n\nPlain\n |x\n");
        assert_eq!(
            entries,
            vec![
                DictEntry {
                    term: "Kubernetes".into(),
                    variants: vec!["кубер".into(), "кубернетис".into()]
                },
                DictEntry {
                    term: "Plain".into(),
                    variants: vec![]
                },
            ]
        );
    }

    #[test]
    fn sections_skip_the_file_header_and_keep_titles() {
        let sections = parse_sections(SAMPLE);
        let titles: Vec<&str> = sections.iter().map(|s| s.title.as_str()).collect();
        assert_eq!(
            titles,
            [
                "Git и платформы разработки",
                "Мессенджеры и соцсети",
                "Омонимы с обычными русскими словами"
            ]
        );
        assert_eq!(sections[0].entries.len(), 2);
    }

    #[test]
    fn bundled_starter_list_parses_into_sections_with_homonyms_last() {
        let sections = parse_sections(STARTER_DICTIONARY);
        assert!(sections.len() >= 12);
        assert!(is_homonym_section(&sections.last().unwrap().title));
        assert!(sections.iter().all(|s| !s.entries.is_empty()));
        let total: usize = sections.iter().map(|s| s.entries.len()).sum();
        assert!(total > 400, "{total}");
    }

    #[test]
    fn user_entries_come_first_and_keep_their_variants() {
        let starter = parse_sections(SAMPLE);
        let block = build_prompt_block(
            &user("Grafana | графана\nПлотный"),
            &starter,
            AppCategory::Other,
            false,
        )
        .unwrap();
        let after = block.split("пиши так): ").nth(1).unwrap();
        assert!(after.starts_with("Grafana (графана); Плотный; "), "{block}");
    }

    #[test]
    fn matching_sections_precede_the_core() {
        let starter = parse_sections(SAMPLE);
        let block = build_prompt_block(&[], &starter, AppCategory::Messenger, false).unwrap();
        assert!(
            block.find("Telegram").unwrap() < block.find("GitHub").unwrap(),
            "{block}"
        );
        let dev = build_prompt_block(&[], &starter, AppCategory::Dev, false).unwrap();
        assert!(dev.find("GitHub").unwrap() < dev.find("Telegram").unwrap());
    }

    #[test]
    fn homonyms_only_for_developer_tools_and_as_bare_terms() {
        let starter = parse_sections(SAMPLE);
        let other = build_prompt_block(&[], &starter, AppCategory::Browser, false).unwrap();
        assert!(!other.contains("Cursor") && !other.contains("курсор"));
        let dev = build_prompt_block(&[], &starter, AppCategory::Dev, true).unwrap();
        assert!(dev.contains("Cursor, Go."), "{dev}");
        assert!(!dev.contains("курсор"));
    }

    #[test]
    fn user_entry_beats_a_starter_duplicate() {
        let starter = parse_sections(SAMPLE);
        let block = build_prompt_block(
            &user("github | гитхабчик"),
            &starter,
            AppCategory::Dev,
            false,
        )
        .unwrap();
        assert_eq!(block.matches("itHub").count() + block.matches("ithub").count(), 1);
    }

    #[test]
    fn the_real_starter_list_respects_the_caps_for_every_category() {
        let starter = parse_sections(STARTER_DICTIONARY);
        for category in [
            AppCategory::Messenger,
            AppCategory::Mail,
            AppCategory::Dev,
            AppCategory::Browser,
            AppCategory::Other,
        ] {
            let block = build_prompt_block(&[], &starter, category, true).unwrap();
            let entries = block.matches("; ").count() + 1;
            assert!(entries <= MAX_PROMPT_ENTRIES + 1, "{category:?}: {entries}");
            assert!(
                block.chars().count() < MAX_PROMPT_CHARS + 300,
                "{category:?}: {}",
                block.chars().count()
            );
        }
    }

    #[test]
    fn huge_user_dictionaries_are_capped_too() {
        let lines: String = (0..500).map(|i| format!("Term{i} | вариант{i}\n")).collect();
        let block = build_prompt_block(&user(&lines), &[], AppCategory::Other, false).unwrap();
        assert!(block.matches("Term").count() <= MAX_PROMPT_ENTRIES);
        assert!(block.chars().count() < MAX_PROMPT_CHARS + 300);
    }

    #[test]
    fn empty_input_gives_no_block() {
        assert_eq!(build_prompt_block(&[], &[], AppCategory::Dev, true), None);
    }

    #[test]
    fn specific_sections_leave_room_for_the_core() {
        let starter = parse_sections(STARTER_DICTIONARY);
        let block = build_prompt_block(&[], &starter, AppCategory::Dev, false).unwrap();
        assert!(block.contains("Telegram") || block.contains("Visa") || block.contains("ChatGPT"), "{block}");
    }
}
