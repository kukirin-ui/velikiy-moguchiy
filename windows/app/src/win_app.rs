//! The program on Windows: the keyboard hook, tray icon, overlay, microphone
//! and settings window wired around the controller and the core.
//!
//! Everything that happens elsewhere (hook, core threads, microphone thread,
//! settings window) is queued as an [`AppEvent`] and handled on the UI thread
//! when the shell wakes up, so no handler ever runs inside another.

use std::cell::RefCell;
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::Instant;
use velikiy_moguchiy_core::config;
use velikiy_moguchiy_win32::form::{Field, Form, FormEvent, Value};
use velikiy_moguchiy_win32::hook::{KeyEvent, KeyboardHook};
#[cfg(not(feature = "smoke"))]
use velikiy_moguchiy_win32::mic::Mic;
use velikiy_moguchiy_win32::overlay::{self, Overlay};
use velikiy_moguchiy_win32::shell::{self, MenuItem, Shell, ShellEvent, Waker};
use velikiy_moguchiy_win32::tray::Tray;
use velikiy_moguchiy_win32::{clipboard, input, window};
use velikiy_moguchiy_windows::app_id::app_id_for_exe;
use velikiy_moguchiy_windows::audio::{Framer, Resampler, FRAME_SAMPLES};
use velikiy_moguchiy_windows::controller::{Controller, Host, OverlayMode, OverlayView, Target};
use velikiy_moguchiy_windows::core_bridge::{self, BridgeEvent, DownloadEvent};
use velikiy_moguchiy_windows::hotkey::{Gesture, HotkeyFilter, TriggerKey, TriggerMode};
use velikiy_moguchiy_windows::keys::{self, Vault};
use velikiy_moguchiy_windows::logfile;
use velikiy_moguchiy_windows::settings::{
    self, Settings, LANGUAGES, PROVIDER_LOCAL, PROVIDER_QWEN, QWEN_MODELS,
};

#[cfg(feature = "smoke")]
use crate::smoke::FakeMic as Mic;

const APP_NAME: &str = "«Великий & Могучий»";
const TIMER_TICK: usize = 1;
const TICK_MS: u32 = 33;
const VK_RMENU: u32 = 0xA5;

const MENU_SETTINGS: u32 = 1;
const MENU_DATA_FOLDER: u32 = 2;
const MENU_LOG: u32 = 3;
const MENU_QUIT: u32 = 9;

/// Field indices of the settings window, in the order they are built.
const F_PROVIDER: usize = 0;
const F_KEY: usize = 1;
const F_MODEL: usize = 2;
const F_LANGUAGE: usize = 3;
const F_TRIGGER: usize = 4;
const F_MODE: usize = 5;
const F_STATUS: usize = 6;
/// Only in builds with local recognition.
const F_DOWNLOAD: usize = 7;

/// Local recognition is compiled in (the `sherpa-onnx` feature).
const LOCAL: bool = cfg!(feature = "sherpa-onnx");

enum AppEvent {
    Gesture(Gesture),
    Bridge(BridgeEvent),
    MicFailed(String),
    Form(FormEvent),
}

#[derive(Clone)]
struct Queue {
    tx: Sender<AppEvent>,
    waker: Waker,
}

impl Queue {
    fn send(&self, event: AppEvent) {
        if self.tx.send(event).is_ok() {
            self.waker.wake();
        }
    }
}

/// Microphone samples to core frames. Shared with the microphone thread.
struct AudioPipe {
    resampler: Option<(Resampler, u32, u16)>,
    framer: Framer,
    pcm: Vec<i16>,
}

impl AudioPipe {
    fn new() -> Self {
        Self {
            resampler: None,
            framer: Framer::new(FRAME_SAMPLES),
            pcm: Vec::new(),
        }
    }

