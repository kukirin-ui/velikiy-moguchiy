//! Voice snippets: a spoken trigger phrase expands to a fixed text.
//!
//! The trigger is matched on the dictated text, not trusted to the model: when
//! the whole dictation is a trigger, or when it contains "вставь <trigger>",
//! the snippet text replaces it exactly as written. Case, "ё" and punctuation
//! are ignored when comparing.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct Snippet {
    pub trigger: String,
    #[serde(default)]
    pub text: String,
}

/// Words that introduce a snippet inside a longer dictation.
const INSERT_WORDS: &[&str] = &["вставь", "вставить", "вставьте", "insert"];

fn normalize_word(word: &str) -> String {
    word.chars()
        .flat_map(char::to_lowercase)
        .map(|c| if c == 'ё' { 'е' } else { c })
        .collect()
}

struct Word {
    start: usize,
    end: usize,
    normalized: String,
}

fn words(text: &str) -> Vec<Word> {
    let mut found = Vec::new();
    let mut start = None;
    let close = |from: usize, to: usize, found: &mut Vec<Word>| {
        found.push(Word {
            start: from,
            end: to,
            normalized: normalize_word(&text[from..to]),
        });
    };
    for (at, ch) in text.char_indices() {
        match (ch.is_alphanumeric(), start) {
            (true, None) => start = Some(at),
            (false, Some(from)) => {
                close(from, at, &mut found);
                start = None;
            }
            _ => {}
        }
    }
    if let Some(from) = start {
        close(from, text.len(), &mut found);
    }
    found
}

fn is_only_punctuation(text: &str) -> bool {
    text.chars().all(|c| !c.is_alphanumeric())
}

/// The snippets that can match, longest trigger first, with their words.
fn candidates(snippets: &[Snippet]) -> Vec<(Vec<String>, &Snippet)> {
    let mut list: Vec<(Vec<String>, &Snippet)> = snippets
        .iter()
        .map(|s| {
            let parts = words(&s.trigger)
                .into_iter()
                .map(|w| w.normalized)
                .collect::<Vec<_>>();
            (parts, s)
        })
        .filter(|(parts, _)| !parts.is_empty())
        .collect();
    list.sort_by_key(|(parts, _)| std::cmp::Reverse(parts.len()));
    list
}

/// Expand snippets in `text`. None when nothing matched.
pub fn apply(text: &str, snippets: &[Snippet]) -> Option<String> {
    let candidates = candidates(snippets);
    let found = words(text);
    if candidates.is_empty() || found.is_empty() {
        return None;
    }

    let spoken: Vec<&str> = found.iter().map(|w| w.normalized.as_str()).collect();
    if let Some((_, snippet)) = candidates
        .iter()
        .find(|(parts, _)| parts.iter().map(String::as_str).eq(spoken.iter().copied()))
    {
        return Some(snippet.text.clone());
    }

    // (start of "вставь", end of the trigger, snippet)
    let mut hits: Vec<(usize, usize, &Snippet)> = Vec::new();
    let mut i = 0;
    while i < found.len() {
        let hit = if INSERT_WORDS.contains(&found[i].normalized.as_str()) {
            candidates.iter().find_map(|(parts, snippet)| {
                let span = found.get(i + 1..i + 1 + parts.len())?;
                let same = span.iter().zip(parts).all(|(w, p)| w.normalized == *p);
                same.then(|| (span.len(), span.last().map_or(0, |w| w.end), *snippet))
            })
        } else {
            None
        };
        match hit {
            Some((count, end, snippet)) => {
                hits.push((found[i].start, end, snippet));
                i += 1 + count;
            }
            None => i += 1,
        }
    }

    let (first_start, _, first) = *hits.first()?;
    let last_end = hits.last().map_or(0, |h| h.1);
    if hits.len() == 1
        && is_only_punctuation(&text[..first_start])
        && is_only_punctuation(&text[last_end..])
    {
        return Some(first.text.clone());
    }
    let mut out = String::with_capacity(text.len());
    let mut copied = 0;
    for (start, end, snippet) in hits {
        out.push_str(&text[copied..start]);
        out.push_str(&snippet.text);
        copied = end;
    }
    out.push_str(&text[copied..]);
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn snippet(trigger: &str, text: &str) -> Snippet {
        Snippet {
            trigger: trigger.into(),
            text: text.into(),
        }
    }

    fn book() -> Vec<Snippet> {
        vec![
            snippet("мой имейл", "ivan@example.com"),
            snippet("подпись", "С уважением,\nИван"),
            snippet("мой рабочий имейл", "work@example.com"),
        ]
    }

    #[test]
    fn whole_dictation_equal_to_a_trigger_is_replaced() {
        assert_eq!(
            apply("Мой имейл.", &book()).as_deref(),
            Some("ivan@example.com")
        );
        assert_eq!(apply("мой  ИМЕЙЛ", &book()).as_deref(), Some("ivan@example.com"));
        assert_eq!(apply("«Подпись»!", &book()).as_deref(), Some("С уважением,\nИван"));
    }

    #[test]
    fn insert_word_expands_inside_a_sentence() {
        assert_eq!(
            apply("Напиши мне на вставь мой имейл, пожалуйста.", &book()).as_deref(),
            Some("Напиши мне на ivan@example.com, пожалуйста.")
        );
        assert_eq!(
            apply("Вставь подпись.", &book()).as_deref(),
            Some("С уважением,\nИван")
        );
        assert_eq!(
            apply("Спасибо. Вставь подпись", &book()).as_deref(),
            Some("Спасибо. С уважением,\nИван")
        );
    }

    #[test]
    fn longest_trigger_wins() {
        assert_eq!(
            apply("вставь мой рабочий имейл", &book()).as_deref(),
            Some("work@example.com")
        );
        assert_eq!(apply("мой рабочий имейл", &book()).as_deref(), Some("work@example.com"));
    }

    #[test]
    fn several_expansions_in_one_dictation() {
        assert_eq!(
            apply("вставь мой имейл и вставь подпись", &book()).as_deref(),
            Some("ivan@example.com и С уважением,\nИван")
        );
    }

    #[test]
    fn trigger_inside_a_sentence_without_the_insert_word_stays() {
        assert_eq!(apply("Это мой имейл для связи.", &book()), None);
        assert_eq!(apply("Напиши подпись внизу", &book()), None);
    }

    #[test]
    fn yo_and_case_are_ignored() {
        let list = vec![snippet("её адрес", "Москва")];
        assert_eq!(apply("ЕЕ адрес", &list).as_deref(), Some("Москва"));
    }

    #[test]
    fn empty_triggers_and_empty_books_do_nothing() {
        assert_eq!(apply("привет", &[]), None);
        assert_eq!(apply("привет", &[snippet("  ", "x")]), None);
        assert_eq!(apply("", &book()), None);
        assert_eq!(apply("...", &book()), None);
    }

    #[test]
    fn the_text_is_inserted_exactly() {
        let list = vec![snippet("код", "  {\"a\": 1}\n")];
        assert_eq!(apply("вставь код", &list).as_deref(), Some("  {\"a\": 1}\n"));
    }
}
