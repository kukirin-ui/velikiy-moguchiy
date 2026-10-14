//! Spoken formatting commands in dictated text ("новая строка", "вопросительный
//! знак", "удали последнее слово", "отправь", ...).
//!
//! The Omni model is told to keep a spoken command verbatim inside `⟦…⟧`
//! brackets instead of acting on it (`modes::VOICE_COMMANDS`); this module turns
//! the markers into text deterministically, so the result never depends on the
//! model's judgement. Multi-word commands that stand alone as a clause are also
//! recognised without brackets, as a safety net for a model that forgot them.
//! "отправь" is honoured only as a marker, only at the very end.

const OPEN: char = '⟦';
const CLOSE: char = '⟧';

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Command {
    NewLine,
    NewParagraph,
    Period,
    Comma,
    Question,
    Exclamation,
    Colon,
    Semicolon,
    Dash,
    OpenQuote,
    CloseQuote,
    DeleteWord,
    DeleteSentence,
    Send,
}

/// Spoken forms, normalised (lowercase, "е" for "ё", words separated by one
/// space). The first form of a command is the one written into a marker.
const PHRASES: &[(&str, Command)] = &[
    ("новая строка", Command::NewLine),
    ("новую строку", Command::NewLine),
    ("новой строки", Command::NewLine),
    ("с новой строки", Command::NewLine),
    ("на новую строку", Command::NewLine),
    ("в новой строке", Command::NewLine),
    ("перенос строки", Command::NewLine),
    ("перевод строки", Command::NewLine),
    ("new line", Command::NewLine),
    ("newline", Command::NewLine),
    ("line break", Command::NewLine),
    ("новый абзац", Command::NewParagraph),
    ("нового абзаца", Command::NewParagraph),
    ("новому абзацу", Command::NewParagraph),
    ("с нового абзаца", Command::NewParagraph),
    ("в новый абзац", Command::NewParagraph),
    ("на новый абзац", Command::NewParagraph),
    ("абзац", Command::NewParagraph),
    ("new paragraph", Command::NewParagraph),
    ("точка", Command::Period),
    ("точку", Command::Period),
    ("full stop", Command::Period),
    ("period", Command::Period),
    ("запятая", Command::Comma),
    ("запятую", Command::Comma),
    ("запятой", Command::Comma),
    ("comma", Command::Comma),
    ("вопросительный знак", Command::Question),
    ("вопросительного знака", Command::Question),
    ("знак вопроса", Command::Question),
    ("question mark", Command::Question),
    ("восклицательный знак", Command::Exclamation),
    ("восклицательного знака", Command::Exclamation),
    ("знак восклицания", Command::Exclamation),
    ("exclamation mark", Command::Exclamation),
    ("exclamation point", Command::Exclamation),
    ("двоеточие", Command::Colon),
    ("двоеточия", Command::Colon),
    ("colon", Command::Colon),
    ("точка с запятой", Command::Semicolon),
    ("точку с запятой", Command::Semicolon),
    ("semicolon", Command::Semicolon),
    ("тире", Command::Dash),
    ("dash", Command::Dash),
    ("открыть кавычки", Command::OpenQuote),
    ("открой кавычки", Command::OpenQuote),
    ("открыть кавычку", Command::OpenQuote),
    ("открывающая кавычка", Command::OpenQuote),
    ("открывающие кавычки", Command::OpenQuote),
    ("открытые кавычки", Command::OpenQuote),
    ("open quote", Command::OpenQuote),
    ("open quotes", Command::OpenQuote),
    ("begin quote", Command::OpenQuote),
    ("закрыть кавычки", Command::CloseQuote),
    ("закрой кавычки", Command::CloseQuote),
    ("закрыть кавычку", Command::CloseQuote),
    ("закрывающая кавычка", Command::CloseQuote),
    ("закрывающие кавычки", Command::CloseQuote),
    ("закрытые кавычки", Command::CloseQuote),
    ("close quote", Command::CloseQuote),
    ("close quotes", Command::CloseQuote),
    ("end quote", Command::CloseQuote),
    ("unquote", Command::CloseQuote),
    ("удали последнее слово", Command::DeleteWord),
    ("удалить последнее слово", Command::DeleteWord),
    ("удалите последнее слово", Command::DeleteWord),
    ("убери последнее слово", Command::DeleteWord),
    ("убрать последнее слово", Command::DeleteWord),
    ("сотри последнее слово", Command::DeleteWord),
    ("стереть последнее слово", Command::DeleteWord),
    ("delete last word", Command::DeleteWord),
    ("delete the last word", Command::DeleteWord),
    ("remove last word", Command::DeleteWord),
    ("удали последнее предложение", Command::DeleteSentence),
    ("удалить последнее предложение", Command::DeleteSentence),
    ("удалите последнее предложение", Command::DeleteSentence),
    ("убери последнее предложение", Command::DeleteSentence),
    ("убрать последнее предложение", Command::DeleteSentence),
    ("сотри последнее предложение", Command::DeleteSentence),
    ("стереть последнее предложение", Command::DeleteSentence),
    ("delete last sentence", Command::DeleteSentence),
    ("delete the last sentence", Command::DeleteSentence),
    ("remove last sentence", Command::DeleteSentence),
    ("отправь", Command::Send),
    ("отправить", Command::Send),
    ("отправь это", Command::Send),
    ("отправь сообщение", Command::Send),
    ("отправить сообщение", Command::Send),
    ("send", Command::Send),
    ("send it", Command::Send),
    ("send message", Command::Send),
];