    fn push(&mut self, samples: &[f32], rate: u32, channels: u16) {
        let fresh = !matches!(&self.resampler, Some((_, r, c)) if *r == rate && *c == channels);
        if fresh {
            self.resampler = Some((Resampler::new(rate, channels), rate, channels));
        }
        let Some((resampler, _, _)) = self.resampler.as_mut() else {
            return;
        };
        self.pcm.clear();
        resampler.process(samples, &mut self.pcm);
        core_bridge::feed_levels(&self.pcm);
        self.framer.push(&self.pcm, core_bridge::push_audio);
    }

    fn flush(&mut self) {
        self.framer.flush(core_bridge::push_audio);
        self.resampler = None;
    }
}

enum Later {
    PressReturn,
    /// Put the user's text back unless the clipboard changed since the paste.
    RestoreClipboard {
        pasted: String,
        previous: String,
    },
}

struct WinHost {
    overlay: Overlay,
    tray: Tray,
    filter: Arc<Mutex<HotkeyFilter>>,
    mic: Option<Mic>,
    pipe: Arc<Mutex<AudioPipe>>,
    queue: Queue,
    later: Vec<(u64, Later)>,
    now_ms: u64,
}

impl WinHost {
    fn run_due(&mut self) {
        let now = self.now_ms;
        let (due, rest): (Vec<_>, Vec<_>) = self.later.drain(..).partition(|(t, _)| *t <= now);
        self.later = rest;
        for (_, action) in due {
            match action {
                Later::PressReturn => {
                    input::press_return();
                }
                Later::RestoreClipboard { pasted, previous } => {
                    if clipboard::text().as_deref() == Some(pasted.as_str()) {
                        clipboard::set_text(&previous, false);
                    }
                }
            }
        }
    }

    fn tooltip(recording: bool) -> String {
        if recording {
            format!("{APP_NAME} — запись")
        } else {
            APP_NAME.to_string()
        }
    }
}

impl Host for WinHost {
    fn begin_session(&mut self, token: u64, hands_free: bool, app_id: Option<&str>) -> bool {
        core_bridge::begin_session(token, hands_free, app_id)
    }

    fn end_session(&mut self) {
        core_bridge::end_session();
    }

    fn cancel_session(&mut self) {
        core_bridge::cancel_session();
    }

    fn start_mic(&mut self) -> Result<(), String> {
        if let Some(mic) = self.mic.take() {
            mic.stop();
        }
        core_bridge::reset_mic_levels();
        *self.pipe.lock().unwrap_or_else(|e| e.into_inner()) = AudioPipe::new();
        let pipe = self.pipe.clone();
        let queue = self.queue.clone();
        let mic = Mic::start(
            Box::new(move |samples, rate, channels| {
                pipe.lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .push(samples, rate, channels);
            }),
            Box::new(move |e| queue.send(AppEvent::MicFailed(e))),
        )?;
        self.mic = Some(mic);
        Ok(())
    }

    fn stop_mic(&mut self) {
        if let Some(mic) = self.mic.take() {
            mic.stop();
            self.pipe.lock().unwrap_or_else(|e| e.into_inner()).flush();
        }
    }

    fn arm_silence_stop(&mut self, on: bool) {
        core_bridge::arm_silence_stop(on);
    }

    fn silence_stop_fired(&mut self) -> bool {
        core_bridge::silence_stop_fired()
    }

    fn foreground(&mut self) -> Option<Target> {
        window::foreground().map(|fg| Target {
            window: fg.window,
            app_id: fg.exe.as_deref().and_then(app_id_for_exe),
        })
    }

    fn paste(&mut self, text: &str, press_return: bool) {
        let restore = core_bridge::clipboard_restore_delay_ms();
        let previous = restore.and_then(|_| clipboard::text());
        if !clipboard::set_text(text, true) {
            log::warn!("could not put the text on the clipboard");
            return;
        }
        if !input::paste() {
            log::warn!("Ctrl+V was blocked (an elevated window has the focus?)");
        }
        if press_return {
            self.later.push((self.now_ms + 120, Later::PressReturn));
        }
        if let (Some(delay), Some(previous)) = (restore, previous) {
            self.later.push((
                self.now_ms + u64::from(delay.max(300)),
                Later::RestoreClipboard {
                    pasted: text.to_string(),
                    previous,
                },
            ));
        }
    }

