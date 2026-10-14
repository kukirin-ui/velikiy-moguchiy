//! Types dictated text into the focused field while the session runs: either the
//! running transcript (live insert) or the Omni reply as it streams in (stream
//! insert).
//!
//! A worker thread owns the keystrokes: callers only hand it the newest target
//! text, and it diffs against what it typed so far (backspaces for the changed
//! tail, then the new tail). Targets that arrive while it is typing replace each
//! other, so the ASR event loop never waits on the keyboard.
//!
//! Safety rules, because Backspace destroys text the user wrote:
//! - The focused UI element is captured when the session starts; once another
//!   element has focus nothing is sent, ever (`FocusAnchor`, compared with
//!   `CFEqual`, not just the app pid).
//! - Before a Backspace-based edit the text before the caret is compared with
//!   what we believe we typed (when the app exposes `AXValue`); a mismatch (app
//!   autocorrect, smart quotes, dropped keystrokes) stops live typing.
//! - `typed` counts exactly the chars that reached the field, also when a
//!   keystroke fails midway.
//! - If the final text cannot be reached, the draft is erased when that is safe
//!   and the full text pasted; otherwise only the missing remainder is pasted, or
//!   the text goes to the clipboard. The full text is never pasted on top of a
//!   partial draft.

use crate::commands;
use crate::unicode_typing::{self, FocusAnchor, NewlineMode, Partial, Verdict};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

const FINISH_TIMEOUT: Duration = Duration::from_secs(30);
/// How long a worker that was told to give up gets to leave its current call.
const ABANDON_GRACE: Duration = Duration::from_secs(2);
const FINISH_POLL: Duration = Duration::from_millis(15);

#[derive(Debug, PartialEq, Eq)]
pub struct Edit {
    pub backspaces: usize,
    pub tail: String,
}

/// Keystrokes that turn `typed` into `target`: erase everything after the common
/// prefix (counted in chars), then type the rest of `target`.
pub fn plan_edit(typed: &str, target: &str) -> Edit {
    let common = typed
        .chars()
        .zip(target.chars())
        .take_while(|(a, b)| a == b)
        .count();
    Edit {
        backspaces: typed.chars().count() - common,
        tail: target.chars().skip(common).collect(),
    }
}

/// `type_unicode_chunk` drops carriage returns, so they must not be counted as typed.
fn normalize(text: &str) -> String {
    text.chars().filter(|&c| c != '\r').collect()
}

/// How the final text reaches the user once typing is over.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Delivery {
    /// The field holds the final text; nothing to paste. Carries its char count.
    Typed(usize),
    /// Nothing usable is in the field: paste the full text as usual.
    PasteAll,
    /// A prefix of the text is in the field and cannot be removed safely: paste
    /// only what is missing.
    PasteRemainder(String),
    /// A draft sits where we cannot reach it (focus moved, or it diverged from
    /// the text): put the text on the clipboard and paste nothing.
    ClipboardOnly,
    /// The session was cancelled and the draft erased; there is nothing to deliver.
    Cancelled,
}