/// Text after the commands were applied.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Processed {
    pub text: String,
    /// "отправь" ended the dictation: press Return after delivering `text`.
    pub send: bool,
}

/// Lowercase, "ё" → "е", everything but letters and digits → one space.
fn normalize_phrase(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut gap = false;
    for ch in text.chars().flat_map(char::to_lowercase) {
        let ch = if ch == 'ё' { 'е' } else { ch };
        if ch.is_alphanumeric() {
            if gap && !out.is_empty() {
                out.push(' ');
            }
            gap = false;
            out.push(ch);
        } else {
            gap = true;
        }
    }
    out
}

fn lookup(inner: &str) -> Option<Command> {
    let wanted = normalize_phrase(inner);
    PHRASES
        .iter()
        .find(|(phrase, _)| *phrase == wanted)
        .map(|(_, command)| *command)
}

fn marker_phrase(command: Command) -> &'static str {
    PHRASES
        .iter()
        .find(|(_, c)| *c == command)
        .map(|(phrase, _)| *phrase)
        .expect("every command has a phrase")
}

/// Apply the spoken commands in `text`. Text without any command comes back
/// untouched.
pub fn process(text: &str) -> Processed {
    let repaired = repair_markers(text, true);
    let marked = mark_plain_commands(&repaired);
    if !marked.contains(OPEN) {
        return Processed {
            text: repaired,
            send: false,
        };
    }
    run(&marked)
}

/// Commands in a reply that is still being typed: markers only (a phrase that
/// is a command only because of what follows must not flicker in and out), a
/// marker that has not been closed yet is held back, and so is trailing space.
pub fn process_streaming(raw: &str) -> String {
    let repaired = repair_markers(raw, false);
    let raw = repaired.as_str();
    let held = match raw.rfind(OPEN) {
        Some(at) if !raw[at..].contains(CLOSE) => &raw[..at],
        _ => raw,
    };
    // A trailing space may belong to a command that is still to come ("Привет
    // ⟦запятая⟧"): hold it back instead of typing it and erasing it again.
    run(held).text.trim_end_matches([' ', '\t']).to_string()
}

// ─── Markers ────────────────────────────────────────────────────────

#[derive(Clone, Copy, PartialEq, Eq)]
enum Join {
    /// The next text is appended as it comes.
    Raw,
    /// The next text is glued on (after a line break or an opening quote).
    Glue,
    /// The next text is separated by one space unless it starts with punctuation.
    Space,
}