    fn copy(&mut self, text: &str) {
        clipboard::set_text(text, false);
    }

    fn show_overlay(&mut self, view: &OverlayView) {
        let mode = match view.mode {
            OverlayMode::Listening => overlay::Mode::Listening,
            OverlayMode::Recognizing | OverlayMode::Correcting => overlay::Mode::Busy,
            OverlayMode::Result => overlay::Mode::Result,
            OverlayMode::Notice => overlay::Mode::Notice,
            OverlayMode::Error => overlay::Mode::Error,
        };
        let text = match (view.mode, view.text.is_empty()) {
            (OverlayMode::Correcting, true) => "Исправляю…".to_string(),
            _ => view.text.clone(),
        };
        let hint = match view.mode {
            OverlayMode::Listening if view.hands_free => "Esc — отмена, клавиша — готово",
            OverlayMode::Listening => "Esc — отмена",
            _ => "",
        };
        self.overlay.show(overlay::Content {
            mode,
            text,
            hint: hint.to_string(),
            levels: [0.0; 16],
        });
    }

    fn hide_overlay(&mut self) {
        self.overlay.hide();
    }

    fn set_tray_recording(&mut self, recording: bool) {
        self.tray
            .set_recording(recording, &Self::tooltip(recording));
    }

    fn reset_hotkey(&mut self) {
        self.filter
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .reset();
    }

    fn setup_problem(&mut self) -> Option<String> {
        let s = Settings::load(&Dpapi);
        if let Some(problem) = s.problem() {
            return Some(problem.to_string());
        }
        if s.provider == PROVIDER_LOCAL && !LOCAL {
            return Some(
                "В этой сборке нет локального распознавания: выберите Qwen в настройках.".into(),
            );
        }
        if s.provider == PROVIDER_LOCAL && core_bridge::model_status(&local_model()) != 2 {
            return Some(
                "Локальная модель ещё не скачана: откройте настройки в меню значка в трее.".into(),
            );
        }
        None
    }

    fn config_flag(&mut self, key: &str) -> bool {
        core_bridge::config_flag(key)
    }
}

/// Keys sealed for the current Windows user.
struct Dpapi;

impl Vault for Dpapi {
    fn seal(&self, plain: &[u8]) -> Result<Vec<u8>, String> {
        velikiy_moguchiy_win32::secret::protect(plain)
    }

    fn open(&self, sealed: &[u8]) -> Result<Vec<u8>, String> {
        velikiy_moguchiy_win32::secret::unprotect(sealed)
    }
}

/// The sherpa-onnx model the local mode uses or will use.
fn local_model() -> String {
    let configured = config::config_get(settings::KEY_LOCAL_MODEL).unwrap_or_default();
    if configured.trim().is_empty() || configured == "sherpa-onnx/bilingual-zh-en" {
        settings::LOCAL_MODEL.to_string()
    } else {
        configured
    }
}

fn local_status_text() -> String {
    match core_bridge::model_status(&local_model()) {
        2 => "Локальная модель скачана.".into(),
        1 => "Локальная модель скачана не полностью — скачайте ещё раз.".into(),
        _ => "Локальная модель не скачана (около 340 МБ).".into(),
    }
}

struct SettingsWindow {
    form: Form,
    before: Settings,
    /// Model ids offered in the picker, in picker order.
    models: Vec<String>,
    languages: Vec<String>,
    providers: Vec<String>,
}