/// What to do with `target` when typing stopped with `typed` in the field.
/// `erased` says the draft was removed again; `same_place` that the focused
/// element is still the one the draft is in.
pub fn plan_fallback(typed: &str, target: &str, erased: bool, same_place: bool) -> Delivery {
    if erased || typed.is_empty() {
        return Delivery::PasteAll;
    }
    if !same_place {
        return Delivery::ClipboardOnly;
    }
    match target.strip_prefix(typed) {
        Some("") => Delivery::Typed(target.chars().count()),
        Some(rest) => Delivery::PasteRemainder(rest.to_string()),
        None => Delivery::ClipboardOnly,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    /// Mirror the running transcript (`update`).
    Live,
    /// Type the Omni reply as it streams in (`append`).
    Stream,
}

struct State {
    mode: Mode,
    pending: Option<String>,
    /// Stream mode: everything received so far.
    streamed: String,
    /// Exactly the chars that are in the field because of us.
    typed: String,
    /// Focus moved or typing failed: no more edits this session.
    stopped: bool,
    /// Cancelled: erase what was typed and exit.
    erase: bool,
    /// No more targets will come; settle on `final_text` and exit.
    closing: bool,
    final_text: Option<String>,
    send_return: bool,
    delivery: Option<Delivery>,
    done: bool,
}

struct Shared {
    token: u64,
    anchor: FocusAnchor,
    /// How newlines are typed, fixed for the session from the frontmost app.
    newline: NewlineMode,
    /// Stream mode: spoken command markers in the reply are applied as it arrives.
    voice_commands: bool,
    state: Mutex<State>,
    wake: Condvar,
    /// Stops keystroke loops (cancel, give-up after a timeout).
    halt: AtomicBool,
    /// `finish` gave up waiting: the worker must leave without touching the field.
    abandoned: AtomicBool,
}

static CURRENT: Mutex<Option<Arc<Shared>>> = Mutex::new(None);

/// The Accessibility groundwork for typing into the focused field. Gathered
/// before the global core lock is taken, because the target app may be slow to
/// answer.
pub struct Prepared {
    anchor: FocusAnchor,
    newline: NewlineMode,
}

/// Check that keystrokes can reach the focused app and remember its focused
/// element. `bundle_id` is the app that was frontmost when the session began; it
/// decides how newlines are typed (terminals must not receive Shift+Return).
/// Does Accessibility calls; never hold a lock around it.
pub fn prepare(bundle_id: Option<&str>) -> Option<Prepared> {
    if let Err(e) = unicode_typing::check_typing_available() {
        log::info!("typing into the field unavailable: {e:?}");
        return None;
    }
    let Some(anchor) = FocusAnchor::capture() else {
        log::info!("typing into the field unavailable: no focused app");
        return None;
    };
    let newline = NewlineMode::for_bundle_id(bundle_id);
    Some(Prepared { anchor, newline })
}

/// Start the typing worker for the session. Cheap and lock-friendly: no
/// Accessibility calls. `voice_commands`: the reply may carry `⟦…⟧` command
/// markers that must not reach the field as typed.
pub fn start(token: u64, mode: Mode, prepared: Prepared, voice_commands: bool) -> bool {
    let pid = prepared.anchor.pid();
    let newline = prepared.newline;
    let shared = Arc::new(Shared {
        token,
        anchor: prepared.anchor,
        newline: prepared.newline,
        voice_commands,
        state: Mutex::new(State {
            mode,
            pending: None,
            streamed: String::new(),
            typed: String::new(),
            stopped: false,
            erase: false,
            closing: false,
            final_text: None,
            send_return: false,
            delivery: None,
            done: false,
        }),
        wake: Condvar::new(),
        halt: AtomicBool::new(false),
        abandoned: AtomicBool::new(false),
    });
    let worker = shared.clone();
    if std::thread::Builder::new()
        .name("velikiy-moguchiy-live-insert".into())
        .spawn(move || run_worker(&worker))
        .is_err()
    {
        return false;
    }
    *CURRENT.lock().unwrap() = Some(shared);
    log::info!("typing into the field started ({mode:?}, pid {pid}, newline {newline:?})");
    true
}

/// Offer the newest preview text; it replaces any target not yet applied.
pub fn update(token: u64, text: &str) {
    let Some(shared) = current_for(token) else {
        return;
    };
    let target = normalize(text);
    if target.is_empty() {
        return;
    }
    let mut st = shared.state.lock().unwrap();
    if st.mode != Mode::Live || st.stopped || st.closing || st.erase {
        return;
    }
    let unchanged = match &st.pending {
        Some(pending) => *pending == target,
        None => st.typed == target,
    };
    if !unchanged {
        st.pending = Some(target);
        shared.wake.notify_all();
    }
}

/// Stream mode: add a chunk of the reply to what should be in the field.
pub fn append(token: u64, delta: &str) {
    let Some(shared) = current_for(token) else {
        return;
    };
    let mut st = shared.state.lock().unwrap();
    if st.mode != Mode::Stream || st.stopped || st.closing || st.erase {
        return;
    }
    st.streamed.push_str(&normalize(delta));
    if st.streamed.is_empty() {
        return;
    }
    let target = if shared.voice_commands {
        commands::process_streaming(&st.streamed)
    } else {
        st.streamed.clone()
    };
    st.pending = Some(target);
    shared.wake.notify_all();
}

/// Bring the field to `final_text` and end typing. `press_return` sends a
/// Return afterwards (still guarded by the focus check). The result says how the
/// text reaches the user.
pub async fn finish(token: u64, final_text: &str, press_return: bool) -> Delivery {
    let Some(shared) = current_for(token) else {
        return Delivery::PasteAll;
    };
    let target = normalize(final_text);
    {
        let mut st = shared.state.lock().unwrap();
        if !st.stopped && !st.erase && !target.is_empty() {
            st.pending = Some(target.clone());
        }
        st.final_text = Some(target.clone());
        st.send_return = press_return;
        st.closing = true;
        shared.wake.notify_all();
    }
    let deadline = Instant::now() + FINISH_TIMEOUT;
    let mut finished = true;
    while !shared.state.lock().unwrap().done {
        if Instant::now() >= deadline {
            log::warn!("typing did not finish in time; telling the worker to give up");
            shared.abandoned.store(true, Ordering::SeqCst);
            shared.halt.store(true, Ordering::SeqCst);
            shared.wake.notify_all();
            finished = false;
            break;
        }
        tokio::time::sleep(FINISH_POLL).await;
    }
    if !finished {
        // The worker leaves at its next keystroke or when its current
        // Accessibility call returns; give it a moment to settle `typed`.
        let grace = Instant::now() + ABANDON_GRACE;
        while !shared.state.lock().unwrap().done && Instant::now() < grace {
            tokio::time::sleep(FINISH_POLL).await;
        }
    }
    let delivery = {
        let st = shared.state.lock().unwrap();
        match (&st.delivery, st.done) {
            (Some(delivery), true) => delivery.clone(),
            // Timed out: the draft cannot be touched any more and whether focus
            // is still on it is unknown, so a leftover draft means "clipboard".
            _ => plan_fallback(&st.typed, &target, false, false),
        }
    };
    let mut current = CURRENT.lock().unwrap();
    if current.as_ref().is_some_and(|s| s.token == token) {
        current.take();
    }
    delivery
}

/// Erase what typing put in the field (if it is still safe) and stop.
pub fn cancel() {
    if let Some(shared) = CURRENT.lock().unwrap().take() {
        request_erase(&shared);
    }
}

/// Like `cancel`, for the session with `token` only.
pub fn abort(token: u64) {
    let shared = {
        let mut current = CURRENT.lock().unwrap();
        if current.as_ref().is_some_and(|s| s.token == token) {
            current.take()
        } else {
            None
        }
    };
    if let Some(shared) = shared {
        request_erase(&shared);
    }
}

fn request_erase(shared: &Shared) {
    let mut st = shared.state.lock().unwrap();
    st.pending = None;
    st.erase = true;
    shared.halt.store(true, Ordering::SeqCst);
    shared.wake.notify_all();
}

fn current_for(token: u64) -> Option<Arc<Shared>> {
    CURRENT
        .lock()
        .unwrap()
        .as_ref()
        .filter(|s| s.token == token)
        .cloned()
}

fn run_worker(shared: &Shared) {
    let mut st = shared.state.lock().unwrap();
    loop {
        while !st.erase
            && !st.closing
            && st.pending.is_none()
            && !shared.abandoned.load(Ordering::SeqCst)
        {
            st = shared.wake.wait(st).unwrap();
        }
        if shared.abandoned.load(Ordering::SeqCst) {
            break;
        }
        if st.erase {
            drop(st);
            let _ = erase_draft(shared);
            st = shared.state.lock().unwrap();
            st.delivery = Some(Delivery::Cancelled);
            break;
        }
        if st.stopped && st.pending.is_some() {
            // A target that arrived while the last edit was failing.
            st.pending = None;
            continue;
        }
        if let Some(target) = st.pending.take() {
            drop(st);
            let stopped = apply(shared, &target);
            st = shared.state.lock().unwrap();
            st.stopped |= stopped;
            continue;
        }
        // Closing with nothing left to apply.
        drop(st);
        let delivery = settle(shared);
        st = shared.state.lock().unwrap();
        st.delivery = Some(delivery);
        break;
    }
    st.done = true;
}

fn typed_snapshot(shared: &Shared) -> String {
    shared.state.lock().unwrap().typed.clone()
}

fn stop(shared: &Shared, why: &str) -> bool {
    log::info!("typing stopped: {why}");
    shared.state.lock().unwrap().stopped = true;
    true
}

/// Type the difference between what is in the field and `target`. Returns
/// whether typing must stop.
fn apply(shared: &Shared, target: &str) -> bool {
    let typed = typed_snapshot(shared);
    let edit = plan_edit(&typed, target);
    // Focus is always checked. The text before the caret is only compared with
    // `typed` when something is about to be deleted; appending cannot destroy
    // anything the user wrote.
    let expected = if edit.backspaces > 0 { typed.as_str() } else { "" };
    match shared.anchor.verify(expected, &shared.halt) {
        Verdict::Ok => {}
        Verdict::FocusMoved => return stop(shared, "focus moved to another field"),
        Verdict::TextMismatch => {
            return stop(shared, "the text before the caret differs from what was typed")
        }
    }
    if shared.abandoned.load(Ordering::SeqCst) || shared.halt.load(Ordering::SeqCst) {
        return true;
    }
    if edit.backspaces > 0 {
        if let Err(partial) = backspace(shared, edit.backspaces) {
            log::warn!("typing stopped: {:?}", partial.error);
            return true;
        }
    }
    match type_text(shared, &edit.tail) {
        Ok(()) => false,
        Err(partial) => {
            log::warn!("typing stopped: {:?}", partial.error);
            true
        }
    }
}

fn backspace(shared: &Shared, count: usize) -> Result<(), Partial> {
    unicode_typing::press_backspace(count, &shared.halt, &mut || {
        shared.state.lock().unwrap().typed.pop();
    })
}

fn type_text(shared: &Shared, text: &str) -> Result<(), Partial> {
    unicode_typing::type_unicode_chunk(text, shared.newline, &shared.halt, &mut |ch| {
        shared.state.lock().unwrap().typed.push(ch);
    })
    .map(|_| ())
}

enum Erase {
    /// The draft is gone (or there was none).
    Done,
    /// Another element has focus; the draft is out of reach.
    FocusMoved,
    /// Left in place: the field no longer provably holds the draft, or erasing failed.
    Left,
}

/// Remove the draft if the field provably still holds it.
fn erase_draft(shared: &Shared) -> Erase {
    let typed = typed_snapshot(shared);
    if typed.is_empty() {
        return Erase::Done;
    }
    // Cancel sets `halt` to cut a running keystroke loop short; the erase itself
    // must still run, so only a give-up (`abandoned`) interrupts it.
    match shared.anchor.verify(&typed, &shared.abandoned) {
        Verdict::Ok => {}
        Verdict::FocusMoved => {
            log::info!("draft left in place: focus moved");
            return Erase::FocusMoved;
        }
        Verdict::TextMismatch => {
            log::info!("draft left in place: the field no longer holds it");
            return Erase::Left;
        }
    }
    if shared.abandoned.load(Ordering::SeqCst) {
        return Erase::Left;
    }
    let count = typed.chars().count();
    let result = unicode_typing::press_backspace(count, &shared.abandoned, &mut || {
        shared.state.lock().unwrap().typed.pop();
    });
    match result {
        Ok(()) => Erase::Done,
        Err(partial) => {
            log::warn!("erasing the draft failed: {:?}", partial.error);
            Erase::Left
        }
    }
}

/// Closing step: confirm the field holds the final text, or recover.
fn settle(shared: &Shared) -> Delivery {
    let (typed, stopped, target, send_return) = {
        let st = shared.state.lock().unwrap();
        (
            st.typed.clone(),
            st.stopped,
            st.final_text.clone().unwrap_or_default(),
            st.send_return,
        )
    };
    if !stopped && !target.is_empty() && typed == target {
        if send_return {
            send_return_if_focused(shared);
        }
        return Delivery::Typed(target.chars().count());
    }

    // Typing did not reach the final text. Prefer a clean field plus a normal
    // paste of everything; that needs focus and the draft to be verified intact.
    let mut erased = false;
    let mut same_place = true;
    match erase_draft(shared) {
        Erase::Done => erased = !typed.is_empty(),
        Erase::FocusMoved => same_place = false,
        Erase::Left => {}
    }
    if target.is_empty() {
        // Nothing to deliver after all; whatever remains stays as the user's.
        return Delivery::Cancelled;
    }
    plan_fallback(&typed_snapshot(shared), &target, erased, same_place)
}

fn send_return_if_focused(shared: &Shared) {
    if shared.abandoned.load(Ordering::SeqCst) || shared.halt.load(Ordering::SeqCst) {
        return;
    }
    match shared.anchor.verify("", &shared.abandoned) {
        Verdict::Ok => {
            if let Err(e) = unicode_typing::press_return() {
                log::warn!("auto Return failed: {e:?}");
            }
        }
        other => log::info!("auto Return skipped ({other:?})"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn edit(backspaces: usize, tail: &str) -> Edit {
        Edit {
            backspaces,
            tail: tail.to_string(),
        }
    }

    #[test]
    fn appends_when_target_extends_typed() {
        assert_eq!(plan_edit("привет", "привет как"), edit(0, " как"));
    }

    #[test]
    fn punctuation_rewrites_the_tail() {
        assert_eq!(
            plan_edit("привет как", "привет, как дела"),
            edit(4, ", как дела")
        );
    }

    #[test]
    fn identical_text_needs_nothing() {
        assert_eq!(plan_edit("привет", "привет"), edit(0, ""));
    }

    #[test]
    fn shorter_target_only_erases() {
        assert_eq!(plan_edit("привет мир", "привет"), edit(4, ""));
    }

    #[test]
    fn empty_typed_types_everything() {
        assert_eq!(plan_edit("", "да"), edit(0, "да"));
    }

    #[test]
    fn full_rewrite_erases_everything() {
        assert_eq!(plan_edit("abc", "xyz"), edit(3, "xyz"));
    }

    #[test]
    fn counts_chars_not_bytes() {
        assert_eq!(plan_edit("ёж", "ёлка"), edit(1, "лка"));
    }

    #[test]
    fn carriage_returns_are_dropped() {
        assert_eq!(normalize("а\r\nб"), "а\nб");
    }

    #[test]
    fn nothing_typed_pastes_everything() {
        assert_eq!(plan_fallback("", "привет", false, true), Delivery::PasteAll);
        assert_eq!(plan_fallback("", "привет", false, false), Delivery::PasteAll);
    }

    #[test]
    fn erased_draft_pastes_everything() {
        assert_eq!(
            plan_fallback("прив", "привет", true, true),
            Delivery::PasteAll
        );
    }

    #[test]
    fn surviving_prefix_pastes_only_the_remainder() {
        assert_eq!(
            plan_fallback("привет, ка", "привет, как дела", false, true),
            Delivery::PasteRemainder("к дела".into())
        );
    }

    #[test]
    fn diverged_draft_goes_to_the_clipboard() {
        // The draft is not a prefix of the final text (live preview was rewritten).
        assert_eq!(
            plan_fallback("привет как", "Привет, как дела", false, true),
            Delivery::ClipboardOnly
        );
    }

    #[test]
    fn draft_in_another_field_goes_to_the_clipboard() {
        assert_eq!(
            plan_fallback("прив", "привет", false, false),
            Delivery::ClipboardOnly
        );
    }

    #[test]
    fn complete_draft_is_delivered() {
        assert_eq!(
            plan_fallback("привет", "привет", false, true),
            Delivery::Typed(6)
        );
    }

    #[test]
    fn remainder_is_taken_in_chars_not_bytes() {
        assert_eq!(
            plan_fallback("ёж", "ёжик", false, true),
            Delivery::PasteRemainder("ик".into())
        );
    }

    fn state(mode: Mode) -> State {
        State {
            mode,
            pending: None,
            streamed: String::new(),
            typed: String::new(),
            stopped: false,
            erase: false,
            closing: false,
            final_text: None,
            send_return: false,
            delivery: None,
            done: false,
        }
    }

    #[test]
    fn typed_length_tracks_progress_callbacks() {
        // Mirrors the closures the worker passes to the typing primitives: the
        // counter follows every key that went out, including on a partial run.
        let mut st = state(Mode::Live);
        for ch in "привет".chars() {
            st.typed.push(ch);
        }
        for _ in 0..2 {
            st.typed.pop();
        }
        assert_eq!(st.typed, "прив");
        assert_eq!(st.typed.chars().count(), 4);
        // A failed run after 3 of 5 tail chars leaves exactly those 3 typed.
        for ch in "етик".chars().take(3) {
            st.typed.push(ch);
        }
        assert_eq!(st.typed, "привети");
        assert_eq!(
            plan_fallback(&st.typed, "приветик", false, true),
            Delivery::PasteRemainder("к".into())
        );
    }
}