/// Punctuation the model may have put around a command word that is now
/// redundant: swallowed from the start of the text that follows.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Absorb {
    No,
    /// `,` `;`
    Light,
    /// `.` `,` `;`
    Sentence,
}

impl Absorb {
    fn swallows(self, ch: char) -> bool {
        match self {
            Absorb::No => false,
            Absorb::Light => matches!(ch, ',' | ';'),
            Absorb::Sentence => matches!(ch, '.' | ',' | ';'),
        }
    }
}

struct Builder {
    out: String,
    join: Join,
    absorb: Absorb,
    capitalize: bool,
    send: bool,
}

impl Builder {
    fn new() -> Self {
        Self {
            out: String::new(),
            join: Join::Raw,
            absorb: Absorb::No,
            capitalize: false,
            send: false,
        }
    }

    fn trim_tail(&mut self, extra: &[char]) {
        while let Some(last) = self.out.chars().last() {
            if last == ' ' || last == '\t' || extra.contains(&last) {
                self.out.pop();
            } else {
                break;
            }
        }
    }

    fn ends_with_sentence_end(&self) -> bool {
        self.out.is_empty() || self.out.ends_with(['.', '!', '?', '…', '\n'])
    }

    fn text(&mut self, segment: &str) {
        let mut rest = segment;
        if self.absorb != Absorb::No {
            loop {
                let trimmed = rest.trim_start_matches([' ', '\t']);
                match trimmed.chars().next() {
                    Some(ch) if self.absorb.swallows(ch) => rest = &trimmed[ch.len_utf8()..],
                    _ => {
                        rest = trimmed;
                        break;
                    }
                }
            }
        }
        match self.join {
            Join::Raw => {
                if !rest.is_empty() {
                    self.out.push_str(rest);
                }
            }
            Join::Glue | Join::Space => {
                let rest = rest.trim_start_matches([' ', '\t']);
                if rest.is_empty() {
                    return;
                }
                if self.join == Join::Space && self.needs_space(rest) {
                    self.out.push(' ');
                }
                self.push_capitalized(rest);
                self.join = Join::Raw;
                self.absorb = Absorb::No;
            }
        }
    }

    fn needs_space(&self, next: &str) -> bool {
        let Some(last) = self.out.chars().last() else {
            return false;
        };
        let first = next.chars().next().unwrap_or(' ');
        !last.is_whitespace()
            && !matches!(last, '«' | '(')
            && !matches!(first, '.' | ',' | ';' | ':' | '!' | '?' | ')' | '»' | '…')
    }

    fn push_capitalized(&mut self, text: &str) {
        let mut chars = text.chars();
        match chars.next() {
            Some(first) if self.capitalize && first.is_lowercase() => {
                self.out.extend(first.to_uppercase());
                self.out.push_str(chars.as_str());
            }
            _ => self.out.push_str(text),
        }
        self.capitalize = false;
    }

    fn line_break(&mut self, breaks: &str) {
        self.trim_tail(&[',', ';']);
        self.out.push_str(breaks);
        self.join = Join::Glue;
        self.absorb = Absorb::Sentence;
        self.capitalize = true;
    }

    fn punctuation(&mut self, mark: char) {
        let terminal = matches!(mark, '.' | '?' | '!');
        if terminal {
            self.trim_tail(&['.', ',', ';', ':', '!', '?']);
        } else {
            self.trim_tail(&[',', ';', ':']);
        }
        self.out.push(mark);
        self.join = Join::Space;
        self.absorb = if terminal { Absorb::Sentence } else { Absorb::Light };
        self.capitalize = terminal;
    }

    fn dash(&mut self) {
        self.trim_tail(&[',', ';']);
        if !self.out.is_empty() && !self.out.ends_with('\n') {
            self.out.push(' ');
        }
        self.out.push('—');
        self.join = Join::Space;
        self.absorb = Absorb::Light;
    }