struct App {
    shell: Shell,
    controller: Controller,
    host: WinHost,
    events: Receiver<AppEvent>,
    settings_window: Option<SettingsWindow>,
    downloading: bool,
    ticking: bool,
    started: Instant,
    _hook: KeyboardHook,
}

impl App {
    fn now_ms(&self) -> u64 {
        self.started.elapsed().as_millis() as u64
    }

    fn on_shell(&mut self, event: ShellEvent) {
        self.host.now_ms = self.now_ms();
        match event {
            ShellEvent::Wake => {
                while let Ok(event) = self.events.try_recv() {
                    self.on_event(event);
                }
            }
            ShellEvent::Timer(TIMER_TICK) => {
                let now = self.host.now_ms;
                self.host.run_due();
                self.controller.on_tick(&mut self.host, now);
                if self.controller.is_recording() {
                    self.host.overlay.set_levels(core_bridge::mic_levels());
                }
            }
            ShellEvent::Timer(_) => {}
            ShellEvent::TrayLeftClick => self.open_settings(),
            ShellEvent::TrayRightClick => self.shell.show_menu(vec![
                MenuItem::Item {
                    id: MENU_SETTINGS,
                    title: "Настройки…".into(),
                    enabled: true,
                },
                MenuItem::Item {
                    id: MENU_DATA_FOLDER,
                    title: "Открыть папку с настройками".into(),
                    enabled: true,
                },
                MenuItem::Item {
                    id: MENU_LOG,
                    title: "Открыть журнал".into(),
                    enabled: true,
                },
                MenuItem::Separator,
                MenuItem::Item {
                    id: MENU_QUIT,
                    title: "Выйти".into(),
                    enabled: true,
                },
            ]),
            ShellEvent::MenuCommand(id) => match id {
                MENU_SETTINGS => self.open_settings(),
                MENU_DATA_FOLDER => window::open_path(&config::config_dir().to_string_lossy()),
                MENU_LOG => {
                    let log = logfile::log_path(&config::config_dir());
                    window::open_path(&log.to_string_lossy());
                }
                MENU_QUIT => self.quit(),
                _ => {}
            },
            ShellEvent::TaskbarCreated => self.host.tray.readd(),
            ShellEvent::CloseRequested => {
                log::info!("asked to close");
                self.quit();
            }
        }
        self.update_timer();
    }

    fn quit(&mut self) {
        let now = self.host.now_ms;
        self.controller
            .on_gesture(&mut self.host, Gesture::Cancel, now);
        if let Some(w) = self.settings_window.take() {
            w.form.close();
        }
        shell::quit();
    }

    fn on_event(&mut self, event: AppEvent) {
        let now = self.host.now_ms;
        match event {
            AppEvent::Gesture(g) => self.controller.on_gesture(&mut self.host, g, now),
            AppEvent::Bridge(BridgeEvent::Core(e)) => {
                self.controller.on_core(&mut self.host, e, now)
            }
            AppEvent::Bridge(BridgeEvent::Download(d)) => self.on_download(d),
            AppEvent::MicFailed(e) => {
                log::error!("microphone: {e}");
                self.controller.on_mic_failed(&mut self.host, &e, now);
            }
            AppEvent::Form(e) => self.on_form(e),
        }
    }

    fn update_timer(&mut self) {
        let want = self.controller.wants_ticks() || !self.host.later.is_empty();
        if want != self.ticking {
            if want {
                self.shell.start_timer(TIMER_TICK, TICK_MS);
            } else {
                self.shell.stop_timer(TIMER_TICK);
            }
            self.ticking = want;
        }
    }

    fn open_settings(&mut self) {
        if let Some(w) = &self.settings_window {
            if w.form.is_open() {
                w.form.focus();
                return;
            }
        }
        let s = Settings::load(&Dpapi);

        let mut providers = vec![PROVIDER_QWEN.to_string()];
        let mut provider_titles = vec!["Qwen в облаке (ваш ключ DashScope)".to_string()];
        if LOCAL {
            providers.push(PROVIDER_LOCAL.to_string());
            provider_titles.push("Локально, без интернета (sherpa-onnx, процессор)".to_string());
        }
        if !providers.contains(&s.provider) {
            providers.push(s.provider.clone());
            provider_titles.push(format!("{} (задан в config.yaml)", s.provider));
        }

        let mut models: Vec<String> = QWEN_MODELS.iter().map(|(id, _)| id.to_string()).collect();
        let mut model_titles: Vec<String> =
            QWEN_MODELS.iter().map(|(_, t)| t.to_string()).collect();
        if !models.contains(&s.qwen_model) {
            models.push(s.qwen_model.clone());
            model_titles.push(s.qwen_model.clone());
        }

        let mut languages: Vec<String> = LANGUAGES.iter().map(|(c, _)| c.to_string()).collect();
        let mut language_titles: Vec<String> =
            LANGUAGES.iter().map(|(_, t)| t.to_string()).collect();
        if !languages.contains(&s.qwen_language) {
            languages.push(s.qwen_language.clone());
            language_titles.push(s.qwen_language.clone());
        }

        let keys = TriggerKey::choices();
        let modes = TriggerMode::choices();
        let index = |list: &[String], v: &str| list.iter().position(|x| x == v).unwrap_or(0);
        let mut fields = vec![
            Field::Choice {
                label: "Распознавание речи".into(),
                options: provider_titles,
                selected: index(&providers, &s.provider),
            },
            Field::Text {
                label: "Ключ DashScope (Model Studio → API Keys)".into(),
                value: s.qwen_key.clone(),
                secret: true,
            },
            Field::Choice {
                label: "Модель Qwen".into(),
                options: model_titles,
                selected: index(&models, &s.qwen_model),
            },
            Field::Choice {
                label: "Язык речи для Qwen".into(),
                options: language_titles,
                selected: index(&languages, &s.qwen_language),
            },
            Field::Choice {
                label: "Клавиша диктовки".into(),
                options: keys.iter().map(|k| k.title()).collect(),
                selected: keys.iter().position(|k| *k == s.trigger_key).unwrap_or(0),
            },
            Field::Choice {
                label: "Как нажимать".into(),
                options: modes.iter().map(|m| m.title().to_string()).collect(),
                selected: modes.iter().position(|m| *m == s.trigger_mode).unwrap_or(0),
            },
            Field::Note(match (LOCAL, self.downloading) {
                (false, _) => String::new(),
                (true, true) => "Скачивание…".into(),
                (true, false) => local_status_text(),
            }),
        ];
        if LOCAL {
            fields.push(Field::Button("Скачать локальную модель".into()));
        }
        fields.push(Field::Note(
            "Держите клавишу и говорите — текст вставится туда, где мигает курсор. \
             Ключ хранится зашифрованным для вашей учётной записи Windows. \
             Остальные настройки — в config.yaml (общий с Mac)."
                .into(),
        ));
        let queue = self.host.queue.clone();
        match Form::open(
            &format!("{APP_NAME} — настройки"),
            fields,
            Box::new(move |e| queue.send(AppEvent::Form(e))),
        ) {
            Ok(form) => {
                self.settings_window = Some(SettingsWindow {
                    form,
                    before: s,
                    models,
                    languages,
                    providers,
                })
            }
            Err(e) => log::error!("settings window: {e}"),
        }
    }