    fn open_quote(&mut self) {
        if let Some(last) = self.out.chars().last() {
            if !last.is_whitespace() && !matches!(last, '«' | '(') {
                self.out.push(' ');
            }
        }
        self.out.push('«');
        self.join = Join::Glue;
        self.absorb = Absorb::Light;
    }

    fn close_quote(&mut self) {
        self.trim_tail(&[',', ';']);
        self.out.push('»');
        self.join = Join::Space;
        self.absorb = Absorb::No;
    }

    fn after_deletion(&mut self) {
        self.join = if self.out.is_empty() || self.out.ends_with('\n') {
            Join::Glue
        } else {
            Join::Space
        };
        self.absorb = Absorb::Sentence;
        self.capitalize = self.ends_with_sentence_end();
    }

    fn delete_word(&mut self) {
        self.trim_tail(&[]);
        let end = self.out.trim_end_matches(char::is_whitespace).len();
        self.out.truncate(end);
        let terminal: Option<char> = self
            .out
            .chars()
            .last()
            .filter(|c| matches!(c, '.' | '!' | '?' | '…'));
        let start = self
            .out
            .rfind(char::is_whitespace)
            .map(|at| at + self.out[at..].chars().next().map_or(1, char::len_utf8))
            .unwrap_or(0);
        self.out.truncate(start);
        self.trim_tail(&[]);
        if let Some(mark) = terminal {
            if !self.out.is_empty() && !self.out.ends_with(['.', '!', '?', '…', '\n']) {
                self.out.push(mark);
            }
        }
        self.after_deletion();
    }

    fn delete_sentence(&mut self) {
        let kept = {
            let trimmed = self.out.trim_end_matches(char::is_whitespace);
            let body = trimmed.trim_end_matches(['.', '!', '?', '…']);
            let mut cut = 0;
            let mut chars = body.char_indices().peekable();
            while let Some((at, ch)) = chars.next() {
                let ends_sentence = match ch {
                    '\n' => true,
                    '.' | '!' | '?' | '…' => chars.peek().map_or(true, |(_, next)| next.is_whitespace()),
                    _ => false,
                };
                if ends_sentence {
                    cut = at + ch.len_utf8();
                }
            }
            body[..cut].to_string()
        };
        self.out = kept;
        self.trim_tail(&[]);
        self.after_deletion();
    }

    fn command(&mut self, command: Command) {
        match command {
            Command::NewLine => self.line_break("\n"),
            Command::NewParagraph => self.line_break("\n\n"),
            Command::Period => self.punctuation('.'),
            Command::Comma => self.punctuation(','),
            Command::Question => self.punctuation('?'),
            Command::Exclamation => self.punctuation('!'),
            Command::Colon => self.punctuation(':'),
            Command::Semicolon => self.punctuation(';'),
            Command::Dash => self.dash(),
            Command::OpenQuote => self.open_quote(),
            Command::CloseQuote => self.close_quote(),
            Command::DeleteWord => self.delete_word(),
            Command::DeleteSentence => self.delete_sentence(),
            Command::Send => {}
        }
    }

    fn finish_send(&mut self) {
        self.trim_tail(&[',', ';']);
        self.send = true;
    }
}

/// Nothing but spaces and sentence punctuation follows.
fn is_trailing(rest: &str) -> bool {
    rest.chars()
        .all(|c| c.is_whitespace() || matches!(c, '.' | ',' | ';' | ':' | '!' | '?' | '…'))
}

fn run(marked: &str) -> Processed {
    let mut builder = Builder::new();
    let mut rest = marked;
    loop {
        let Some(open) = rest.find(OPEN) else {
            builder.text(rest);
            break;
        };
        builder.text(&rest[..open]);
        let after = &rest[open + OPEN.len_utf8()..];
        let Some(close) = after.find(CLOSE) else {
            builder.text(after);
            break;
        };
        let inner = &after[..close];
        rest = &after[close + CLOSE.len_utf8()..];
        match lookup(inner) {
            Some(Command::Send) if is_trailing(rest) => {
                builder.finish_send();
                break;
            }
            Some(Command::Send) | None => builder.text(inner),
            Some(command) => builder.command(command),
        }
    }
    Processed {
        text: builder.out,
        send: builder.send,
    }
}