    fn on_form(&mut self, event: FormEvent) {
        let Some(w) = self.settings_window.take() else {
            return;
        };
        match event {
            FormEvent::Save(values) => {
                let choice = |i: usize| match values.get(i) {
                    Some(Value::Choice(c)) => *c,
                    _ => 0,
                };
                let text = |i: usize| match values.get(i) {
                    Some(Value::Text(t)) => t.clone(),
                    _ => String::new(),
                };
                let pick = |list: &[String], i: usize, fallback: &str| {
                    list.get(i).cloned().unwrap_or_else(|| fallback.to_string())
                };
                let after = Settings {
                    provider: pick(&w.providers, choice(F_PROVIDER), &w.before.provider),
                    qwen_key: text(F_KEY),
                    qwen_model: pick(&w.models, choice(F_MODEL), &w.before.qwen_model),
                    qwen_language: pick(&w.languages, choice(F_LANGUAGE), &w.before.qwen_language),
                    trigger_key: TriggerKey::choices()
                        .get(choice(F_TRIGGER))
                        .copied()
                        .unwrap_or(w.before.trigger_key),
                    trigger_mode: TriggerMode::choices()
                        .get(choice(F_MODE))
                        .copied()
                        .unwrap_or(w.before.trigger_mode),
                };
                match after.save(&w.before, &Dpapi) {
                    Ok(()) => {
                        core_bridge::reload_config();
                        self.host
                            .filter
                            .lock()
                            .unwrap_or_else(|e| e.into_inner())
                            .configure(after.trigger_key, after.trigger_mode);
                        log::info!("settings saved");
                        w.form.close();
                        return;
                    }
                    Err(e) => {
                        log::error!("saving settings: {e}");
                        w.form
                            .set_note(F_STATUS, &format!("Не удалось сохранить: {e}"));
                    }
                }
            }
            FormEvent::Button(F_DOWNLOAD) if LOCAL && !self.downloading => {
                if core_bridge::download_model(&local_model()) {
                    self.downloading = true;
                    w.form.set_note(F_STATUS, "Скачивание…");
                } else {
                    w.form.set_note(
                        F_STATUS,
                        "Не удалось начать скачивание — подробности в журнале.",
                    );
                }
            }
            FormEvent::Button(_) => {}
            FormEvent::Closed => return,
        }
        self.settings_window = Some(w);
    }

    fn on_download(&mut self, event: DownloadEvent) {
        let note = match event {
            DownloadEvent::Progress {
                file_index,
                file_count,
                done,
                total,
            } => {
                let percent = (done * 100).checked_div(total).unwrap_or(0);
                format!(
                    "Скачивание: файл {} из {file_count}, {percent}%",
                    file_index + 1
                )
            }
            DownloadEvent::Finished => {
                self.downloading = false;
                self.host.tray.notify(APP_NAME, "Локальная модель скачана.");
                local_status_text()
            }
            DownloadEvent::Failed(e) => {
                self.downloading = false;
                log::error!("model download: {e}");
                format!("Не скачалась: {e}")
            }
        };
        if let Some(w) = &self.settings_window {
            w.form.set_note(F_STATUS, &note);
        }
    }
}

thread_local! {
    static APP: RefCell<Option<App>> = const { RefCell::new(None) };
}