// ─── Sloppy brackets ────────────────────────────────────────────────

/// The longest command phrase of at most `MAX_PHRASE_WORDS` words that ends
/// `tail` (which must end in a word), as the byte offset where it starts.
fn phrase_ending(tail: &str) -> Option<usize> {
    let found = words(tail);
    if found.last()?.end != tail.len() {
        return None;
    }
    (1..=found.len().min(MAX_PHRASE_WORDS))
        .rev()
        .map(|count| found[found.len() - count].start)
        .find(|&start| lookup(&tail[start..]).is_some())
}

/// The longest command phrase at the start of `head`, as the byte offset where
/// it ends.
fn phrase_starting(head: &str) -> Option<usize> {
    let found = words(head);
    (1..=found.len().min(MAX_PHRASE_WORDS))
        .rev()
        .map(|count| found[count - 1].end)
        .find(|&end| lookup(&head[..end]).is_some())
}

const MAX_PHRASE_WORDS: usize = 4;

/// Models sometimes drop one bracket of a marker ("Как дела вопросительный
/// знак⟧", "⟦новая строка Как дела"). A stray closing bracket is paired with the
/// command phrase before it; a stray opening one (`close_open_tail`) with the
/// phrase after it. A bracket that cannot be paired is dropped.
fn repair_markers(text: &str, close_open_tail: bool) -> String {
    if !text.contains(OPEN) && !text.contains(CLOSE) {
        return text.to_string();
    }
    let mut out = String::with_capacity(text.len() + 4);
    let mut open_at: Option<usize> = None;
    for ch in text.chars() {
        match ch {
            OPEN => {
                if let Some(at) = open_at.take() {
                    close_or_drop(&mut out, at);
                }
                open_at = Some(out.len());
                out.push(OPEN);
            }
            CLOSE if open_at.is_some() => {
                open_at = None;
                out.push(CLOSE);
            }
            CLOSE => {
                let tail = out.trim_end();
                if let Some(start) = phrase_ending(tail) {
                    out.insert(start, OPEN);
                    out.push(CLOSE);
                }
            }
            _ => out.push(ch),
        }
    }
    if let Some(at) = open_at {
        if close_open_tail {
            close_or_drop(&mut out, at);
        }
    }
    out
}

/// `out[at]` is an opening bracket nobody closed: close it after the phrase that
/// follows, or remove it.
fn close_or_drop(out: &mut String, at: usize) {
    let after = at + OPEN.len_utf8();
    match phrase_starting(&out[after..]) {
        Some(end) => out.insert(after + end, CLOSE),
        None => {
            out.remove(at);
        }
    }
}

// ─── Commands spoken without brackets ───────────────────────────────

struct Word {
    start: usize,
    end: usize,
    normalized: String,
}

fn words(text: &str) -> Vec<Word> {
    let mut found = Vec::new();
    let mut start = None;
    for (at, ch) in text.char_indices() {
        match (ch.is_alphanumeric(), start) {
            (true, None) => start = Some(at),
            (false, Some(from)) => {
                found.push(Word {
                    start: from,
                    end: at,
                    normalized: normalize_phrase(&text[from..at]),
                });
                start = None;
            }
            _ => {}
        }
    }
    if let Some(from) = start {
        found.push(Word {
            start: from,
            end: text.len(),
            normalized: normalize_phrase(&text[from..]),
        });
    }
    found
}

fn bounded_before(text: &str, start: usize) -> bool {
    let before = text[..start].trim_end_matches([' ', '\t']);
    before.is_empty() || before.ends_with(['.', ',', ';', ':', '!', '?', '…', '\n', '—', '–', '«', '"', '('])
}

fn bounded_after(text: &str, end: usize) -> bool {
    let after = text[end..].trim_start_matches([' ', '\t']);
    after.is_empty() || after.starts_with(['.', ',', ';', ':', '!', '?', '…', '\n', '—', '–', '»', '"', ')'])
}

/// Wrap multi-word commands that make up a whole clause ("Привет, новая строка,
/// как дела") in markers. A command word inside a sentence is left alone, and
/// "отправь" never counts here.
fn mark_plain_commands(text: &str) -> String {
    let found = words(text);
    if found.is_empty() {
        return text.to_string();
    }
    let mut phrases: Vec<(Vec<&str>, Command)> = PHRASES
        .iter()
        .filter(|(_, command)| *command != Command::Send)
        .map(|(phrase, command)| (phrase.split(' ').collect::<Vec<_>>(), *command))
        .filter(|(parts, _)| parts.len() > 1)
        .collect();
    phrases.sort_by_key(|(parts, _)| std::cmp::Reverse(parts.len()));

    let mut out = String::with_capacity(text.len());
    let mut copied = 0;
    let mut i = 0;
    while i < found.len() {
        let hit = phrases.iter().find_map(|(parts, command)| {
            let span = found.get(i..i + parts.len())?;
            let same = span.iter().zip(parts).all(|(word, part)| word.normalized == *part);
            let joined = span.windows(2).all(|pair| {
                text[pair[0].end..pair[1].start]
                    .chars()
                    .all(|c| c == ' ' || c == '\t')
            });
            let (first, last) = (span.first()?, span.last()?);
            (same && joined && bounded_before(text, first.start) && bounded_after(text, last.end))
                .then_some((first.start, last.end, parts.len(), *command))
        });
        match hit {
            Some((start, end, count, command)) => {
                out.push_str(&text[copied..start]);
                out.push(OPEN);
                out.push_str(marker_phrase(command));
                out.push(CLOSE);
                copied = end;
                i += count;
            }
            None => i += 1,
        }
    }
    out.push_str(&text[copied..]);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(input: &str) -> String {
        process(input).text
    }

    #[test]
    fn plain_text_is_untouched() {
        for input in [
            "Привет, как дела?",
            "Это точка доступа.",
            "Поставь запятую в конце, пожалуйста.",
            "Нажми новая строка и всё.",
            "  пробелы  сохраняются ",
            "",
        ] {
            assert_eq!(process(input), Processed { text: input.into(), send: false });
        }
    }

    #[test]
    fn new_line_and_paragraph_markers() {
        assert_eq!(text("Привет ⟦новая строка⟧ Как дела"), "Привет\nКак дела");
        assert_eq!(text("Привет ⟦новый абзац⟧ как дела"), "Привет\n\nКак дела");
        assert_eq!(text("Раз ⟦new line⟧ два ⟦new paragraph⟧ три"), "Раз\nДва\n\nТри");
    }

    #[test]
    fn russian_morphology_and_case() {
        for form in [
            "новая строка",
            "Новую строку",
            "НОВОЙ СТРОКИ",
            "с новой строки",
            "на новую строку",
            "Перенос строки",
        ] {
            assert_eq!(text(&format!("Один ⟦{form}⟧ два")), "Один\nДва", "{form}");
        }
        for form in ["новый абзац", "С нового абзаца", "в новый абзац"] {
            assert_eq!(text(&format!("Один ⟦{form}⟧ два")), "Один\n\nДва", "{form}");
        }
        assert_eq!(text("Что ⟦Вопросительного знака⟧"), "Что?");
        assert_eq!(text("Что ⟦ знак вопроса ⟧"), "Что?");
        assert_eq!(text("Ура ⟦восклицательный  знак⟧"), "Ура!");
        assert_eq!(text("Запятая ⟦ЗАПЯТУЮ⟧ точка"), "Запятая, точка");
    }

    #[test]
    fn punctuation_commands_attach_to_the_word_before() {
        assert_eq!(text("Привет ⟦запятая⟧ как дела ⟦вопросительный знак⟧"), "Привет, как дела?");
        assert_eq!(text("Конец ⟦точка⟧ Следующее"), "Конец. Следующее");
        assert_eq!(text("Список ⟦двоеточие⟧ раз"), "Список: раз");
        assert_eq!(text("Слово ⟦тире⟧ слово"), "Слово — слово");
        assert_eq!(text("Вау ⟦восклицательный знак⟧"), "Вау!");
    }

    #[test]
    fn model_punctuation_around_a_marker_is_absorbed() {
        assert_eq!(text("Привет, ⟦запятая⟧, как дела?"), "Привет, как дела?");
        assert_eq!(text("Привет. ⟦новая строка⟧. Как дела?"), "Привет.\nКак дела?");
        assert_eq!(text("Как дела, ⟦вопросительный знак⟧."), "Как дела?");
        assert_eq!(text("Как дела. ⟦вопросительный знак⟧"), "Как дела?");
        assert_eq!(text("Раз, ⟦новая строка⟧, два"), "Раз\nДва");
    }

    #[test]
    fn quotes_open_and_close_around_the_words() {
        assert_eq!(
            text("Он сказал ⟦открыть кавычки⟧ привет мир ⟦закрыть кавычки⟧ и ушёл"),
            "Он сказал «привет мир» и ушёл"
        );
        assert_eq!(text("⟦открыть кавычки⟧Да⟦закрыть кавычки⟧."), "«Да».");
        assert_eq!(text("Say ⟦open quote⟧ hi ⟦close quote⟧"), "Say «hi»");
    }

    #[test]
    fn delete_last_word_edits_this_dictation() {
        assert_eq!(text("Один два три ⟦удали последнее слово⟧ четыре"), "Один два четыре");
        assert_eq!(text("Один два. ⟦удали последнее слово⟧"), "Один.");
        assert_eq!(text("Один ⟦удали последнее слово⟧ два"), "Два");
        assert_eq!(text("⟦удали последнее слово⟧ Привет"), "Привет");
        assert_eq!(text("Раз два ⟦Удалить последнее слово⟧ ⟦delete last word⟧ три"), "Три");
    }

    #[test]
    fn delete_last_sentence_edits_this_dictation() {
        assert_eq!(
            text("Первое. Второе предложение. ⟦удали последнее предложение⟧ Третье."),
            "Первое. Третье."
        );
        assert_eq!(text("Только одно. ⟦удали последнее предложение⟧"), "");
        assert_eq!(text("Раз. Два? Три ⟦удали последнее предложение⟧"), "Раз. Два?");
        assert_eq!(text("Версия 3.5 вышла. Нет ⟦удали последнее предложение⟧"), "Версия 3.5 вышла.");
        assert_eq!(
            text("Строка\nЕщё строка ⟦удали последнее предложение⟧ Новая"),
            "Строка\nНовая"
        );
    }

    #[test]
    fn send_only_counts_at_the_very_end() {
        assert_eq!(
            process("Привет, как дела? ⟦отправь⟧"),
            Processed { text: "Привет, как дела?".into(), send: true }
        );
        assert_eq!(
            process("Готово, ⟦отправить⟧."),
            Processed { text: "Готово".into(), send: true }
        );
        assert_eq!(
            process("Done ⟦send it⟧"),
            Processed { text: "Done".into(), send: true }
        );
        assert_eq!(
            process("⟦отправь⟧ мне файл"),
            Processed { text: "отправь мне файл".into(), send: false }
        );
    }

    #[test]
    fn unknown_or_broken_markers_keep_their_words() {
        assert_eq!(text("Это ⟦кот⟧ спит"), "Это кот спит");
        assert_eq!(text("Хвост ⟦новая"), "Хвост новая");
    }

    #[test]
    fn standalone_clauses_work_without_brackets() {
        assert_eq!(
            text("Привет, новая строка, как дела, вопросительный знак."),
            "Привет\nКак дела?"
        );
        assert_eq!(text("Привет. Новый абзац. Как дела?"), "Привет.\n\nКак дела?");
        assert_eq!(text("Привет, с новой строки"), "Привет\n");
        assert_eq!(text("Раз два. Удали последнее слово."), "Раз.");
        assert_eq!(text("Он сказал, открыть кавычки, привет, закрыть кавычки."), "Он сказал, «привет».");
    }

    #[test]
    fn command_words_inside_a_sentence_stay_words() {
        for input in [
            "Это называется новая строка в редакторе.",
            "Поставь вопросительный знак после слова.",
            "Используй новый абзац для разделения.",
            "Кнопка удали последнее слово не работает.",
        ] {
            assert_eq!(text(input), input);
        }
    }

    #[test]
    fn single_words_need_a_marker() {
        assert_eq!(text("Привет, точка, как дела"), "Привет, точка, как дела");
        assert_eq!(text("Привет, запятая."), "Привет, запятая.");
        assert_eq!(text("Привет ⟦запятая⟧ дела"), "Привет, дела");
    }

    #[test]
    fn plain_send_is_never_a_command() {
        assert_eq!(
            process("Пожалуйста, отправь."),
            Processed { text: "Пожалуйста, отправь.".into(), send: false }
        );
    }

    #[test]
    fn a_dropped_bracket_is_repaired() {
        assert_eq!(
            text("Привет ⟦новая строка⟧ Как дела вопросительный знак⟧"),
            "Привет\nКак дела?"
        );
        assert_eq!(text("Привет ⟦новая строка Как дела"), "Привет\nКак дела");
        assert_eq!(text("Привет ⟦запятая как дела ⟦вопросительный знак⟧"), "Привет, как дела?");
        assert_eq!(text("Привет⟧ мир"), "Привет мир");
        assert_eq!(text("Привет ⟦ мир"), "Привет  мир");
        assert_eq!(
            process("Готово ⟦отправь"),
            Processed { text: "Готово".into(), send: true }
        );
        assert_eq!(text("Раз два запятая⟧ три"), "Раз два, три");
    }

    #[test]
    fn markers_inside_brackets_are_not_matched_twice() {
        assert_eq!(text("Раз ⟦новая строка⟧ два"), "Раз\nДва");
    }

    #[test]
    fn streaming_holds_back_an_unfinished_marker() {
        assert_eq!(process_streaming("Привет ⟦нов"), "Привет");
        assert_eq!(process_streaming("Привет ⟦новая строка⟧ Ка"), "Привет\nКа");
        assert_eq!(process_streaming("Привет ⟦"), "Привет");
        assert_eq!(process_streaming("Привет "), "Привет");
        assert_eq!(process_streaming("Привет"), "Привет");
        assert_eq!(process_streaming("Привет, новая строка, как"), "Привет, новая строка, как");
    }

    #[test]
    fn streamed_text_converges_to_the_final_text() {
        let full = "Привет ⟦запятая⟧ мир ⟦новая строка⟧ дела ⟦вопросительный знак⟧";
        let mut seen = String::new();
        for ch in full.chars() {
            seen.push(ch);
            let _ = process_streaming(&seen);
        }
        assert_eq!(process_streaming(&seen), process(full).text);
    }

    #[test]
    fn capitalisation_follows_line_breaks_and_sentence_marks() {
        assert_eq!(text("раз ⟦точка⟧ два ⟦новая строка⟧ три"), "раз. Два\nТри");
        assert_eq!(text("раз ⟦запятая⟧ два"), "раз, два");
    }

    #[test]
    fn consecutive_line_breaks_stack() {
        assert_eq!(text("Раз ⟦новая строка⟧ ⟦новая строка⟧ два"), "Раз\n\nДва");
    }
}