pub fn run() {
    let data_dir = config::config_dir();
    let log_path = logfile::init(&data_dir).ok();
    log::info!("{APP_NAME} {} starting", env!("CARGO_PKG_VERSION"));

    if !window::claim_single_instance("Local\\VelikiyMoguchiy") {
        window::message_box(
            APP_NAME,
            "Программа уже запущена — её значок в трее, у часов.",
        );
        return;
    }

    // The keys must be in this process's environment before the core first
    // reads the config.
    if let Err(e) = config::ensure_defaults() {
        log::warn!("default config: {e}");
    }
    if let Err(e) = settings::apply_windows_defaults() {
        log::warn!("Windows defaults: {e}");
    }
    if let Err(e) = keys::secure(&Dpapi) {
        log::error!("encrypting the DashScope keys: {e}");
    }

    let shell = match Shell::create() {
        Ok(s) => s,
        Err(e) => {
            log::error!("main window: {e}");
            return;
        }
    };
    let (tx, events) = channel();
    let queue = Queue {
        tx,
        waker: shell.waker(),
    };

    let core_queue = queue.clone();
    if !core_bridge::start(move |e| core_queue.send(AppEvent::Bridge(e))) {
        let hint = log_path
            .map(|p| p.display().to_string())
            .unwrap_or_default();
        window::message_box(
            APP_NAME,
            &format!("Не удалось запустить ядро распознавания.\n{hint}"),
        );
        return;
    }

    let settings = Settings::load(&Dpapi);
    let filter = Arc::new(Mutex::new(HotkeyFilter::new(
        settings.trigger_key,
        settings.trigger_mode,
    )));

    let hook_filter = filter.clone();
    let hook_queue = queue.clone();
    let hook = match KeyboardHook::install(Box::new(move |e: KeyEvent| {
        let mut f = hook_filter.lock().unwrap_or_else(|e| e.into_inner());
        // The smoke test presses the dictation key with SendInput.
        let injected = e.injected && !cfg!(feature = "smoke");
        let verdict = f.on_key(e.vk, e.down, u64::from(e.time_ms), injected);
        // Releasing Alt alone would open the focused window's menu bar.
        if e.down && !e.injected && e.vk == VK_RMENU && f.key() == TriggerKey::RightAlt {
            input::mask_alt_release();
        }
        drop(f);
        if let Some(g) = verdict.gesture {
            hook_queue.send(AppEvent::Gesture(g));
        }
        verdict.swallow
    })) {
        Ok(h) => h,
        Err(e) => {
            log::error!("keyboard hook: {e}");
            window::message_box(
                APP_NAME,
                "Не удалось перехватить клавиатуру — диктовка не будет работать.",
            );
            core_bridge::shutdown();
            return;
        }
    };

    let overlay = match Overlay::create() {
        Ok(o) => o,
        Err(e) => {
            log::error!("overlay: {e}");
            core_bridge::shutdown();
            return;
        }
    };
    let mut tray = Tray::add(shell.hwnd(), APP_NAME);
    let first_run_problem = settings.problem();
    if let Some(problem) = first_run_problem {
        tray.notify(APP_NAME, problem);
    }
    #[cfg(feature = "smoke")]
    crate::smoke::write_report(&serde_json::json!({
        "pid": std::process::id(),
        "data_dir": data_dir,
        "config_path": config::config_path(),
        "config_exists": config::config_path().is_file(),
        "log_path": log_path,
        "core_started": true,
        "hook_installed": true,
        "tray_added": tray.added(),
        "provider": settings.provider,
        "qwen_model": settings.qwen_model,
        "qwen_language": settings.qwen_language,
        "trigger_key": settings.trigger_key.config_value(),
        "trigger_mode": settings.trigger_mode.config_value(),
        "has_key": !settings.qwen_key.is_empty(),
        "setup_problem": first_run_problem,
    }));

    let app = App {
        shell,
        controller: Controller::new(),
        host: WinHost {
            overlay,
            tray,
            filter,
            mic: None,
            pipe: Arc::new(Mutex::new(AudioPipe::new())),
            queue,
            later: Vec::new(),
            now_ms: 0,
        },
        events,
        settings_window: None,
        downloading: false,
        ticking: false,
        started: Instant::now(),
        _hook: hook,
    };
    APP.with(|a| *a.borrow_mut() = Some(app));
    shell.set_handler(Box::new(|event| {
        APP.with(|a| {
            if let Some(app) = a.borrow_mut().as_mut() {
                app.on_shell(event);
            }
        })
    }));
    if first_run_problem.is_some() {
        APP.with(|a| {
            if let Some(app) = a.borrow_mut().as_mut() {
                app.open_settings();
            }
        });
    }

    shell.run();

    APP.with(|a| {
        if let Some(mut app) = a.borrow_mut().take() {
            app.host.stop_mic();
            app.host.overlay.hide();
        }
    });
    core_bridge::shutdown();
    log::info!("{APP_NAME} stopped");
}
