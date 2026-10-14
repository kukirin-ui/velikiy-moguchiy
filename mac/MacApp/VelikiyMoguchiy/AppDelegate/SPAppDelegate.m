#import "SPAppDelegate.h"
#import "SPPermissionManager.h"
#import "SPAccessibilityManager.h"
#import "SPHotkeyMonitor.h"
#import "SPMediaKeyMonitor.h"
#import "SPAudioCaptureManager.h"
#import "SPAudioDeviceManager.h"
#import "SPRustBridge.h"
#import "SPClipboardManager.h"
#import "SPClipboardRestorePolicy.h"
#import "SPPasteManager.h"
#import "SPInstantPasteGuard.h"
#import "SPTextEditPolicy.h"
#import "SPSelectionEditor.h"
#import "SPCuePlayer.h"
#import "SPStatusBarManager.h"
#import "SPOverlayPanel.h"
#import "SPHistoryManager.h"
#import "SPRetranscriber.h"
#import "SPRecordingManager.h"
#import "SPLipCaptureManager.h"
#import "SPLipsPolicy.h"
#import "SPLipsService.h"
#import "SPLipsRuntime.h"
#import "SPLocalAsrOffer.h"
#import "SPOnboardingWindowController.h"
#import "SPAppUpdateChecker.h"
#import "SPProblemReportWindowController.h"
#import "SPRecentDictationsWindowController.h"
#import "SPSetupWizardWindowController.h"
#import "SPLocalization.h"
#import "SPOutputModes.h"
#import "velikiy_moguchiy_core.h"
#import "SPAppPaths.h"
#import "SPErrorExplainer.h"
#import "SPHotkeyNames.h"
#import "SPTriggerKeyPolicy.h"
#import <os/log.h>
#import <sys/stat.h>
#import <UserNotifications/UserNotifications.h>

@class SPAppDelegate;

/// Drives the output-mode key: a press (tap or long press) cycles the mode and
/// never starts a recording.
@interface SPModeHotkeyProxy : NSObject <SPHotkeyMonitorDelegate>
@property (nonatomic, weak) SPAppDelegate *target;
@property (nonatomic, weak) SPHotkeyMonitor *monitor;
/// What a press does; without one it cycles the output mode.
@property (nonatomic, copy) void (^onPress)(void);
@end

/// Forwards an extra hotkey monitor's events to the app delegate, tagging the
/// session it starts with a purpose so the dictation flow is reused unchanged.
@interface SPHotkeyPurposeProxy : NSObject <SPHotkeyMonitorDelegate>
@property (nonatomic, weak) SPAppDelegate *target;
@property (nonatomic, assign) SPSessionPurpose purpose;
@end

/// Forwards the lips key's hold to the app delegate (experimental.lips).
@interface SPLipsHotkeyProxy : NSObject <SPHotkeyMonitorDelegate>
@property (nonatomic, weak) SPAppDelegate *target;
@end

@interface SPAppDelegate () <SPAudioDeviceManagerDelegate, SPOverlayPanelDelegate, UNUserNotificationCenterDelegate>
@property (nonatomic, strong) SPRecentDictationsWindowController *recentDictations;
@property (nonatomic, strong) NSPanel *designPreviewMenuPanel;
// Recording of the session in flight, linked to its history row when the
// session ends.
@property (nonatomic, copy) NSString *sessionAudioPath;
@property (nonatomic, copy) NSString *sessionAppBundleId;
// Camera clip (opt-in lip-reading data, lipdata.capture_video): armed at the
// trigger-down, owned by the session once the hold / tap is confirmed.
@property (nonatomic, strong) SPLipClip *armedLipClip;
@property (nonatomic, strong) SPLipClip *sessionLipClip;
@property (nonatomic, strong) NSDate *recordingStartTime;
@property (nonatomic, assign) time_t lastConfigModTime;
@property (nonatomic, copy) dispatch_block_t pendingSessionEndBlock;
@property (nonatomic, assign) BOOL showingError;
@property (nonatomic, copy) NSString *lastAsrText;
@property (nonatomic, strong) NSTask *micWarmTask;
@property (nonatomic, strong) SPMediaKeyMonitor *mediaKeyMonitor;
@property (nonatomic, strong) SPHotkeyMonitor *translateHotkeyMonitor;
@property (nonatomic, strong) SPHotkeyMonitor *askHotkeyMonitor;
@property (nonatomic, strong) SPHotkeyMonitor *editHotkeyMonitor;
@property (nonatomic, strong) SPHotkeyPurposeProxy *translateHotkeyProxy;
@property (nonatomic, strong) SPHotkeyPurposeProxy *askHotkeyProxy;
@property (nonatomic, strong) SPHotkeyPurposeProxy *editHotkeyProxy;
@property (nonatomic, strong) SPHotkeyMonitor *undoHotkeyMonitor;
@property (nonatomic, strong) SPModeHotkeyProxy *undoHotkeyProxy;
@property (nonatomic, strong) SPHotkeyMonitor *repasteHotkeyMonitor;
@property (nonatomic, strong) SPModeHotkeyProxy *repasteHotkeyProxy;
// Voice edit: the selection captured at the trigger, for the session in flight.
@property (nonatomic, strong) SPSelectionAnchor *editAnchor;
// The last text the app put into a field (undo), and the last dictation text
// of this run (re-paste).
@property (nonatomic, strong) SPInsertionRecord *lastInsertion;
@property (nonatomic, copy) NSString *lastDictationText;
@property (nonatomic, strong) SPHotkeyMonitor *modeHotkeyMonitor;
@property (nonatomic, strong) SPModeHotkeyProxy *modeHotkeyProxy;
@property (nonatomic, strong) SPHotkeyMonitor *mouseHotkeyMonitor;
// Lips mode: the camera clip recorded while the lips key is held, and whether
// a recorded clip is still being read.
@property (nonatomic, strong) SPHotkeyMonitor *lipsHotkeyMonitor;
@property (nonatomic, strong) SPLipsHotkeyProxy *lipsHotkeyProxy;
@property (nonatomic, strong) SPLipClip *lipsClip;
@property (nonatomic, assign) BOOL lipsBusy;
@property (nonatomic, copy) NSString *pendingLipsModelTag;
@property (nonatomic, strong) SPLocalAsrOffer *localAsrOffer;
@property (nonatomic, strong) SPProblemReportWindowController *problemReport;
@property (nonatomic, strong) SPHotkeyPurposeProxy *mouseHotkeyProxy;
@property (nonatomic, strong) NSTimer *silenceStopTimer;
// Watches the level meter while recording for a microphone that gives nothing.
@property (nonatomic, strong) NSTimer *micSilenceTimer;
// When each warning was last said, so a warning repeated on every dictation is said once in a while.
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDate *> *warningShownAt;
// A message that waits for the pill to finish the result of the session.
@property (nonatomic, strong) SPErrorExplanation *pendingPillMessage;
// Polls the permissions while one is missing, so granting it later needs no restart.
@property (nonatomic, strong) NSTimer *permissionWatchTimer;
@property (nonatomic, assign) BOOL watchedAccessibilityGranted;
@property (nonatomic, assign) BOOL watchedInputMonitoringGranted;
@property (nonatomic, assign) BOOL hotkeyRestartPending;
// Ends a recording that has gone on for recording.max_duration_s.
@property (nonatomic, strong) NSTimer *recordingCapTimer;
// Judges the focused element before a paste (password field, no field at all).
@property (nonatomic, strong) SPAccessibilityManager *accessibilityManager;
@property (nonatomic, strong) SPOnboardingWindowController *onboarding;
// A first launch: «Начало работы» takes the place of the separate prompts and offers.
@property (nonatomic, assign) BOOL onboardingAtLaunch;
@property (nonatomic, assign) SPSessionPurpose pendingSessionPurpose;
@property (nonatomic, assign) SPSessionPurpose sessionPurpose;
// Session result metadata delivered just before the final text; consumed
// (and cleared) when the final text arrives and history is recorded.
@property (nonatomic, copy) NSString *pendingMetaAsrText;
@property (nonatomic, copy) NSString *pendingMetaAsrProvider;
@property (nonatomic, assign) BOOL pendingMetaLlmApplied;
// How the core wants the final text delivered (SPTextDelivery), delivered just
// before the final text; consumed when it arrives.
@property (nonatomic, assign) NSInteger pendingDeliveryKind;
@property (nonatomic, copy) NSString *pendingDeliveryRemainder;
// The dictation ended with the spoken "отправь": Return follows the paste.
@property (nonatomic, assign) BOOL pendingSendRequest;
// Experimental paste-ASR-first flow (experimental.paste_asr_first):
// raw text pasted at ASR-final time, awaiting the LLM correction.
@property (nonatomic, strong) SPInstantPasteGuard *instantPasteGuard;
// Session-scoped clipboard restoration policy; the effective delay is
// snapshotted when a session begins (see beginRustSessionWithMode:).
@property (nonatomic, strong) SPClipboardRestorePolicy *clipboardRestorePolicy;
@property (nonatomic, copy) NSString *instantPastedText;
@property (nonatomic, assign) BOOL instantPasteKeepClipboard;
@property (nonatomic, strong) id numberKeyMonitor;
@property (nonatomic, assign) BOOL llmCorrectionInProgress;
@property (nonatomic, assign) BOOL rawAsrFallbackInteractionActive;
@property (nonatomic, assign) BOOL sessionWantsAudioCapture;
@property (nonatomic, assign) BOOL audioPreparationEnabled;
@property (nonatomic, assign) BOOL preCaptureInterruptedPendingSessionEnd;
@property (nonatomic, assign) BOOL loggedFirstRecognitionForActivation;
@property (nonatomic, assign) NSUInteger recognitionMetricActivationSequence;
@property (nonatomic, assign) uint64_t recognitionMetricSessionToken;
- (void)beginTriggerForPurpose:(SPSessionPurpose)purpose;
- (void)discardArmedLipClip;
- (void)lipsKeyDown;
- (void)lipsHoldStarted;
- (void)lipsKeyUp;
- (void)lipsKeyCancelled;
@end

static BOOL sessionStateAllowsConfigReload(NSString *state) {
    if (state.length == 0) return YES;
    return [state isEqualToString:@"idle"] ||
           [state isEqualToString:@"completed"] ||
           [state isEqualToString:@"failed"] ||
           [state isEqualToString:@"error"];
}

@implementation SPAppDelegate

static const NSTimeInterval kManualPasteResultLingerDuration = 8.0;
// Peak below this (about -80 dBFS) is a muted, unplugged or wrong input, not a quiet room.
static const float kSilentMicPeak = 0.0001f;
static const NSTimeInterval kMicSilenceHintDelay = 2.5;
static const NSTimeInterval kWarningRepeatInterval = 10 * 60;
static NSString *const kSessionStartFailure = @"Не удалось начать сессию";
// How many times the first-use hints are shown before they stop.
static const NSInteger kFirstUseHintLimit = 3;
static NSString *const kHoldHintCountKey = @"SPHoldHintCount";
static NSString *const kHandsFreeHintCountKey = @"SPHandsFreeHintCount";
static const NSInteger kEscapeKeyCode = 53;
static const NSTimeInterval kAbortResultLingerDuration = 0.8;
static const NSTimeInterval kQuickBadgeLingerDuration = 1.8;

static BOOL configFlagEnabled(const char *keyPath) {
    char *rawValue = sp_config_get(keyPath);
    if (!rawValue) return NO;

    NSString *value = [[[NSString stringWithUTF8String:rawValue] ?: @""
        stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    sp_core_free_string(rawValue);
    return [value isEqualToString:@"1"] ||
           [value isEqualToString:@"true"] ||
           [value isEqualToString:@"yes"] ||
           [value isEqualToString:@"on"];
}

static NSString *configStringValue(const char *keyPath) {
    char *rawValue = sp_config_get(keyPath);
    if (!rawValue) return @"";
    NSString *value = [NSString stringWithUTF8String:rawValue] ?: @"";
    sp_core_free_string(rawValue);
    return value;
}

static BOOL configFlagEnabledDefaultingTo(const char *keyPath, BOOL defaultValue) {
    char *rawValue = sp_config_get(keyPath);
    if (!rawValue) return defaultValue;
    BOOL missing = rawValue[0] == '\0';
    sp_core_free_string(rawValue);
    return missing ? defaultValue : configFlagEnabled(keyPath);
}

static BOOL autoRetryOnErrorEnabled(void) {
    return configFlagEnabledDefaultingTo("history.auto_retry_on_error", YES);
}

static BOOL keepLastDictationEnabled(void) {
    return configFlagEnabled("clipboard.keep_last_dictation");
}

// A guard bound to ONE session's identity via its session token. Injections
// scheduled by an older session carry that session's guard, so a newer session
// (which bumps the token) can neither authorize nor be hijacked by them; the
// guard also refuses to fire while the app is quitting.
//
// The app intentionally does NOT restrict injection to the app that was frontmost
// when dictation began. Starting a session in one app and pasting into another
// (dictate from a terminal, paste into a chat box) is a normal, supported
// workflow, so the paste lands in whatever app is frontmost at injection time.
- (SPPasteInjectionGuard)injectionGuardForSessionToken:(uint64_t)token {
    __weak typeof(self) weakSelf = self;
    return ^BOOL{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.quitting) return NO;
        return token == strongSelf.rustBridge.currentSessionToken;
    };
}

- (BOOL)prepareAudioQueueForResolvedDevice {
    if (!self.audioPreparationEnabled) return NO;
    [self.audioCaptureManager setInputDeviceID:[self.audioDeviceManager resolvedDeviceID]];
    return [self.audioCaptureManager prepare];
}

static BOOL configFlagEnabledWithDefault(const char *keyPath, BOOL defaultValue) {
    char *rawValue = sp_config_get(keyPath);
    if (!rawValue) return defaultValue;

    BOOL enabled = defaultValue;
    if (strcmp(rawValue, "true") == 0) {
        enabled = YES;
    } else if (strcmp(rawValue, "false") == 0) {
        enabled = NO;
    }
    sp_core_free_string(rawValue);
    return enabled;
}

// Phantom-key lab switches (issues #57/#65): env flags that disable whole
// subsystems so the arming source can be bisected with real-usage rounds.
// VELIKIY_MOGUCHIY_LAB_NO_HOTKEY=1  -> no SPHotkeyMonitor at all (no tap/monitors/Carbon)
// VELIKIY_MOGUCHIY_LAB_NO_AUDIO=1   -> no prepared AudioQueue (mic device not held)
static BOOL SPLabFlag(const char *name) {
    const char *value = getenv(name);
    return value && value[0] == '1';
}

/// The pill has no room for template buttons; templates stay off.
- (BOOL)shouldShowPromptTemplateButtons {
    return NO;
}

- (BOOL)shouldAutoPasteProcessedText {
    return configFlagEnabledWithDefault("llm.auto_paste_processed_text", YES);
}

- (void)showPromptTemplateButtonsIfNeededOrDismiss {
    [self showPromptTemplateButtonsIfNeededOrDismissWithLingerDuration:0];
}

- (void)showPromptTemplateButtonsIfNeededOrDismissWithLingerDuration:(NSTimeInterval)lingerDuration {
    [self startAnyKeyDismissMonitoring];

    if (![self shouldShowPromptTemplateButtons]) {
        [self.overlayPanel lingerAndDismissWithDuration:lingerDuration];
        return;
    }

    NSArray *templates = [self.rustBridge promptTemplates];
    NSMutableArray<NSDictionary *> *visibleTemplates = [NSMutableArray array];
    NSInteger visibleShortcut = 1;
    for (NSUInteger index = 0; index < templates.count; index++) {
        NSDictionary *templateData = templates[index];
        id enabledValue = templateData[@"enabled"];
        BOOL enabled = ![enabledValue isKindOfClass:[NSNumber class]] || [enabledValue boolValue];
        if (!enabled) continue;

        NSMutableDictionary *overlayTemplate = [templateData mutableCopy] ?: [NSMutableDictionary dictionary];
        overlayTemplate[@"shortcut"] = @(visibleShortcut++);
        overlayTemplate[@"source_index"] = @(index);
        [visibleTemplates addObject:overlayTemplate];
    }

    NSLog(@"[VelikiyMoguchiy] Prompt templates visible: %lu / %lu", (unsigned long)visibleTemplates.count, (unsigned long)templates.count);
    if (visibleTemplates.count > 0 && self.lastAsrText.length > 0) {
        [self.overlayPanel showTemplateButtons:visibleTemplates lingerDuration:lingerDuration];
        [self startNumberKeyMonitoringWithVisibleCount:(NSInteger)visibleTemplates.count];
    } else {
        [self.overlayPanel lingerAndDismissWithDuration:lingerDuration];
    }
}

- (void)applyHotkeyConfig:(struct SPHotkeyConfig)hotkeyConfig restartMonitorIfNeeded:(BOOL)restartIfNeeded {
    BOOL changed = self.hotkeyMonitor.targetKeyCode != hotkeyConfig.trigger_key_code ||
                   self.hotkeyMonitor.altKeyCode != hotkeyConfig.trigger_alt_key_code ||
                   self.hotkeyMonitor.targetModifierFlag != hotkeyConfig.trigger_modifier_flag ||
                   self.hotkeyMonitor.targetMatchKind != hotkeyConfig.trigger_match_kind ||
                   self.hotkeyMonitor.triggerMode != (SPHotkeyTriggerMode)hotkeyConfig.trigger_mode;

    if (!changed) return;

    if (restartIfNeeded) {
        [self.hotkeyMonitor stop];
        [self.translateHotkeyMonitor stop];
        [self.askHotkeyMonitor stop];
        [self.editHotkeyMonitor stop];
        [self.undoHotkeyMonitor stop];
        [self.repasteHotkeyMonitor stop];
        [self.modeHotkeyMonitor stop];
        [self.mouseHotkeyMonitor stop];
    }

    self.hotkeyMonitor.targetKeyCode = hotkeyConfig.trigger_key_code;
    self.hotkeyMonitor.altKeyCode = hotkeyConfig.trigger_alt_key_code;
    self.hotkeyMonitor.targetModifierFlag = hotkeyConfig.trigger_modifier_flag;
    self.hotkeyMonitor.targetMatchKind = hotkeyConfig.trigger_match_kind;
    self.hotkeyMonitor.triggerMode = (SPHotkeyTriggerMode)hotkeyConfig.trigger_mode;

    if (restartIfNeeded) {
        [self.hotkeyMonitor start];
    }
}

- (void)reloadConfigAndApplyHotkey {
    [self.rustBridge reloadConfig];

    struct SPHotkeyConfig newConfig = sp_core_get_hotkey_config();
    NSLog(@"[VelikiyMoguchiy] Reloaded hotkey config: trigger=%d/%d flag=0x%llx kind=%d",
          newConfig.trigger_key_code,
          newConfig.trigger_alt_key_code,
          (unsigned long long)newConfig.trigger_modifier_flag,
          newConfig.trigger_match_kind);

    [self applyHotkeyConfig:newConfig restartMonitorIfNeeded:YES];
    [self rebuildExtraHotkeyMonitors];
    [self.overlayPanel reloadAppearanceFromConfig];
    [self startMicWarmIfEnabled];
}

- (void)reloadConfigAndApplyHotkeyIfSafe {
    if (!sessionStateAllowsConfigReload(self.sessionState)) {
        self.hasPendingConfigReload = YES;
        NSLog(@"[VelikiyMoguchiy] Deferring config reload until session becomes idle (state=%@)", self.sessionState ?: @"unknown");
        return;
    }

    self.hasPendingConfigReload = NO;
    [self reloadConfigAndApplyHotkey];
}

- (void)applyDeferredConfigReloadIfNeeded {
    if (self.hotkeyRestartPending && sessionStateAllowsConfigReload(self.sessionState)) {
        [self checkWatchedPermissions];
    }
    if (!self.hasPendingConfigReload) return;
    if (!sessionStateAllowsConfigReload(self.sessionState)) return;

    NSLog(@"[VelikiyMoguchiy] Applying deferred config reload");
    self.hasPendingConfigReload = NO;
    [self reloadConfigAndApplyHotkey];
}

/// Design preview for screenshots (`-VMDesignPreview YES [-VMDesignPreviewPane about]`):
/// the status item, the Settings window and the overlay pill, drawn on the last
/// screen (a virtual display in tests). No hotkeys, audio, permission prompts or
/// activation, so it can run beside a working copy of the app.
- (void)startDesignPreview {
    [self installEditMenu];
    self.permissionManager = [[SPPermissionManager alloc] init];
    self.audioDeviceManager = [[SPAudioDeviceManager alloc] init];
    self.rustBridge = [[SPRustBridge alloc] initWithDelegate:self];
    [self.rustBridge initializeCore];
    NSScreen *screen = NSScreen.screens.count > 1 ? NSScreen.screens.lastObject : nil;
    if (!screen) {
        NSLog(@"[VelikiyMoguchiy] Design preview needs a second (virtual) display");
        return;
    }
    // No status item: it would appear in the menu bar of the main screen.
    self.statusBarManager = [[SPStatusBarManager alloc]
        initMenuOnlyWithPermissionManager:self.permissionManager
                       audioDeviceManager:self.audioDeviceManager];
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"VMDesignPreviewMenu"]) {
        NSView *menuView = [self.statusBarManager designPreviewView];
        NSRect visible = screen.visibleFrame;
        NSPanel *panel = [[NSPanel alloc]
            initWithContentRect:NSMakeRect(NSMaxX(visible) - 360, NSMaxY(visible) - 60 - NSHeight(menuView.frame),
                                           NSWidth(menuView.frame), NSHeight(menuView.frame))
                      styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                        backing:NSBackingStoreBuffered
                          defer:NO];
        panel.title = @"Меню (предпросмотр)";
        panel.opaque = NO;
        panel.backgroundColor = NSColor.clearColor;
        panel.hasShadow = YES;
        panel.contentView = menuView;
        panel.releasedWhenClosed = NO;
        [panel orderFrontRegardless];
        self.designPreviewMenuPanel = panel;
    }
    self.setupWizard = [[SPSetupWizardWindowController alloc] init];
    self.setupWizard.rustBridge = self.rustBridge;
    [self.setupWizard
        showForDesignPreviewOnScreen:screen
                                pane:[NSUserDefaults.standardUserDefaults stringForKey:@"VMDesignPreviewPane"]];
    // Created even when not shown: the Overlay pane previews the pill through it.
    self.overlayPanel = [[SPOverlayPanel alloc] init];
    self.overlayPanel.screenOverride = screen;
    NSString *overlayState = [NSUserDefaults.standardUserDefaults stringForKey:@"VMDesignPreviewOverlay"];
    if (overlayState.length > 0) {
        [self.overlayPanel updateState:overlayState];
    }

    NSString *snapshots = [NSUserDefaults.standardUserDefaults stringForKey:@"VMDesignPreviewSnapshots"];
    if (snapshots.length > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self writeDesignSnapshotsToDirectory:snapshots];
            [NSApp terminate:nil];
        });
    }
}

- (void)writeDesignSnapshotsToDirectory:(NSString *)directory {
    [NSFileManager.defaultManager createDirectoryAtPath:directory
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:NULL];
    NSArray *appearances = @[ @[ NSAppearanceNameAqua, @"-light" ], @[ NSAppearanceNameDarkAqua, @"-dark" ] ];
    for (NSArray *pair in appearances) {
        NSApp.appearance = [NSAppearance appearanceNamed:pair[0]];
        self.setupWizard.window.appearance = NSApp.appearance;
        self.designPreviewMenuPanel.appearance = NSApp.appearance;
        // Appearance changes reach the views on the next pass of the run loop.
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.4]];
        [self.setupWizard writeDesignSnapshotsToDirectory:directory suffix:pair[1]];
        if (self.designPreviewMenuPanel) {
            __block NSView *menuView = nil;
            [NSApp.appearance performAsCurrentDrawingAppearance:^{
                menuView = [self.statusBarManager designPreviewView];
            }];
            menuView.appearance = NSApp.appearance;
            self.designPreviewMenuPanel.contentView = menuView;
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
            SPWriteViewSnapshot(self.designPreviewMenuPanel.contentView,
                                [directory stringByAppendingPathComponent:
                                               [NSString stringWithFormat:@"menu%@.png", pair[1]]]);
        }
    }
    for (NSString *state in @[ @"recording_hold", @"correcting", @"completed_letter", @"error" ]) {
        if ([state isEqualToString:@"completed_letter"]) {
            [self.overlayPanel showModeIndicator:@"Р"];
        } else {
            [self.overlayPanel updateState:state];
        }
        NSWindow *pill = nil;
        for (NSWindow *window in NSApp.windows) {
            if ([window isKindOfClass:NSPanel.class] && window != self.designPreviewMenuPanel &&
                NSWidth(window.frame) < 200) {
                pill = window;
            }
        }
        if (pill) {
            SPWriteViewSnapshot(pill.contentView,
                                [directory stringByAppendingPathComponent:
                                               [NSString stringWithFormat:@"overlay-%@.png", state]]);
        }
    }
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSLog(@"[VelikiyMoguchiy] Application launching...");
    self.sessionState = @"idle";

    if ([NSUserDefaults.standardUserDefaults boolForKey:@"VMDesignPreview"]) {
        [self startDesignPreview];
        return;
    }

    // Add Edit menu so Cmd+C/V/X/A work in text fields (menu-bar-only app has none by default)
    [self installEditMenu];

    // Initialize components
    self.cuePlayer = [[SPCuePlayer alloc] init];
    self.clipboardManager = [[SPClipboardManager alloc] init];
    self.clipboardRestorePolicy = [[SPClipboardRestorePolicy alloc] init];
    self.clipboardRestorePolicy.clipboardManager = self.clipboardManager;
    self.pasteManager = [[SPPasteManager alloc] init];
    self.accessibilityManager = [[SPAccessibilityManager alloc] init];
    self.instantPasteGuard = [[SPInstantPasteGuard alloc] init];
    self.audioCaptureManager = [[SPAudioCaptureManager alloc] init];
    self.audioDeviceManager = [[SPAudioDeviceManager alloc] init];
    self.audioDeviceManager.delegate = self;
    [self.audioDeviceManager startListening];
    self.permissionManager = [[SPPermissionManager alloc] init];

    // Initialize Rust bridge (must be before hotkey monitor)
    self.rustBridge = [[SPRustBridge alloc] initWithDelegate:self];
    [[SPRecordingManager sharedManager] startRetention];
    [SPLipCaptureManager cleanUpStaleTemporaryClips];
    [self startMicWarmIfEnabled];
    [self launchLipflowIfEnabled];
    [self.rustBridge initializeCore];

    // Initialize status bar
    self.statusBarManager = [[SPStatusBarManager alloc] initWithDelegate:self
                                                       permissionManager:self.permissionManager
                                                      audioDeviceManager:self.audioDeviceManager];

    // Initialize floating overlay
    self.overlayPanel = [[SPOverlayPanel alloc] init];
    self.overlayPanel.delegate = self;

    [SPLipsRuntime sharedRuntime].rustBridge = self.rustBridge;
    self.onboardingAtLaunch = [SPOnboardingWindowController shouldShowAtLaunch];
    [self startUpdateAndSetupChecks];

    // Clicks on error notifications open the place that fixes the error.
    [UNUserNotificationCenter currentNotificationCenter].delegate = self;
    // On a first launch «Начало работы» asks for notifications when the user
    // wants them, instead of one more system prompt at launch.
    if (!self.onboardingAtLaunch) {
        [self.permissionManager requestNotificationPermission];
    }

    // Request Speech Recognition permission if Apple Speech is the configured provider
    char *rawProvider = sp_config_get("asr.provider");
    if (rawProvider) {
        if (strcmp(rawProvider, "apple-speech") == 0) {
            [self.permissionManager requestSpeechRecognitionPermissionWithCompletion:^(BOOL granted) {
                NSLog(@"[VelikiyMoguchiy] Speech recognition permission: %@", granted ? @"granted" : @"denied");
                if (!granted) {
                    [self.permissionManager showPermissionAlertForType:SPPermissionTypeSpeechRecognition
                                                          settingsURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"]];
                }
            }];
        }
        sp_core_free_string(rawProvider);
    }

    // Check permissions. Nothing below waits for them: a permission granted
    // later is picked up by the permission watch without a restart.
    NSArray<NSNumber *> *lostPermissions = [self.permissionManager lostPermissionTypes];
    BOOL accessibilityLost = [lostPermissions containsObject:@(SPPermissionTypeAccessibility)];
    [self.permissionManager checkAllPermissionsPromptingAccessibility:!accessibilityLost
                                                           completion:^(BOOL micGranted, BOOL accessibilityGranted, BOOL inputMonitoringGranted) {
        NSLog(@"[VelikiyMoguchiy] Permissions — mic:%d accessibility:%d inputMonitoring:%d lost:%@",
              micGranted, accessibilityGranted, inputMonitoringGranted, lostPermissions);

        // No app-level alerts for Accessibility / Input Monitoring at launch:
        // macOS shows its own Input Monitoring prompt when the event tap
        // starts, and the status bar menu offers grant actions for both.
        if (!accessibilityGranted) {
            NSLog(@"[VelikiyMoguchiy] WARNING: Accessibility permission not granted");
        }

        if (!inputMonitoringGranted) {
            NSLog(@"[VelikiyMoguchiy] WARNING: Input Monitoring probe failed, will attempt hotkey monitor anyway");
        }

        // Build the queue after TCC confirms microphone access, but do not
        // start hardware yet. The trigger-down path starts this prepared queue.
        if (micGranted) {
            [self enableAudioPreparation];
        } else {
            NSLog(@"[VelikiyMoguchiy] Microphone permission not granted; audio waits for it");
        }

        // Start hotkey monitor (let it try CGEventTap directly — the probe may give false negatives)
        if (SPLabFlag("VELIKIY_MOGUCHIY_LAB_NO_HOTKEY")) {
            NSLog(@"[VelikiyMoguchiy] LAB: hotkey stack disabled (no tap, no NSEvent monitors, no Carbon)");
        } else {
            self.hotkeyMonitor = [[SPHotkeyMonitor alloc] initWithDelegate:self];

            // Apply hotkey configuration from config.yaml
            struct SPHotkeyConfig hotkeyConfig = sp_core_get_hotkey_config();
            [self applyHotkeyConfig:hotkeyConfig restartMonitorIfNeeded:NO];

            [self.hotkeyMonitor start];
            [self rebuildExtraHotkeyMonitors];
            NSLog(@"[VelikiyMoguchiy] Ready — hotkey monitor active");
        }

        // Start watching config file for hotkey changes
        [self startConfigWatcher];

        [self.permissionManager rememberGrantedPermissions];
        self.watchedAccessibilityGranted = accessibilityGranted;
        self.watchedInputMonitoringGranted = inputMonitoringGranted;
        if (!micGranted || !accessibilityGranted || !inputMonitoringGranted) {
            [self startPermissionWatch];
        }

        // Alerts are modal: shown once everything above is running.
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.onboardingAtLaunch) {
                // Its checklist covers the microphone, the key and the 🌐 clash.
                [self statusBarDidSelectOnboarding];
            } else if (lostPermissions.count > 0) {
                [self.permissionManager showLostAccessAlertForTypes:lostPermissions];
            } else if (!micGranted) {
                [self.cuePlayer playError];
                [self.permissionManager showPermissionAlertForType:SPPermissionTypeMicrophone
                                                       settingsURL:[SPPermissionManager settingsURLForType:SPPermissionTypeMicrophone]];
            } else {
                [self warnAboutFnConflictIfNeeded];
            }
        });
    }];

}

- (void)enableAudioPreparation {
    if (self.audioPreparationEnabled) return;
    if (SPLabFlag("VELIKIY_MOGUCHIY_LAB_NO_AUDIO")) {
        NSLog(@"[VelikiyMoguchiy] LAB: audio queue preparation disabled");
        return;
    }
    self.audioPreparationEnabled = YES;
    if (![self prepareAudioQueueForResolvedDevice]) {
        NSLog(@"[VelikiyMoguchiy] Initial audio queue preparation failed; trigger-down will retry");
    }
}

/// An Fn trigger on a Mac whose 🌐 key also switches the layout, opens the
/// emoji picker or starts the system dictation: said once per such setting.
- (void)warnAboutFnConflictIfNeeded {
    if (![[configStringValue("hotkey.trigger_key") lowercaseString] isEqualToString:@"fn"]) return;
    NSInteger usage = SPFnUsageType();
    NSString *conflict = SPFnUsageConflict(usage);
    if (!conflict) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *warnedKey = @"SPFnConflictWarnedUsage";
    if ([defaults objectForKey:warnedKey] && [defaults integerForKey:warnedKey] == usage) return;
    [defaults setInteger:usage forKey:warnedKey];

    [NSApp activateIgnoringOtherApps:YES];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = @"Клавиша Fn (🌐) занята системой";
    alert.informativeText = SPFnConflictExplanation(conflict);
    [alert addButtonWithTitle:@"Открыть «Клавиатуру»"];
    [alert addButtonWithTitle:@"Выбрать другую клавишу"];
    [alert addButtonWithTitle:@"Оставить Fn"];
    NSModalResponse response = [alert runModal];
    if (response == NSAlertFirstButtonReturn) {
        [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:SPKeyboardSettingsURL]];
    } else if (response == NSAlertSecondButtonReturn) {
        [self showSettingsPane:@"hotkey"];
    }
}

#pragma mark - Permissions granted after launch

/// While a permission is missing: the microphone, once allowed, gets its audio
/// queue; a new Accessibility or Input Monitoring grant rebuilds the hotkey
/// monitors, whose event tap could not be created without it.
- (void)startPermissionWatch {
    if (self.permissionWatchTimer) return;
    __weak typeof(self) weakSelf = self;
    self.permissionWatchTimer = [NSTimer scheduledTimerWithTimeInterval:3.0
                                                                repeats:YES
                                                                  block:^(NSTimer *timer) {
        [weakSelf checkWatchedPermissions];
    }];
}

- (void)checkWatchedPermissions {
    if (self.quitting) return;
    BOOL mic = [self.permissionManager isMicrophoneGranted];
    BOOL accessibility = [self.permissionManager isAccessibilityGranted];
    BOOL inputMonitoring = [self.permissionManager isInputMonitoringGranted];
    if (mic && !self.audioPreparationEnabled) {
        NSLog(@"[VelikiyMoguchiy] Microphone access granted; preparing audio");
        [self enableAudioPreparation];
    }
    if ((accessibility && !self.watchedAccessibilityGranted) ||
        (inputMonitoring && !self.watchedInputMonitoringGranted)) {
        NSLog(@"[VelikiyMoguchiy] Accessibility / Input Monitoring granted; restarting the hotkey monitors");
        self.hotkeyRestartPending = YES;
    }
    self.watchedAccessibilityGranted = accessibility;
    self.watchedInputMonitoringGranted = inputMonitoring;
    if (self.hotkeyRestartPending && sessionStateAllowsConfigReload(self.sessionState)) {
        self.hotkeyRestartPending = NO;
        [self restartHotkeyMonitors];
    }
    if (mic && accessibility && inputMonitoring && !self.hotkeyRestartPending) {
        [self.permissionManager rememberGrantedPermissions];
        [self.permissionWatchTimer invalidate];
        self.permissionWatchTimer = nil;
    }
}

- (void)restartHotkeyMonitors {
    if (!self.hotkeyMonitor) return;
    [self.hotkeyMonitor stop];
    [self.hotkeyMonitor start];
    [self rebuildExtraHotkeyMonitors];
}

/// The trigger fired while the microphone is not allowed: no session starts,
/// and the pill and a notification say where to allow it. YES when refused.
- (BOOL)refuseTriggerWithoutMicrophone {
    if ([self.permissionManager isMicrophoneGranted]) return NO;
    NSLog(@"[VelikiyMoguchiy] Trigger without microphone access; no session started");
    [self.audioCaptureManager cancelPreCapture];
    [self discardArmedLipClip];
    [self resetAllHotkeyMonitorsToIdle];
    self.pendingSessionPurpose = SPSessionPurposeDictate;
    [self.cuePlayer playError];
    [self startPermissionWatch];
    if ([self.permissionManager isMicrophoneUndetermined]) {
        [self.permissionManager requestMicrophonePermissionWithCompletion:^(BOOL granted) {}];
        return YES;
    }
    SPErrorExplanation *explanation =
        [SPErrorExplainer explanationWithKind:SPErrorKindMicrophone
                                    shortText:@"Нет доступа к микрофону"
                                       detail:@"Разрешите его: Системные настройки → Конфиденциальность → Микрофон → "
                                              @"«Великий & Могучий». Перезапускать приложение не нужно."
                                       action:SPErrorActionMicrophonePrivacy];
    [self.overlayPanel showMessage:explanation.shortText icon:SPOverlayMessageIconError];
    [self sendErrorNotificationForExplanation:explanation];
    return YES;
}

#pragma mark - Updates and first-run offers

- (void)startUpdateAndSetupChecks {
    __weak typeof(self) weakSelf = self;
    self.localAsrOffer = [[SPLocalAsrOffer alloc] initWithRustBridge:self.rustBridge];
    self.localAsrOffer.configChangedHandler = ^{
        [weakSelf reloadConfigAndApplyHotkeyIfSafe];
    };
    self.localAsrOffer.openSettingsHandler = ^{
        [weakSelf statusBarDidSelectSetupWizard];
    };
    // After the launch has settled, so the offer does not land on top of the permission prompts.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!weakSelf.quitting && !weakSelf.onboardingAtLaunch &&
            sessionStateAllowsConfigReload(weakSelf.sessionState)) {
            [weakSelf.localAsrOffer offerIfNeeded];
        }
    });
    [SPAppUpdateChecker checkIfDueWithHandler:^(NSString *version, NSURL *page, BOOL isNew) {
        [weakSelf.statusBarManager showAppUpdateVersion:version];
        if (isNew) {
            [weakSelf showInfoMessage:[NSString stringWithFormat:@"Доступна новая версия %@: ссылка в меню приложения", version]];
        }
    }];
    if (configFlagEnabled("experimental.lips")) {
        [[SPLipsRuntime sharedRuntime] checkForModelUpdateWithHandler:^(NSString *tag) {
            weakSelf.pendingLipsModelTag = tag;
            [weakSelf.statusBarManager showLipsModelUpdate:tag];
            [weakSelf showInfoMessage:[NSString stringWithFormat:@"Есть новая модель губ %@: обновить можно в меню", tag]];
        }];
    }
}

- (void)statusBarDidSelectAppUpdate {
    [[NSWorkspace sharedWorkspace] openURL:[SPAppUpdateChecker knownReleasePage]];
}

- (void)statusBarDidSelectLipsModelUpdate {
    NSString *tag = self.pendingLipsModelTag;
    if (!tag) return;
    __weak typeof(self) weakSelf = self;
    [[SPLipsRuntime sharedRuntime] offerModelUpdate:tag completion:^(BOOL updated) {
        if (!updated) return;
        weakSelf.pendingLipsModelTag = nil;
        [weakSelf.statusBarManager showLipsModelUpdate:nil];
    }];
}

- (void)statusBarDidSelectReportProblem {
    if (!self.problemReport) self.problemReport = [[SPProblemReportWindowController alloc] init];
    [self.problemReport present];
}

#pragma mark - Extra hotkeys (translate, ask)

- (SPHotkeyMonitor *)extraHotkeyMonitorForConfig:(struct SPHotkeyConfig)config
                                           proxy:(SPHotkeyPurposeProxy *)proxy {
    if (config.trigger_key_code == 0) return nil;
    SPHotkeyMonitor *monitor = [[SPHotkeyMonitor alloc] initWithDelegate:proxy];
    monitor.targetKeyCode = config.trigger_key_code;
    monitor.altKeyCode = config.trigger_alt_key_code;
    monitor.targetModifierFlag = config.trigger_modifier_flag;
    monitor.targetMatchKind = config.trigger_match_kind;
    monitor.triggerMode = (SPHotkeyTriggerMode)config.trigger_mode;
    [monitor start];
    return monitor;
}

- (void)rebuildExtraHotkeyMonitors {
    [self.mediaKeyMonitor stop];
    self.mediaKeyMonitor = nil;
    if (configFlagEnabled("hotkey.media_play_pause")) {
        __weak typeof(self) weakSelf = self;
        self.mediaKeyMonitor = [[SPMediaKeyMonitor alloc] initWithHandler:^{
            [weakSelf statusBarDidSelectToggleVoiceInput];
        }];
        [self.mediaKeyMonitor start];
    }

    [self.translateHotkeyMonitor stop];
    [self.askHotkeyMonitor stop];
    [self.editHotkeyMonitor stop];
    [self.undoHotkeyMonitor stop];
    [self.repasteHotkeyMonitor stop];
    [self.modeHotkeyMonitor stop];
    [self.mouseHotkeyMonitor stop];

    if (!self.translateHotkeyProxy) {
        self.translateHotkeyProxy = [[SPHotkeyPurposeProxy alloc] init];
        self.translateHotkeyProxy.target = self;
        self.translateHotkeyProxy.purpose = SPSessionPurposeTranslate;
        self.askHotkeyProxy = [[SPHotkeyPurposeProxy alloc] init];
        self.askHotkeyProxy.target = self;
        self.askHotkeyProxy.purpose = SPSessionPurposeAsk;
        self.editHotkeyProxy = [[SPHotkeyPurposeProxy alloc] init];
        self.editHotkeyProxy.target = self;
        self.editHotkeyProxy.purpose = SPSessionPurposeEdit;
    }
    self.translateHotkeyMonitor =
        [self extraHotkeyMonitorForConfig:sp_core_get_extra_hotkey_config(1)
                                    proxy:self.translateHotkeyProxy];
    self.askHotkeyMonitor =
        [self extraHotkeyMonitorForConfig:sp_core_get_extra_hotkey_config(2)
                                    proxy:self.askHotkeyProxy];
    self.editHotkeyMonitor =
        [self extraHotkeyMonitorForConfig:sp_core_get_extra_hotkey_config(5)
                                    proxy:self.editHotkeyProxy];
    [self applyAbortKeyConfig:sp_core_get_extra_hotkey_config(3)];
    [self rebuildModeAndMouseMonitors];
    [self rebuildLipsMonitor];
    NSLog(@"[VelikiyMoguchiy] Extra hotkeys: translate=%@ ask=%@ edit=%@ undo=%@ repaste=%@ mode=%@ mouse=%@ lips=%@",
          self.translateHotkeyMonitor ? @"on" : @"off",
          self.askHotkeyMonitor ? @"on" : @"off",
          self.editHotkeyMonitor ? @"on" : @"off",
          self.undoHotkeyMonitor ? @"on" : @"off",
          self.repasteHotkeyMonitor ? @"on" : @"off",
          self.modeHotkeyMonitor ? @"on" : @"off",
          self.mouseHotkeyMonitor ? @"on" : @"off",
          self.lipsHotkeyMonitor ? @"on" : @"off");
}

/// A monitor for a key whose press runs one action (no recording).
- (SPHotkeyMonitor *)pressHotkeyMonitorForConfig:(struct SPHotkeyConfig)config
                                           proxy:(SPModeHotkeyProxy *)proxy {
    if (config.trigger_key_code == 0) return nil;
    SPHotkeyMonitor *monitor = [[SPHotkeyMonitor alloc] initWithDelegate:proxy];
    monitor.targetKeyCode = config.trigger_key_code;
    monitor.altKeyCode = config.trigger_alt_key_code;
    monitor.targetModifierFlag = config.trigger_modifier_flag;
    monitor.targetMatchKind = config.trigger_match_kind;
    // Toggle: any press and release is a "tap start", never a hold.
    monitor.triggerMode = SPHotkeyTriggerModeToggle;
    proxy.monitor = monitor;
    [monitor start];
    return monitor;
}

/// The output-mode key and the mouse button trigger (hotkey.mode_key,
/// hotkey.mouse_button). The mouse button is another source for the main
/// trigger's hold / toggle / auto state machine.
- (void)rebuildModeAndMouseMonitors {
    self.modeHotkeyMonitor = nil;
    struct SPHotkeyConfig modeConfig = sp_core_get_extra_hotkey_config(4);
    if (modeConfig.trigger_key_code != 0) {
        if (!self.modeHotkeyProxy) {
            self.modeHotkeyProxy = [[SPModeHotkeyProxy alloc] init];
            self.modeHotkeyProxy.target = self;
        }
        SPHotkeyMonitor *monitor = [[SPHotkeyMonitor alloc] initWithDelegate:self.modeHotkeyProxy];
        monitor.targetKeyCode = modeConfig.trigger_key_code;
        monitor.altKeyCode = modeConfig.trigger_alt_key_code;
        monitor.targetModifierFlag = modeConfig.trigger_modifier_flag;
        monitor.targetMatchKind = modeConfig.trigger_match_kind;
        // Toggle: any press and release is a "tap start", never a hold.
        monitor.triggerMode = SPHotkeyTriggerModeToggle;
        self.modeHotkeyProxy.monitor = monitor;
        [monitor start];
        self.modeHotkeyMonitor = monitor;
    }

    // Undo and re-paste keys act on a press like the output-mode key does.
    __weak typeof(self) weakSelf = self;
    if (!self.undoHotkeyProxy) {
        self.undoHotkeyProxy = [[SPModeHotkeyProxy alloc] init];
        self.undoHotkeyProxy.target = self;
        self.undoHotkeyProxy.onPress = ^{ [weakSelf undoLastInsertion]; };
        self.repasteHotkeyProxy = [[SPModeHotkeyProxy alloc] init];
        self.repasteHotkeyProxy.target = self;
        self.repasteHotkeyProxy.onPress = ^{ [weakSelf repasteLastDictation]; };
    }
    self.undoHotkeyMonitor = [self pressHotkeyMonitorForConfig:sp_core_get_extra_hotkey_config(6)
                                                         proxy:self.undoHotkeyProxy];
    self.repasteHotkeyMonitor = [self pressHotkeyMonitorForConfig:sp_core_get_extra_hotkey_config(7)
                                                            proxy:self.repasteHotkeyProxy];

    self.mouseHotkeyMonitor = nil;
    uint8_t button = sp_core_get_mouse_button();
    if (button != 0) {
        if (!self.mouseHotkeyProxy) {
            self.mouseHotkeyProxy = [[SPHotkeyPurposeProxy alloc] init];
            self.mouseHotkeyProxy.target = self;
            self.mouseHotkeyProxy.purpose = SPSessionPurposeDictate;
        }
        SPHotkeyMonitor *monitor = [[SPHotkeyMonitor alloc] initWithDelegate:self.mouseHotkeyProxy];
        monitor.targetMatchKind = SPHotkeyMatchKindMouseButton;
        monitor.targetKeyCode = button;
        monitor.altKeyCode = 0;
        monitor.targetModifierFlag = 0;
        monitor.triggerMode = (SPHotkeyTriggerMode)sp_core_get_hotkey_config().trigger_mode;
        [monitor start];
        self.mouseHotkeyMonitor = monitor;
    }
}

/// Every monitor that may hold a recording state returns to idle (a session
/// ended outside the normal hotkey flow).
- (void)resetAllHotkeyMonitorsToIdle {
    [self.hotkeyMonitor resetToIdle];
    [self.translateHotkeyMonitor resetToIdle];
    [self.askHotkeyMonitor resetToIdle];
    [self.editHotkeyMonitor resetToIdle];
    [self.mouseHotkeyMonitor resetToIdle];
}

/// Selected text of the focused element in the frontmost app, via Accessibility.
- (NSString *)copyFocusedSelectedText {
    AXUIElementRef systemWide = AXUIElementCreateSystemWide();
    CFTypeRef focused = NULL;
    AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute, &focused);
    CFRelease(systemWide);
    if (!focused) return nil;
    CFTypeRef selected = NULL;
    AXUIElementCopyAttributeValue((AXUIElementRef)focused, kAXSelectedTextAttribute, &selected);
    CFRelease(focused);
    if (!selected) return nil;
    NSString *text = nil;
    if (CFGetTypeID(selected) == CFStringGetTypeID()) {
        text = [(__bridge NSString *)selected copy];
    }
    CFRelease(selected);
    return text.length > 0 ? text : nil;
}

// Lipflow (amywork777/lipflow, vendored in vendor/lipflow) reads silently
// mouthed English from the webcam. It is a separate Python app with ~1.2 GB of
// models built by vendor/lipflow/setup.sh into /Applications/Lipflow.app and
// keeps its own push-to-talk key, so the app only launches it alongside.
- (void)launchLipflowIfEnabled {
    if (!configFlagEnabled("experimental.lipflow")) return;
    NSURL *url = [NSURL fileURLWithPath:@"/Applications/Lipflow.app"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
        NSLog(@"[VelikiyMoguchiy] experimental.lipflow is on but /Applications/Lipflow.app is missing; run vendor/lipflow/setup.sh");
        return;
    }
    NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
    configuration.activates = NO;
    [[NSWorkspace sharedWorkspace] openApplicationAtURL:url
                                          configuration:configuration
                                      completionHandler:^(NSRunningApplication *app, NSError *error) {
        if (error) NSLog(@"[VelikiyMoguchiy] Failed to launch Lipflow: %@", error);
    }];
}

// Bundled mic-warm (drewburchfield/macos-mic-keepwarm) holds the input device
// open so push-to-talk does not wait 2-5 s for the mic or Bluetooth SCO to
// wake. It keeps the orange mic indicator on, hence opt-in.
//
// Called at launch and after every config reload, so the helper follows
// experimental.keep_mic_warm in both directions. It is told our pid
// (--parent-pid) and exits by itself when we are gone, so a crash or SIGKILL
// of the app cannot leave it holding the microphone.
- (void)startMicWarmIfEnabled {
    if (!configFlagEnabled("experimental.keep_mic_warm")) {
        [self stopMicWarm];
        return;
    }
    if (self.micWarmTask.isRunning) return;

    NSString *path = [[NSBundle mainBundle] pathForAuxiliaryExecutable:@"mic-warm"];
    if (!path) {
        NSLog(@"[VelikiyMoguchiy] keep_mic_warm enabled but mic-warm helper is missing from the bundle");
        return;
    }
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:path];
    task.arguments = @[ @"--parent-pid", [NSString stringWithFormat:@"%d", getpid()] ];
    task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        NSLog(@"[VelikiyMoguchiy] Failed to launch mic-warm: %@", error);
        return;
    }
    self.micWarmTask = task;
    NSLog(@"[VelikiyMoguchiy] mic-warm helper started (pid %d)", task.processIdentifier);
}

/// Stop the helper: SIGTERM first, SIGKILL if it has not left shortly after.
- (void)stopMicWarm {
    NSTask *task = self.micWarmTask;
    self.micWarmTask = nil;
    if (!task || !task.isRunning) return;
    pid_t pid = task.processIdentifier;
    [task terminate];
    for (int i = 0; i < 30 && task.isRunning; i++) {
        usleep(10 * 1000);
    }
    if (task.isRunning) {
        NSLog(@"[VelikiyMoguchiy] mic-warm ignored SIGTERM; killing it");
        kill(pid, SIGKILL);
    }
    NSLog(@"[VelikiyMoguchiy] mic-warm helper stopped");
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    NSLog(@"[VelikiyMoguchiy] Application terminating...");
    self.quitting = YES;
    self.sessionWantsAudioCapture = NO;
    // Stop the hotkey monitor before any slow teardown so its event tap
    // cannot stall the session keyboard stream (see statusBarDidSelectQuit).
    // Safe to call twice — stop() is idempotent.
    [self.hotkeyMonitor stop];
    [self.translateHotkeyMonitor stop];
    [self.askHotkeyMonitor stop];
    [self.editHotkeyMonitor stop];
    [self.undoHotkeyMonitor stop];
    [self.repasteHotkeyMonitor stop];
    [self.modeHotkeyMonitor stop];
    [self.mouseHotkeyMonitor stop];
    [self.lipsHotkeyMonitor stop];
    [self stopSilenceAutoStop];
    [self cancelPendingSessionEnd];
    // Cancel any scheduled CGEventPost paste/undo blocks. The status-bar quit
    // path already does this, but termination can also start elsewhere
    // (Sparkle update relaunch, logout/shutdown) — without the cancel, a
    // pending synthetic paste can still fire during run-loop draining and
    // leak key events into whichever app is focused.
    [self.pasteManager cancel];
    [self stopMicWarm];
    [self.mediaKeyMonitor stop];
    [self.audioCaptureManager shutdown];
    [self recordUnfinishedSessionWithStatus:@"cancelled"];
    [self discardArmedLipClip];
    [[SPRecordingManager sharedManager] endRecordingAndWait];
    [[SPLipCaptureManager sharedManager] shutdown];
    [[SPLipsService sharedService] shutdown];
    // Safety net: restore device mute even if capture state was already cleared.
    // Device mute is a persistent system property — leaving it on after quit is bad.
    [self.audioCaptureManager restoreMutedSystemOutputIfNeeded];
    if (self.configWatcher) {
        dispatch_source_cancel(self.configWatcher);
        self.configWatcher = nil;
    }
    [self.audioDeviceManager stopListening];
    [self.rustBridge destroyCore];
}

#pragma mark - Edit Menu (for Cmd+C/V in text fields)

- (void)installEditMenu {
    NSMenu *mainMenu = [NSApp mainMenu];
    if (!mainMenu) {
        mainMenu = [[NSMenu alloc] init];
        [NSApp setMainMenu:mainMenu];
    }

    NSMenuItem *editMenuItem = [[NSMenuItem alloc] initWithTitle:SPLocalizedString(@"menu.edit") action:nil keyEquivalent:@""];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:SPLocalizedString(@"menu.edit")];

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
    [editMenu addItemWithTitle:SPLocalizedString(@"menu.edit.undo") action:@selector(undo:) keyEquivalent:@"z"];
    [editMenu addItemWithTitle:SPLocalizedString(@"menu.edit.redo") action:@selector(redo:) keyEquivalent:@"Z"];
#pragma clang diagnostic pop
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:SPLocalizedString(@"menu.edit.cut") action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:SPLocalizedString(@"menu.edit.copy") action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:SPLocalizedString(@"menu.edit.paste") action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:SPLocalizedString(@"menu.edit.selectAll") action:@selector(selectAll:) keyEquivalent:@"a"];

    editMenuItem.submenu = editMenu;
    [mainMenu addItem:editMenuItem];
}

#pragma mark - Config File Watcher

- (void)startConfigWatcher {
    NSString *configPath = SPAppDataPath(@"config.yaml");

    // Record initial modification time
    struct stat st;
    if (stat(configPath.UTF8String, &st) == 0) {
        self.lastConfigModTime = st.st_mtime;
    }

    // Check config file modification every 3 seconds
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), 3 * NSEC_PER_SEC, 1 * NSEC_PER_SEC);

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        [weakSelf checkConfigFileChanged];
    });

    dispatch_resume(timer);
    self.configWatcher = timer;
    NSLog(@"[VelikiyMoguchiy] Config file watcher started (polling every 3s)");
}

- (void)checkConfigFileChanged {
    NSString *configPath = SPAppDataPath(@"config.yaml");

    struct stat st;
    if (stat(configPath.UTF8String, &st) != 0) return;

    if (st.st_mtime == self.lastConfigModTime) return;
    self.lastConfigModTime = st.st_mtime;

    NSLog(@"[VelikiyMoguchiy] Config file changed, scheduling config reload...");

    [self reloadConfigAndApplyHotkeyIfSafe];
}

#pragma mark - SPHotkeyMonitorDelegate

- (void)cancelPendingSessionEnd {
    if (self.pendingSessionEndBlock) {
        dispatch_block_cancel(self.pendingSessionEndBlock);
        self.pendingSessionEndBlock = nil;
    }
}

- (void)hotkeyMonitorDidBeginTrigger {
    [self beginTriggerForPurpose:SPSessionPurposeDictate];
}

- (void)beginTriggerForPurpose:(SPSessionPurpose)purpose {
    // Without the microphone the hold / tap decision only explains why nothing starts.
    if (![self.permissionManager isMicrophoneGranted]) return;
    // This callback occurs on the initial key-down, before the 180ms hold/tap
    // decision. Starting the already-prepared queue here makes the microphone
    // privacy indicator and Bluetooth route activation begin immediately.
    if (self.pendingSessionEndBlock) {
        [self cancelPendingSessionEnd];
        self.preCaptureInterruptedPendingSessionEnd = YES;
    }
    [self.audioCaptureManager setInputDeviceID:[self.audioDeviceManager resolvedDeviceID]];
    if (![self.audioCaptureManager beginPreCapture]) {
        NSLog(@"[VelikiyMoguchiy] Trigger-down audio pre-capture failed; confirmed session will retry");
    }
    // The camera warms up alongside the microphone, for dictation only.
    [self discardArmedLipClip];
    if (purpose == SPSessionPurposeDictate) {
        self.armedLipClip = [[SPLipCaptureManager sharedManager] beginPreCapture];
    }
}

- (void)hotkeyMonitorDidCancelTrigger {
    [self.audioCaptureManager cancelPreCapture];
    [self discardArmedLipClip];
    if (self.preCaptureInterruptedPendingSessionEnd) {
        self.preCaptureInterruptedPendingSessionEnd = NO;
        self.sessionWantsAudioCapture = NO;
        [self.audioCaptureManager stopCapture];
        [[SPRecordingManager sharedManager] endRecording];
        [[SPLipCaptureManager sharedManager] endClip:self.sessionLipClip];
        [self.rustBridge endSession];
    }
}

/// Begin a Rust session and capture per-session state shared by the hold and
/// tap start paths. Returns NO (after surfacing the error) when the session
/// could not be started.
- (BOOL)beginRustSessionWithMode:(SPSessionModeObjC)mode {
    SPSessionPurpose requested = self.pendingSessionPurpose;
    self.pendingSessionPurpose = SPSessionPurposeDictate;
    NSString *selectedText = nil;
    self.editAnchor = nil;
    if (requested == SPSessionPurposeEdit) {
        // The selection and the focused field are captured now, before the
        // user speaks: the result replaces exactly this selection.
        SPSelectionAnchor *anchor = [SPSelectionAnchor captureFocused];
        selectedText = anchor.selectedText;
        requested = [SPTextEditPolicy effectivePurposeForRequested:requested selectedText:selectedText];
        if (requested == SPSessionPurposeEdit && !sp_core_edit_supported()) {
            NSLog(@"[VelikiyMoguchiy] Edit needs a DashScope key (it runs on Qwen Omni) — behaving like Ask");
            requested = SPSessionPurposeAsk;
        }
        if (requested == SPSessionPurposeEdit) {
            self.editAnchor = anchor;
            NSLog(@"[VelikiyMoguchiy] Edit session: %lu selected chars", (unsigned long)selectedText.length);
        } else {
            // Nothing (usable) selected: never paste, answer like Ask.
            NSLog(@"[VelikiyMoguchiy] Edit key without an editable selection (%lu chars) — behaving like Ask",
                  (unsigned long)selectedText.length);
        }
    } else if (requested == SPSessionPurposeAsk) {
        selectedText = [self copyFocusedSelectedText];
        NSLog(@"[VelikiyMoguchiy] Ask session: %lu selected chars", (unsigned long)selectedText.length);
    }
    self.sessionPurpose = requested;
    sp_core_set_next_session_purpose(self.sessionPurpose, selectedText.UTF8String);
    // The overlay's level bars must not start from the previous recording's tail.
    sp_core_reset_mic_levels();
    self.pendingDeliveryKind = SPTextDeliveryPasteAll;
    self.pendingDeliveryRemainder = nil;
    self.pendingSendRequest = NO;
    if (![self.rustBridge beginSessionWithMode:mode]) {
        [self handleAudioCaptureError:kSessionStartFailure];
        return NO;
    }
    // Snapshot the effective clipboard restoration policy for this session.
    // Rust hot-reloads config inside session_begin, so this is the validated
    // value governing this session; edits apply from the next session.
    [self.clipboardRestorePolicy
        captureSessionRestoreDelayMs:sp_core_get_clipboard_config().restore_delay_ms];
    self.loggedFirstRecognitionForActivation = NO;
    self.recognitionMetricActivationSequence = self.audioCaptureManager.activationSequence;
    self.recognitionMetricSessionToken = self.rustBridge.currentSessionToken;
    return YES;
}

- (void)hotkeyMonitorDidDetectHoldStart {
    NSLog(@"[VelikiyMoguchiy] Hold start detected");
    if ([self refuseTriggerWithoutMicrophone]) return;
    [self deactivateRawAsrFallbackInteraction];
    [self.audioCaptureManager logActivationMilestone:@"hold decision"];
    [self stopNumberKeyMonitoring];
    [self stopAnyKeyDismissMonitoring];
    [self.overlayPanel hideTemplateButtons];
    self.showingError = NO;
    [self cancelPendingSessionEnd];
    self.sessionWantsAudioCapture = YES;
    self.preCaptureInterruptedPendingSessionEnd = NO;
    if (self.audioCaptureManager.isCapturing && !self.audioCaptureManager.isPreCapturing) {
        [self.audioCaptureManager stopCapture];
    }

    self.recordingStartTime = [NSDate date];
    self.sessionState = @"recording_hold";
    [self armAbortKey];
    [self.cuePlayer reloadFeedbackConfig];
    [self.cuePlayer playStart];
    [self.statusBarManager updateState:@"recording"];
    [self.overlayPanel updateState:@"recording"];

    // Start Rust session + audio capture
    if (![self beginRustSessionWithMode:SPSessionModeHold]) return;
    [self startAudioCaptureWithRetryIncludingPreRoll:YES];
    [self startMicSilenceWatch];
    [self startRecordingCap];
}

- (void)hotkeyMonitorDidDetectHoldEnd {
    NSLog(@"[VelikiyMoguchiy] Hold end detected");
    [self.cuePlayer playStop];

    // Keep recording for 300ms after Fn release to capture trailing speech,
    // then stop mic and end session.  Use a cancellable block so a rapid
    // re-press can prevent the stale endSession from killing the new session.
    [self cancelPendingSessionEnd];
    self.preCaptureInterruptedPendingSessionEnd = NO;
    dispatch_block_t block = dispatch_block_create(0, ^{
        self.pendingSessionEndBlock = nil;
        self.sessionWantsAudioCapture = NO;
        [self.audioCaptureManager stopCapture];
        [[SPRecordingManager sharedManager] endRecording];
        [[SPLipCaptureManager sharedManager] endClip:self.sessionLipClip];
        [self.rustBridge endSession];
    });
    self.pendingSessionEndBlock = block;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), block);
}

- (void)hotkeyMonitorDidCancelHoldForCompanionInput {
    // Trigger held together with another key (Fn+brightness, Cmd-C): not a
    // dictation request. Same teardown as the abort key.
    NSLog(@"[VelikiyMoguchiy] Hold trigger combined with another key — aborting session");
    [self abortActiveSession];
}

- (void)hotkeyMonitorDidDetectTapStart {
    NSLog(@"[VelikiyMoguchiy] Tap start detected");
    if ([self refuseTriggerWithoutMicrophone]) return;
    [self deactivateRawAsrFallbackInteraction];
    [self.audioCaptureManager logActivationMilestone:@"tap decision"];
    [self stopNumberKeyMonitoring];
    [self stopAnyKeyDismissMonitoring];
    [self.overlayPanel hideTemplateButtons];
    self.showingError = NO;
    [self cancelPendingSessionEnd];
    self.sessionWantsAudioCapture = YES;
    self.preCaptureInterruptedPendingSessionEnd = NO;
    if (self.audioCaptureManager.isCapturing && !self.audioCaptureManager.isPreCapturing) {
        [self.audioCaptureManager stopCapture];
    }

    self.recordingStartTime = [NSDate date];
    self.sessionState = @"recording_toggle";
    [self armAbortKey];
    [self.cuePlayer reloadFeedbackConfig];
    [self.cuePlayer playStart];
    [self.statusBarManager updateState:@"recording"];
    [self.overlayPanel updateState:@"recording"];

    if (![self beginRustSessionWithMode:SPSessionModeToggle]) return;
    [self startAudioCaptureWithRetryIncludingPreRoll:NO];
    [self startSilenceAutoStopIfConfigured];
    [self startMicSilenceWatch];
    [self startRecordingCap];
    [self showHandsFreeHintIfNeeded];
}

#pragma mark - Recording limit and first-use hints

/// recording.max_duration_s: a recording left running (a forgotten hands-free
/// one, a stuck key) ends the way the user would have ended it.
- (void)startRecordingCap {
    [self.recordingCapTimer invalidate];
    self.recordingCapTimer = nil;
    float seconds = sp_core_recording_cap_seconds();
    if (seconds <= 0) return;
    uint64_t token = self.rustBridge.currentSessionToken;
    __weak typeof(self) weakSelf = self;
    self.recordingCapTimer = [NSTimer scheduledTimerWithTimeInterval:seconds
                                                             repeats:NO
                                                               block:^(NSTimer *timer) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || token != strongSelf.rustBridge.currentSessionToken) return;
        NSString *state = strongSelf.sessionState;
        if (![state hasPrefix:@"recording"]) return;
        NSLog(@"[VelikiyMoguchiy] Recording reached its %.0fs limit — ending it", seconds);
        if ([state isEqualToString:@"recording_hold"]) {
            [strongSelf hotkeyMonitorDidDetectHoldEnd];
            [strongSelf resetAllHotkeyMonitorsToIdle];
        } else {
            [strongSelf stopSilenceAutoStop];
            [strongSelf endHandsFreeRecordingLikeSecondTap];
        }
        [strongSelf showInfoMessage:[NSString stringWithFormat:
            @"Запись остановлена: прошло %.0f мин. Предел меняется в Настройках → Управление → Запись.",
            seconds / 60.0]];
    }];
}

/// The trigger's name for a sentence, "клавишу" when it has none.
- (NSString *)triggerKeyShortName {
    return SPHotkeyShortName(configStringValue("hotkey.trigger_key")) ?: @"клавишу";
}

/// Shows a first-use hint while its counter is below the limit. YES when shown.
- (BOOL)takeFirstUseHint:(NSString *)counterKey {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSInteger shown = [defaults integerForKey:counterKey];
    if (shown >= kFirstUseHintLimit) return NO;
    [defaults setInteger:shown + 1 forKey:counterKey];
    return YES;
}

/// The first hands-free recordings say how they end, next to the level bars.
- (void)showHandsFreeHintIfNeeded {
    if (self.hotkeyMonitor.abortKeyCode != kEscapeKeyCode) return;
    if (![self takeFirstUseHint:kHandsFreeHintCountKey]) return;
    [self.overlayPanel setRecordingHint:[NSString stringWithFormat:@"Ещё раз %@ — готово · Esc — отмена",
                                                                   [self triggerKeyShortName]]];
}

- (void)hotkeyMonitorDidIgnoreShortPress {
    if (!sessionStateAllowsConfigReload(self.sessionState)) return;
    if (![self takeFirstUseHint:kHoldHintCountKey]) return;
    [self.overlayPanel showMessage:[NSString stringWithFormat:@"Держите %@ и говорите", [self triggerKeyShortName]]
                              icon:SPOverlayMessageIconNotice];
}

#pragma mark - A microphone that gives nothing

/// After a couple of seconds of a recording whose input never rose above
/// digital silence, the pill says so next to its level bars.
- (void)startMicSilenceWatch {
    [self.micSilenceTimer invalidate];
    uint64_t token = self.rustBridge.currentSessionToken;
    NSDate *started = [NSDate date];
    __block BOOL hintShown = NO;
    __weak typeof(self) weakSelf = self;
    self.micSilenceTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                           repeats:YES
                                                             block:^(NSTimer *timer) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || token != strongSelf.rustBridge.currentSessionToken ||
            ![strongSelf.sessionState hasPrefix:@"recording"]) {
            [timer invalidate];
            return;
        }
        if (-started.timeIntervalSinceNow < kMicSilenceHintDelay) return;
        if (sp_core_mic_peak() < kSilentMicPeak) {
            [strongSelf.overlayPanel setRecordingHint:@"Микрофон молчит"];
            hintShown = YES;
            return;
        }
        // Another hint (the hands-free one) stays; only this one is taken back.
        if (hintShown) [strongSelf.overlayPanel setRecordingHint:nil];
        [timer invalidate];
    }];
}

/// The core heard no speech: the pill says why nothing was typed, and the
/// recording stays listed in «Последние диктовки».
- (void)finishSessionWithoutSpeech {
    // A short press can end before a slow (Bluetooth) microphone delivers its first sound.
    BOOL longEnough = self.recordingStartTime && -self.recordingStartTime.timeIntervalSinceNow >= kMicSilenceHintDelay;
    BOOL micSilent = longEnough && sp_core_mic_peak() < kSilentMicPeak;
    [self.micSilenceTimer invalidate];
    self.sessionState = @"idle";
    [self disarmAbortKey];
    [self deactivateRawAsrFallbackInteraction];
    self.sessionPurpose = SPSessionPurposeDictate;
    self.editAnchor = nil;
    [self recordUnfinishedSessionWithStatus:@"empty"
                                      error:micSilent ? @"микрофон не дал звука" : @"в записи не было речи"];
    [self.statusBarManager updateState:@"idle"];
    if (micSilent) {
        [self.overlayPanel showMessage:@"Микрофон молчит — проверьте вход в меню значка"
                                  icon:SPOverlayMessageIconNotice];
    } else {
        [self.overlayPanel showMessage:@"Не расслышал" icon:SPOverlayMessageIconNoSpeech];
    }
    [self applyDeferredConfigReloadIfNeeded];
}

#pragma mark - Silence auto-stop (hands-free recordings)

/// Watches the mic level (recording.auto_stop_silence_s) for a hands-free
/// recording. Never armed for hold sessions: only the tap-start path calls it.
- (void)startSilenceAutoStopIfConfigured {
    [self stopSilenceAutoStop];
    float seconds = sp_core_silence_stop_seconds();
    if (seconds <= 0) return;
    sp_core_silence_stop_arm(seconds);
    uint64_t token = self.rustBridge.currentSessionToken;
    __weak typeof(self) weakSelf = self;
    self.silenceStopTimer = [NSTimer scheduledTimerWithTimeInterval:0.2
                                                            repeats:YES
                                                              block:^(NSTimer *timer) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            [timer invalidate];
            return;
        }
        BOOL stillRecording = token == strongSelf.rustBridge.currentSessionToken &&
                              [strongSelf.sessionState isEqualToString:@"recording_toggle"];
        if (!stillRecording) {
            [strongSelf stopSilenceAutoStop];
            return;
        }
        if (!sp_core_silence_stop_fired()) return;
        NSLog(@"[VelikiyMoguchiy] Silence after speech for %.0fs — ending the hands-free recording", seconds);
        [strongSelf stopSilenceAutoStop];
        [strongSelf endHandsFreeRecordingLikeSecondTap];
    }];
}

- (void)stopSilenceAutoStop {
    [self.silenceStopTimer invalidate];
    self.silenceStopTimer = nil;
    sp_core_silence_stop_arm(0);
}

/// What a second tap on the trigger does: the same delegate path, plus the
/// state machines return to idle because no key event drives them this time.
- (void)endHandsFreeRecordingLikeSecondTap {
    [self hotkeyMonitorDidDetectTapEnd];
    [self resetAllHotkeyMonitorsToIdle];
}

- (void)hotkeyMonitorDidDetectTapEnd {
    NSLog(@"[VelikiyMoguchiy] Tap end detected");
    [self.cuePlayer playStop];

    // Keep recording for 300ms after tap-end to capture trailing speech,
    // then stop mic and end session.  Use a cancellable block (same as hold).
    [self cancelPendingSessionEnd];
    dispatch_block_t block = dispatch_block_create(0, ^{
        self.pendingSessionEndBlock = nil;
        self.sessionWantsAudioCapture = NO;
        [self.audioCaptureManager stopCapture];
        [[SPRecordingManager sharedManager] endRecording];
        [[SPLipCaptureManager sharedManager] endClip:self.sessionLipClip];
        [self.rustBridge endSession];
    });
    self.pendingSessionEndBlock = block;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), block);
}

#pragma mark - Audio Capture Start with Retry

- (void)startAudioCaptureWithRetryIncludingPreRoll:(BOOL)includePreRoll {
    struct SPFeedbackConfig feedbackConfig = sp_core_get_feedback_config();
    self.audioCaptureManager.muteOutputEnabled = feedbackConfig.mute_system_output;
    [self.audioCaptureManager setInputDeviceID:[self.audioDeviceManager resolvedDeviceID]];
    uint64_t token = self.rustBridge.currentSessionToken;
    [self recordUnfinishedSessionWithStatus:@"cancelled"];
    [self adoptLipClipForNewSession];
    NSString *audioPath = [[SPRecordingManager sharedManager] beginRecording];
    self.sessionAudioPath = audioPath;
    self.sessionAppBundleId = self.rustBridge.currentSessionBundleId;
    SPAudioFrameCallback callback = ^(const void *buffer, uint32_t length, uint64_t timestamp) {
        [self.rustBridge pushAudioFrame:buffer length:length timestamp:timestamp];
        if (audioPath) [[SPRecordingManager sharedManager] appendPCM:buffer length:length];
    };

    // AudioQueue capture starts cheaply without blocking the main thread, so a
    // synchronous start is fine here.
    if ([self.audioCaptureManager startCaptureWithAudioCallback:callback
                                                 includePreRoll:includePreRoll]) return;

    // After a device route change or fresh permission grant the audio
    // subsystem may need a moment to settle. Retry once after a short delay.
    NSLog(@"[VelikiyMoguchiy] Audio capture failed on first attempt, retrying in 500ms...");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(500 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        if (token != self.rustBridge.currentSessionToken) return;
        if (self.quitting) return;
        if (!self.sessionWantsAudioCapture) return;

        struct SPFeedbackConfig retryFeedback = sp_core_get_feedback_config();
        self.audioCaptureManager.muteOutputEnabled = retryFeedback.mute_system_output;
        [self.audioCaptureManager setInputDeviceID:[self.audioDeviceManager resolvedDeviceID]];
        if ([self.audioCaptureManager startCaptureWithAudioCallback:callback
                                                     includePreRoll:includePreRoll]) {
            NSLog(@"[VelikiyMoguchiy] Audio capture started on retry");
            return;
        }
        [self handleAudioCaptureError:@"Не удалось начать запись звука"];
    });
}

#pragma mark - SPRustBridgeDelegate

- (void)rustBridgeDidBecomeReady {
    NSLog(@"[VelikiyMoguchiy] Session ready (ASR connected)");
    // A fresh session invalidates any instant-paste state from a session
    // that was cancelled between its raw paste and its LLM correction.
    self.instantPastedText = nil;
    [self.instantPasteGuard reset];
    if (self.rustBridge.currentSessionToken == self.recognitionMetricSessionToken) {
        [self.audioCaptureManager logActivationMilestone:@"ASR ready"
                                   forActivationSequence:self.recognitionMetricActivationSequence];
    }
}

- (void)rustBridgeDidReceiveFinalText:(NSString *)text {
    if (self.quitting) return;
    self.sessionState = @"idle";
    [self disarmAbortKey];
    NSLog(@"[VelikiyMoguchiy] Final text received (%lu chars)", (unsigned long)text.length);
    self.llmCorrectionInProgress = NO;
    [self deactivateRawAsrFallbackInteraction];

    // Record history
    NSInteger durationMs = [self takeSessionDurationMs];
    NSString *appBundleId = self.sessionAppBundleId;
    self.sessionAppBundleId = nil;
    SPSessionPurpose purpose = self.sessionPurpose;
    // A voice edit keeps the replaced selection as the row's original text.
    NSString *editOriginal = purpose == SPSessionPurposeEdit ? self.editAnchor.selectedText : nil;
    [[SPHistoryManager sharedManager] recordSessionWithDurationMs:durationMs
                                                             text:text
                                                          asrText:self.pendingMetaAsrText
                                                      asrProvider:self.pendingMetaAsrProvider
                                                       llmApplied:self.pendingMetaLlmApplied
                                                           status:text.length > 0 ? @"ok" : @"empty"
                                                        audioPath:[self takeFinishedSessionAudioPath]
                                                            error:text.length > 0 ? nil : @"в записи не было речи"
                                                      appBundleId:appBundleId
                                                     originalText:editOriginal];
    if (text.length > 0 && [SPTextEditPolicy purposeCountsAsDictation:purpose]) {
        self.lastDictationText = text;
    }
    // The camera clip is judged on the raw recognized text (before the LLM and
    // snippets): that is what was actually spoken.
    [self resolveSessionLipClipWithStatus:text.length > 0 ? @"ok" : @"empty"
                                finalText:text
                              appBundleId:appBundleId];
    self.pendingMetaAsrText = nil;
    self.pendingMetaAsrProvider = nil;
    self.pendingMetaLlmApplied = NO;

    SPTextDelivery delivery = (SPTextDelivery)self.pendingDeliveryKind;
    NSString *remainder = self.pendingDeliveryRemainder;
    BOOL sendRequested = self.pendingSendRequest;
    self.pendingDeliveryKind = SPTextDeliveryPasteAll;
    self.pendingDeliveryRemainder = nil;
    self.pendingSendRequest = NO;

    if (delivery == SPTextDeliveryAlreadyTyped) {
        // The core typed the text into the field and already sent Return when
        // paste.auto_return is on (it re-checks the focused field first).
        NSLog(@"[VelikiyMoguchiy] Text already typed into the field; skipping paste");
        [self recordInsertionOfText:text originalText:nil];
        if (keepLastDictationEnabled()) {
            [self.clipboardManager cancelPendingRestore];
            [self.clipboardManager writeTransientText:text];
        }
        [self.overlayPanel updateDisplayText:text];
        [self.overlayPanel updateState:@"pasting"];
        [self.statusBarManager updateState:@"idle"];
        [self showPromptTemplateButtonsIfNeededOrDismiss];
        [self applyDeferredConfigReloadIfNeeded];
        return;
    }

    if (delivery == SPTextDeliveryClipboardOnly) {
        // A partial draft sits in a field we can no longer reach safely. Pasting
        // the full text would duplicate it, so hand it over via the clipboard.
        NSLog(@"[VelikiyMoguchiy] Typed draft cannot be completed safely; text copied to clipboard only");
        [self.clipboardManager cancelPendingRestore];
        [self.clipboardManager writeText:text];
        [self.statusBarManager updateState:@"idle"];
        [self.overlayPanel showMessage:@"Не вставилось целиком — текст в буфере, ⌘V"
                                  icon:SPOverlayMessageIconClipboard];
        [self applyDeferredConfigReloadIfNeeded];
        return;
    }

    // A prefix is already in the field: paste only what is missing.
    NSString *pasteText = (delivery == SPTextDeliveryPasteRemainder && remainder.length > 0)
                              ? remainder
                              : text;
    if (pasteText != text) {
        NSLog(@"[VelikiyMoguchiy] Pasting the remaining %lu chars after a partial typed draft",
              (unsigned long)pasteText.length);
    }

    if (purpose == SPSessionPurposeEdit) {
        self.sessionPurpose = SPSessionPurposeDictate;
        SPSelectionAnchor *anchor = self.editAnchor;
        self.editAnchor = nil;
        [self applyEditResult:text toSelection:anchor];
        [self applyDeferredConfigReloadIfNeeded];
        return;
    }

    if (self.sessionPurpose == SPSessionPurposeAsk) {
        self.sessionPurpose = SPSessionPurposeDictate;
        [self.clipboardManager cancelPendingRestore];
        [self.clipboardManager writeText:text];
        [self.statusBarManager updateState:@"idle"];
        [self.overlayPanel showMessage:[@"Ответ в буфере: " stringByAppendingString:[self firstLineOfText:text]]
                                  icon:SPOverlayMessageIconClipboard];
        [self applyDeferredConfigReloadIfNeeded];
        return;
    }

    // Experimental paste-ASR-first flow: the raw text is already in the
    // target app; apply the correction in place instead of pasting again.
    if ([self finishInstantPasteWithFinalText:text]) return;

    uint64_t token = self.rustBridge.currentSessionToken;
    SPPasteInjectionGuard guard = [self injectionGuardForSessionToken:token];
    BOOL shouldAutoPaste = [self shouldAutoPasteProcessedText];
    BOOL accessOK = [self.permissionManager isAccessibilityGranted];
    BOOL canAutoPaste = shouldAutoPaste && accessOK;
    BOOL keepLastDictation = keepLastDictationEnabled();
    NSLog(@"[VelikiyMoguchiy] Accessibility granted: %@", accessOK ? @"YES" : @"NO");

    SPPasteTarget target = canAutoPaste ? [self.accessibilityManager pasteTargetForFocusedElement] : SPPasteTargetPaste;
    if (target == SPPasteTargetSecure) {
        // Dictated text never goes into a password field, nor onto the clipboard for one.
        NSLog(@"[VelikiyMoguchiy] Focus is a password field; the text is not pasted");
        [self.statusBarManager updateState:@"idle"];
        [self.overlayPanel showMessage:@"Поле пароля — текст не вставлен" icon:SPOverlayMessageIconNotice];
        [self applyDeferredConfigReloadIfNeeded];
        return;
    }
    if (target == SPPasteTargetNone) {
        NSLog(@"[VelikiyMoguchiy] Nothing that takes text has focus; the text goes to the clipboard");
        [self.clipboardManager cancelPendingRestore];
        [self.clipboardManager writeText:text];
        [self.statusBarManager updateState:@"idle"];
        [self.overlayPanel showMessage:@"Некуда вставить — текст в буфере, ⌘V" icon:SPOverlayMessageIconClipboard];
        [self applyDeferredConfigReloadIfNeeded];
        return;
    }

    if (canAutoPaste) {
        // Show corrected text in overlay before pasting
        [self.overlayPanel updateDisplayText:text];
        [self.statusBarManager updateState:@"pasting"];
        [self.overlayPanel updateState:@"pasting"];

        // Auto-paste flow temporarily backs up the clipboard, then restores it,
        // unless the last dictation is meant to stay on the clipboard.
        if (keepLastDictation) {
            [self.clipboardManager cancelPendingRestore];
            [self.clipboardManager writeTransientText:pasteText];
        } else {
            // The text is only a paste vehicle: keep it out of clipboard
            // histories (transient + auto-generated markers).
            [self.clipboardManager backup];
            [self.clipboardManager writeTransientText:pasteText];
        }

        // The spoken "отправь" goes through the same guarded Return as the
        // setting: it is only sent if this paste was actually injected.
        BOOL autoReturn = configFlagEnabled("paste.auto_return") || sendRequested;
        [self.pasteManager simulatePasteWithGuard:guard completion:^(BOOL posted) {
            // A newer session owns the clipboard and the UI now; this
            // callback must not touch either. Checked BEFORE any side
            // effect, not just before the UI updates.
            if (token != self.rustBridge.currentSessionToken) return;
            NSLog(@"[VelikiyMoguchiy] Paste completion callback fired (posted=%d)", posted);
            if (posted) {
                // Taken before Return: after a sent message nothing is left to undo.
                [self recordInsertionOfText:text originalText:nil];
                // Return is only meaningful after the paste was actually
                // injected — otherwise it would submit whatever was already
                // in the target app's input field.
                if (autoReturn) {
                    [self.pasteManager simulateReturnKeyWithGuard:guard];
                }
                if (!keepLastDictation) {
                    [self.clipboardRestorePolicy scheduleRestoreForCurrentSession];
                    [self noteClipboardThatCannotComeBack];
                }
            } else {
                // Nothing was injected. Leave the text on the clipboard so
                // the user can paste manually; restoring the backup over it
                // would throw the transcript away.
                [self.clipboardManager cancelPendingRestore];
                [self.overlayPanel showMessage:@"Не вставилось — текст в буфере, ⌘V"
                                          icon:SPOverlayMessageIconClipboard];
            }
            [self.statusBarManager updateState:@"idle"];
            [self showPromptTemplateButtonsIfNeededOrDismiss];
        }];
    } else {
        [self.clipboardManager cancelPendingRestore];
        if (keepLastDictation) {
            [self.clipboardManager writeTransientText:text];
        } else {
            [self.clipboardManager writeText:text];
        }

        [self.statusBarManager updateState:@"idle"];
        if (!shouldAutoPaste) {
            // Copy-only is the user's choice: the clipboard icon says enough.
            NSLog(@"[VelikiyMoguchiy] Auto-paste disabled — processed text copied to clipboard only");
            [self.overlayPanel updateState:@"pasting"];
            [self.overlayPanel showResultBadge:@"✓ Скопировано"];
            [self showPromptTemplateButtonsIfNeededOrDismissWithLingerDuration:kManualPasteResultLingerDuration];
        } else {
            NSLog(@"[VelikiyMoguchiy] Accessibility not granted — text copied to clipboard only");
            [self.overlayPanel showMessage:@"Нет универсального доступа — текст в буфере, ⌘V"
                                      icon:SPOverlayMessageIconClipboard];
        }
    }

    [self applyDeferredConfigReloadIfNeeded];
}

- (void)rustBridgeDidEncounterError:(NSString *)message {
    if (self.quitting) return;
    self.sessionState = @"failed";
    [self disarmAbortKey];
    os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_ERROR, "[VelikiyMoguchiy] Session error: %{public}@", message ?: @"unknown error");
    NSLog(@"[VelikiyMoguchiy] Session error: %@", message);
    self.showingError = YES;
    self.llmCorrectionInProgress = NO;
    [self deactivateRawAsrFallbackInteraction];
    self.instantPastedText = nil;
    [self.instantPasteGuard reset];
    self.pendingDeliveryKind = SPTextDeliveryPasteAll;
    self.pendingDeliveryRemainder = nil;
    self.pendingSendRequest = NO;
    self.editAnchor = nil;
    [self.cuePlayer playError];
    self.sessionWantsAudioCapture = NO;
    [self.audioCaptureManager stopCapture];
    [self discardArmedLipClip];
    BOOL recordingKept = self.sessionAudioPath != nil;
    [self recordUnfinishedSessionWithStatus:@"error"
                                      error:[SPHistoryManager
                                                errorReasonWithSummary:[SPRetranscriber summaryForProviderMessage:message]
                                                       providerMessage:message]];
    [self resetAllHotkeyMonitorsToIdle];
    [self.statusBarManager updateState:@"error"];

    // The pill says what broke in a few words; the notification says what to do.
    // The provider's own text stays in the log and the history row.
    SPErrorExplanation *explanation = [SPErrorExplainer explanationForMessage:message recordingKept:recordingKept];
    NSLog(@"[VelikiyMoguchiy] Error %@ shown as \"%@\"", explanation.code, explanation.shortText);
    [self.overlayPanel showMessage:explanation.shortText icon:SPOverlayMessageIconError];
    [self sendErrorNotificationForExplanation:explanation];

    // Brief error display, then back to idle.
    // Guard with session token so a new session isn't reset to idle.
    uint64_t token = self.rustBridge.currentSessionToken;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (token != self.rustBridge.currentSessionToken) return;
        self.showingError = NO;
        [self.statusBarManager updateState:@"idle"];
        [self.overlayPanel updateState:@"idle"];
        [self applyDeferredConfigReloadIfNeeded];
    });
}

- (void)sendRetranscribedNotification:(NSString *)message {
    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = @"Великий & Могучий";
    content.body = message;
    content.sound = nil;

    NSString *identifier = [NSString stringWithFormat:@"velikiy-moguchiy-retranscribed-%f",
                            [[NSDate date] timeIntervalSince1970]];
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:identifier
                                                                          content:content
                                                                          trigger:nil];
    [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request
                                                           withCompletionHandler:^(NSError * _Nullable error) {
        if (error) {
            NSLog(@"[VelikiyMoguchiy] Failed to deliver retranscription notification: %@", error.localizedDescription);
        }
    }];
}

/// One banner per kind of message: a newer error replaces the older one. The
/// click leads to the explanation's action (userNotificationCenter:didReceive…).
- (void)postNotificationWithIdentifier:(NSString *)identifier
                                 title:(NSString *)title
                           explanation:(SPErrorExplanation *)explanation {
    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = title;
    content.body = [SPErrorExplainer notificationBodyForExplanation:explanation];
    content.sound = nil;
    content.userInfo = @{ @"action" : @(explanation.action) };
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:identifier
                                                                          content:content
                                                                          trigger:nil];
    [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request
                                                           withCompletionHandler:^(NSError * _Nullable error) {
        if (error) {
            NSLog(@"[VelikiyMoguchiy] Failed to deliver notification: %@", error.localizedDescription);
        }
    }];
}

- (void)sendErrorNotificationForExplanation:(SPErrorExplanation *)explanation {
    [self postNotificationWithIdentifier:@"velikiy-moguchiy-error"
                                   title:SPLocalizedString(@"notification.error.title")
                             explanation:explanation];
}

- (void)rustBridgeDidReceiveWarning:(NSString *)message {
    os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "[VelikiyMoguchiy] Session warning: %{public}@", message ?: @"unknown warning");
    NSLog(@"[VelikiyMoguchiy] Session warning: %@", message);
    SPErrorExplanation *explanation = [SPErrorExplainer explanationForWarning:message];
    if (!explanation) return;
    // Correction switched on without a key fails the same way on every dictation.
    if (!self.warningShownAt) self.warningShownAt = [NSMutableDictionary dictionary];
    NSDate *shownAt = self.warningShownAt[explanation.detail];
    if (shownAt && -shownAt.timeIntervalSinceNow < kWarningRepeatInterval) return;
    self.warningShownAt[explanation.detail] = [NSDate date];

    [self.permissionManager checkNotificationPermissionWithCompletion:^(BOOL granted) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.quitting) return;
            if (granted) {
                [self postNotificationWithIdentifier:@"velikiy-moguchiy-warning"
                                               title:SPLocalizedString(@"notification.warning.title")
                                         explanation:explanation];
            } else {
                // The warning comes before the text is delivered: the pill
                // says it once it has shown the result.
                self.pendingPillMessage = explanation;
            }
        });
    }];
}

/// The first line of `text`, short enough for the pill.
- (NSString *)firstLineOfText:(NSString *)text {
    NSString *line = [[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet].firstObject ?: @"";
    return line.length > 80 ? [[line substringToIndex:80] stringByAppendingString:@"…"] : line;
}

- (void)rustBridgeDidReceiveInterimText:(NSString *)text {
    if (!self.loggedFirstRecognitionForActivation && text.length > 0 &&
        self.rustBridge.currentSessionToken == self.recognitionMetricSessionToken) {
        self.loggedFirstRecognitionForActivation = YES;
        [self.audioCaptureManager logActivationMilestone:@"first recognition result"
                                   forActivationSequence:self.recognitionMetricActivationSequence];
    }
    [self.overlayPanel updateInterimText:text];
}

- (void)rustBridgeDidReceiveAsrFinalText:(NSString *)text {
    NSLog(@"[VelikiyMoguchiy] ASR final text: %lu chars", (unsigned long)text.length);
    if (!self.loggedFirstRecognitionForActivation && text.length > 0 &&
        self.rustBridge.currentSessionToken == self.recognitionMetricSessionToken) {
        self.loggedFirstRecognitionForActivation = YES;
        [self.audioCaptureManager logActivationMilestone:@"first recognition result"
                                   forActivationSequence:self.recognitionMetricActivationSequence];
    }
    self.lastAsrText = text;
    [self.overlayPanel updateDisplayText:text];
    [self activateRawAsrFallbackInteractionIfPossible];

    [self maybeInstantPasteAsrText:text];
}

#pragma mark - Experimental: paste ASR first, correct after LLM

/// Paste the raw ASR text as soon as recognition finishes, so the user sees
/// text land immediately instead of waiting out the LLM round-trip. The
/// correction is applied in place later — only when SPInstantPasteGuard can
/// prove the insertion is untouched — or delivered via clipboard otherwise.
- (void)maybeInstantPasteAsrText:(NSString *)text {
    if (self.quitting || text.length == 0) return;
    // The speech of an Ask / Edit is a question / an instruction, not text to insert.
    if (self.sessionPurpose == SPSessionPurposeAsk || self.sessionPurpose == SPSessionPurposeEdit) return;
    if (!configFlagEnabled("experimental.paste_asr_first")) return;
    // The session types its text itself (live insert / streaming insertion); a
    // raw paste on top would duplicate it. Decided when the session began.
    if (self.rustBridge.currentSessionTypesText) return;
    if (![self.permissionManager isAccessibilityGranted]) return;
    if ([self.accessibilityManager pasteTargetForFocusedElement] != SPPasteTargetPaste) return;

    NSLog(@"[VelikiyMoguchiy] InstantPaste: pasting raw ASR text (%lu chars)", (unsigned long)text.length);
    self.instantPastedText = text;
    self.instantPasteKeepClipboard = NO;
    [self.instantPasteGuard reset];

    if (keepLastDictationEnabled()) {
        [self.clipboardManager cancelPendingRestore];
        [self.clipboardManager writeTransientText:text];
    } else {
        // Paste vehicle for the raw text: hidden from clipboard histories.
        [self.clipboardManager backup];
        [self.clipboardManager writeTransientText:text];
    }

    uint64_t token = self.rustBridge.currentSessionToken;
    [self.pasteManager simulatePasteWithGuard:[self injectionGuardForSessionToken:token]
                                   completion:^(BOOL posted) {
        // A newer session owns this state now — checked before any mutation
        // so a stale callback cannot clear the new session's instant-paste
        // bookkeeping or cancel its clipboard restore.
        if (token != self.rustBridge.currentSessionToken) return;
        if (!posted) {
            // Nothing was pasted. Clear the instant-paste state so the
            // normal final-text flow (which would otherwise treat the raw
            // text as already delivered) performs the paste instead.
            self.instantPastedText = nil;
            [self.instantPasteGuard reset];
            [self.clipboardManager cancelPendingRestore];
            return;
        }
        // The correction may have replaced the clipboard content already
        // (fast LLM); in that case the backup must not be restored over it.
        if (!self.instantPasteKeepClipboard && !keepLastDictationEnabled()) {
            [self.clipboardRestorePolicy scheduleRestoreForCurrentSession];
        }
        // Only capture when the correction hasn't been handled yet.
        if ([text isEqualToString:self.instantPastedText]) {
            [self.instantPasteGuard captureAfterPasteWithRawText:text];
        }
    }];
}

/// Handle the corrected text for a session whose raw ASR text was already
/// pasted. Returns YES when the instant-paste flow consumed the final text.
- (BOOL)finishInstantPasteWithFinalText:(NSString *)text {
    if (!self.instantPastedText) return NO;
    NSString *raw = self.instantPastedText;
    self.instantPastedText = nil;

    [self.overlayPanel updateDisplayText:text];

    BOOL keepLastDictation = keepLastDictationEnabled();

    if ([text isEqualToString:raw]) {
        // Nothing to correct; the raw paste already delivered the result.
        [self recordInsertionOfText:text originalText:nil];
        [self.instantPasteGuard reset];
        [self.statusBarManager updateState:@"idle"];
        [self showPromptTemplateButtonsIfNeededOrDismiss];
    } else if ([self.instantPasteGuard replaceWithCorrectedText:text]) {
        [self recordInsertionOfText:text originalText:nil];
        if (keepLastDictation) {
            [self.clipboardManager cancelPendingRestore];
            [self.clipboardManager writeTransientText:text];
        }
        [self.statusBarManager updateState:@"idle"];
        [self showPromptTemplateButtonsIfNeededOrDismiss];
    } else {
        // Cannot prove in-place replacement is safe (focus moved, user
        // typed, or the app lacks accessibility text support). Leave the
        // raw text alone and deliver the correction via clipboard.
        self.instantPasteKeepClipboard = YES;
        [self recordInsertionOfText:raw originalText:nil];
        [self.clipboardManager cancelPendingRestore];
        if (keepLastDictation) {
            [self.clipboardManager writeTransientText:text];
        } else {
            [self.clipboardManager writeText:text];
        }
        [self.statusBarManager updateState:@"idle"];
        [self.overlayPanel updateState:@"pasting"];
        [self.overlayPanel showResultBadge:@"✓ Скопировано"];
        [self.overlayPanel lingerAndDismiss];
    }

    [self applyDeferredConfigReloadIfNeeded];
    return YES;
}

- (void)rustBridgeDidReceiveSessionMetaWithAsrText:(NSString *)asrText
                                          provider:(NSString *)provider
                                        llmApplied:(BOOL)llmApplied {
    self.pendingMetaAsrText = asrText;
    self.pendingMetaAsrProvider = provider;
    self.pendingMetaLlmApplied = llmApplied;
}

- (void)rustBridgeDidReceiveTextDeliveryKind:(NSInteger)kind remainder:(NSString *)remainder {
    self.pendingSendRequest = (kind & SPTextDeliverySendFlag) != 0;
    self.pendingDeliveryKind = kind & ~SPTextDeliverySendFlag;
    self.pendingDeliveryRemainder = remainder;
}

- (void)rustBridgeDidReceiveRewriteText:(NSString *)text {
    NSLog(@"[VelikiyMoguchiy] Rewrite text received (%lu chars)", (unsigned long)text.length);

    [self.clipboardManager cancelPendingRestore];

    // Copy to clipboard (no auto-paste — user decides where to paste)
    [self.clipboardManager writeText:text];

    // Show result with "Copied" indicator
    [self.statusBarManager updateState:@"idle"];
    [self.overlayPanel updateDisplayText:text];
    [self.overlayPanel updateState:@"pasting"];
    [self.overlayPanel showResultBadge:@"✓ Скопировано"];
    [self.overlayPanel lingerAndDismiss];
}

- (void)rustBridgeDidChangeState:(NSString *)state {
    if (self.quitting || self.showingError) return;
    if ([state isEqualToString:@"no_speech"]) {
        [self finishSessionWithoutSpeech];
        return;
    }
    self.sessionState = state;
    BOOL isCorrecting = [state isEqualToString:@"correcting"];
    if (isCorrecting) {
        self.llmCorrectionInProgress = YES;
    } else if ([state hasPrefix:@"recording"] ||
               [state isEqualToString:@"preparing_paste"] ||
               [state isEqualToString:@"pasting"] ||
               [state isEqualToString:@"cancelled"] ||
               [state isEqualToString:@"idle"] ||
               [state isEqualToString:@"failed"]) {
        self.llmCorrectionInProgress = NO;
        [self deactivateRawAsrFallbackInteraction];
    }
    if ([state isEqualToString:@"preparing_paste"] ||
        [state isEqualToString:@"pasting"] ||
        [state isEqualToString:@"cancelled"] ||
        [state isEqualToString:@"idle"] ||
        [state isEqualToString:@"failed"]) {
        [self disarmAbortKey];
    }
    [self.statusBarManager updateState:state];
    [self.overlayPanel updateState:state];
    if (isCorrecting) {
        [self activateRawAsrFallbackInteractionIfPossible];
    }
    [self applyDeferredConfigReloadIfNeeded];
}

#pragma mark - Raw ASR Fallback

- (void)activateRawAsrFallbackInteractionIfPossible {
    if (!self.llmCorrectionInProgress || self.lastAsrText.length == 0) return;

    self.rawAsrFallbackInteractionActive = YES;
    [self.overlayPanel setRawAsrFallbackClickEnabled:YES];

    // Assign the handler first: installing it arms the capture backend
    // (Carbon hotkeys for modifier-only triggers, the consuming tap
    // otherwise), so canConsumeHandlerKeyEvents is meaningful only after
    // this assignment.
    __weak typeof(self) weakSelf = self;
    self.hotkeyMonitor.enterKeyHandler = ^BOOL{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return NO;
        return [strongSelf requestRawAsrFallbackFromUserAction:@"enter"];
    };
    if (!self.hotkeyMonitor.canConsumeHandlerKeyEvents) {
        self.hotkeyMonitor.enterKeyHandler = nil;
    }
}

- (void)deactivateRawAsrFallbackInteraction {
    self.rawAsrFallbackInteractionActive = NO;
    self.hotkeyMonitor.enterKeyHandler = nil;
    [self.overlayPanel setRawAsrFallbackClickEnabled:NO];
}

- (BOOL)requestRawAsrFallbackFromUserAction:(NSString *)action {
    if (!self.rawAsrFallbackInteractionActive || self.lastAsrText.length == 0) {
        return NO;
    }

    BOOL accepted = [self.rustBridge acceptAsrResult];
    NSLog(@"[VelikiyMoguchiy] Raw ASR fallback requested via %@ (%@)",
          action ?: @"unknown",
          accepted ? @"sent" : @"not active");

    self.llmCorrectionInProgress = NO;
    [self deactivateRawAsrFallbackInteraction];
    // Consume the triggering event even if the Rust send failed: a failure
    // means the correction already finished and its final text is in flight,
    // so letting the Return through would type a stray newline right before
    // the paste lands.
    return YES;
}

#pragma mark - Abort Key

- (void)applyAbortKeyConfig:(struct SPHotkeyConfig)config {
    // Only a plain key can be captured while a session runs; modifier-only and
    // combo values are ignored, as is a key the trigger itself already owns.
    BOOL plainKey = config.trigger_key_code != 0 &&
                    config.trigger_match_kind == SPHotkeyMatchKindKeyDown &&
                    config.trigger_modifier_flag == 0;
    NSInteger keyCode = plainKey ? config.trigger_key_code : 0;
    if (keyCode == self.hotkeyMonitor.targetKeyCode ||
        keyCode == self.hotkeyMonitor.altKeyCode) {
        keyCode = 0;
    }
    self.hotkeyMonitor.abortKeyCode = keyCode;
    NSLog(@"[VelikiyMoguchiy] Abort key: %@", keyCode ? [NSString stringWithFormat:@"%ld", (long)keyCode] : @"off");
}

/// The handler exists only while a session is running, so the abort key
/// (Escape by default) is neither captured nor consumed the rest of the time.
- (void)armAbortKey {
    if (self.hotkeyMonitor.abortKeyCode == 0) return;
    __weak typeof(self) weakSelf = self;
    self.hotkeyMonitor.abortKeyHandler = ^BOOL{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return NO;
        return [strongSelf abortActiveSession];
    };
}

- (void)disarmAbortKey {
    self.hotkeyMonitor.abortKeyHandler = nil;
}

- (BOOL)abortActiveSession {
    if (self.quitting || sessionStateAllowsConfigReload(self.sessionState) ||
        [self.sessionState isEqualToString:@"cancelled"]) {
        return NO;
    }
    NSLog(@"[VelikiyMoguchiy] Abort key pressed — cancelling session (state=%@)", self.sessionState);
    [self disarmAbortKey];
    [self cancelPendingSessionEnd];
    self.preCaptureInterruptedPendingSessionEnd = NO;
    self.sessionWantsAudioCapture = NO;
    [self.audioCaptureManager cancelPreCapture];
    [self.audioCaptureManager stopCapture];
    [self discardArmedLipClip];
    [self recordUnfinishedSessionWithStatus:@"cancelled"];
    [self.rustBridge cancelSession];
    [self.rustBridge discardSessionCallbacks];
    self.llmCorrectionInProgress = NO;
    [self deactivateRawAsrFallbackInteraction];
    self.instantPastedText = nil;
    [self.instantPasteGuard reset];
    self.pendingMetaAsrText = nil;
    self.pendingMetaAsrProvider = nil;
    self.pendingMetaLlmApplied = NO;
    self.pendingDeliveryKind = SPTextDeliveryPasteAll;
    self.pendingDeliveryRemainder = nil;
    self.recordingStartTime = nil;
    self.sessionPurpose = SPSessionPurposeDictate;
    self.pendingSessionPurpose = SPSessionPurposeDictate;
    self.editAnchor = nil;
    self.showingError = NO;
    self.sessionState = @"idle";
    [self resetAllHotkeyMonitorsToIdle];
    [self.statusBarManager updateState:@"idle"];
    [self.overlayPanel updateState:@"cancelled"];
    [self.overlayPanel lingerAndDismissWithDuration:kAbortResultLingerDuration];
    [self applyDeferredConfigReloadIfNeeded];
    return YES;
}

#pragma mark - Session Recording

- (NSInteger)takeSessionDurationMs {
    if (!self.recordingStartTime) return 0;
    NSInteger durationMs = (NSInteger)(-[self.recordingStartTime timeIntervalSinceNow] * 1000);
    self.recordingStartTime = nil;
    return durationMs;
}

/// Closes the in-flight session's recording and returns its path when a
/// non-empty file was written.
- (NSString *)takeFinishedSessionAudioPath {
    NSString *path = self.sessionAudioPath;
    self.sessionAudioPath = nil;
    if (!path) return nil;
    SPRecordingManager *recordings = [SPRecordingManager sharedManager];
    [recordings endRecording];
    return [recordings existingPathForRecording:path];
}

/// A session that ended without a final text (cancelled, failed, superseded)
/// still keeps its recording; give it a history row so it stays listed.
- (void)recordUnfinishedSessionWithStatus:(NSString *)status {
    [self recordUnfinishedSessionWithStatus:status error:nil];
}

- (void)recordUnfinishedSessionWithStatus:(NSString *)status error:(NSString *)error {
    // No final text for this session: its camera clip is of no use either.
    [self discardSessionLipClip];
    if (!self.sessionAudioPath) return;
    NSInteger durationMs = [self takeSessionDurationMs];
    NSString *path = [self takeFinishedSessionAudioPath];
    NSString *appBundleId = self.sessionAppBundleId;
    self.sessionAppBundleId = nil;
    int64_t sessionId = [[SPHistoryManager sharedManager] recordSessionWithDurationMs:durationMs
                                                                                 text:@""
                                                                              asrText:nil
                                                                          asrProvider:nil
                                                                           llmApplied:NO
                                                                               status:status
                                                                            audioPath:path
                                                                                error:error
                                                                          appBundleId:appBundleId];
    if (sessionId > 0) {
        [self retryFailedSessionId:sessionId
                            status:status
                        durationMs:durationMs
                         audioPath:path
                       appBundleId:appBundleId];
    }
}

#pragma mark - Lip-reading camera clips

/// The trigger was cancelled or the session never started: drop the armed clip.
- (void)discardArmedLipClip {
    SPLipClip *clip = self.armedLipClip;
    self.armedLipClip = nil;
    [[SPLipCaptureManager sharedManager] discardClip:clip];
}

/// The session ended without a usable result (cancelled, failed, superseded).
- (void)discardSessionLipClip {
    SPLipClip *clip = self.sessionLipClip;
    self.sessionLipClip = nil;
    [[SPLipCaptureManager sharedManager] discardClip:clip];
}

/// The hold / tap was confirmed: the clip armed at the trigger-down now belongs
/// to the session (dictation only). Paths without a trigger-down (menu, media
/// key) arm one here.
- (void)adoptLipClipForNewSession {
    SPLipClip *clip = self.armedLipClip;
    self.armedLipClip = nil;
    if (self.sessionPurpose != SPSessionPurposeDictate) {
        [[SPLipCaptureManager sharedManager] discardClip:clip];
        return;
    }
    if (!clip) clip = [[SPLipCaptureManager sharedManager] beginPreCapture];
    self.sessionLipClip = clip;
}

- (void)resolveSessionLipClipWithStatus:(NSString *)status
                              finalText:(NSString *)text
                            appBundleId:(NSString *)appBundleId {
    SPLipClip *clip = self.sessionLipClip;
    self.sessionLipClip = nil;
    if (!clip) return;
    NSString *outputMode = SPNormalizedOutputMode(configStringValue("asr.qwen.output_mode"));
    [[SPLipCaptureManager sharedManager] resolveClip:clip
                                             dictate:self.sessionPurpose == SPSessionPurposeDictate
                                              status:status
                                           finalText:text
                                      recognizedText:self.pendingMetaAsrText
                                         appBundleId:appBundleId
                                          outputMode:outputMode
                                          completion:nil];
}

#pragma mark - Automatic retry

/// One automatic re-transcription of a dictation that failed. The recording is
/// already closed here (takeFinishedSessionAudioPath waits for the file).
- (void)retryFailedSessionId:(int64_t)sessionId
                      status:(NSString *)status
                  durationMs:(NSInteger)durationMs
                   audioPath:(NSString *)audioPath
                 appBundleId:(NSString *)appBundleId {
    BOOL audioExists = audioPath.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:audioPath];
    if (![SPRetranscriber shouldAutoRetryForStatus:status
                                        durationMs:durationMs
                                       audioExists:audioExists
                                           enabled:autoRetryOnErrorEnabled()]) {
        return;
    }
    NSLog(@"[VelikiyMoguchiy] Retrying failed dictation %lld once in the background", (long long)sessionId);
    NSDictionary *session = @{
        @"id" : @(sessionId),
        @"audio_path" : audioPath,
        @"app_bundle_id" : appBundleId ?: @"",
        @"text" : @"",
    };
    [[SPRetranscriber sharedRetranscriber] retranscribeSession:session
                                                    completion:^(SPRetranscriptionResult *result) {
        [self finishAutomaticRetry:result];
    }];
}

/// The history row is already updated. The text goes to the clipboard only:
/// the cursor may be elsewhere by now, so it is never pasted automatically.
- (void)finishAutomaticRetry:(SPRetranscriptionResult *)result {
    if (self.quitting || ![result.status isEqualToString:@"ok"]) return;
    NSLog(@"[VelikiyMoguchiy] Automatic retry recognized %lu chars", (unsigned long)result.text.length);
    if (!sessionStateAllowsConfigReload(self.sessionState)) {
        [self sendRetranscribedNotification:@"Распознано повторно — текст в «Последних диктовках»"];
        return;
    }
    [self.clipboardManager cancelPendingRestore];
    [self.clipboardManager writeText:result.text];
    [self.permissionManager checkNotificationPermissionWithCompletion:^(BOOL granted) {
        if (granted) {
            [self sendRetranscribedNotification:@"Распознано повторно — вставь ⌘V"];
        } else if (sessionStateAllowsConfigReload(self.sessionState)) {
            [self.overlayPanel showMessage:@"Распознано повторно — в буфере, ⌘V"
                                      icon:SPOverlayMessageIconClipboard];
        }
    }];
}

#pragma mark - Audio Error Recovery

- (void)handleAudioCaptureError:(NSString *)reason {
    NSLog(@"[VelikiyMoguchiy] Audio capture error: %@", reason);
    [self disarmAbortKey];
    [self.audioCaptureManager cancelPreCapture];
    [self.audioCaptureManager stopCapture];
    [self discardArmedLipClip];
    [self recordUnfinishedSessionWithStatus:@"error"
                                      error:[SPHistoryManager errorReasonWithSummary:reason providerMessage:nil]];
    self.sessionState = @"error";
    self.showingError = YES;
    [self.cuePlayer playError];
    self.sessionWantsAudioCapture = NO;
    [self.rustBridge cancelSession];
    [self resetAllHotkeyMonitorsToIdle];
    [self.statusBarManager updateState:@"error"];
    SPErrorExplanation *explanation =
        [reason isEqualToString:kSessionStartFailure]
            ? [SPErrorExplainer explanationWithKind:SPErrorKindUnknown
                                          shortText:@"Запись не началась"
                                             detail:@"Попробуйте ещё раз. Если повторяется, напишите нам: "
                                                    @"меню значка → «Сообщить о проблеме…»."
                                             action:SPErrorActionNone]
            : [SPErrorExplainer microphoneExplanationWithShortText:reason];
    [self.overlayPanel showMessage:explanation.shortText icon:SPOverlayMessageIconError];
    [self sendErrorNotificationForExplanation:explanation];

    uint64_t token = self.rustBridge.currentSessionToken;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (token != self.rustBridge.currentSessionToken) return;
        self.showingError = NO;
        [self.statusBarManager updateState:@"idle"];
        [self.overlayPanel updateState:@"idle"];
        [self applyDeferredConfigReloadIfNeeded];
    });
}

#pragma mark - SPAudioDeviceManagerDelegate

- (void)audioDeviceManagerDeviceListDidChange {
    if (!self.audioPreparationEnabled) return;

    // If the selected device disappeared mid-recording, stop gracefully
    if (![self.audioDeviceManager isSelectedDeviceAvailable]) {
        NSLog(@"[VelikiyMoguchiy] Selected audio device disappeared during recording");
        BOOL wasCapturing = self.audioCaptureManager.isCapturing;
        [self.audioCaptureManager shutdown];

        if (wasCapturing) {
            [self handleAudioCaptureError:@"Аудиоустройство отключено"];
        } else {
            [self prepareAudioQueueForResolvedDevice];
        }
    } else if (!self.audioCaptureManager.isAudioQueueRunning) {
        // Device-list and default-route changes can invalidate even an
        // inactive AudioQueue. Rebuild so Bluetooth reconnects never retain a
        // stale device and system-default selection resolves on next start.
        [self.audioCaptureManager shutdown];
        [self prepareAudioQueueForResolvedDevice];
    }
}

#pragma mark - SPStatusBarDelegate (menu)

- (void)statusBarMenuDidOpen {
    self.hotkeyMonitor.suspended = YES;
    self.translateHotkeyMonitor.suspended = YES;
    self.askHotkeyMonitor.suspended = YES;
    self.editHotkeyMonitor.suspended = YES;
}

- (void)statusBarMenuDidClose {
    // Defer unsuspend to the next run-loop iteration so that any menu-item
    // action (e.g. Quit → stop()) executes first.  Without this, Cocoa's
    // menuDidClose: fires before the item action, resetting suspended=NO
    // and allowing FlagsChanged events through the NSEvent monitor path
    // before stop() has a chance to set running=NO.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.quitting) return;
        self.hotkeyMonitor.suspended = NO;
        self.translateHotkeyMonitor.suspended = NO;
        self.askHotkeyMonitor.suspended = NO;
        self.editHotkeyMonitor.suspended = NO;
    });
}

- (void)statusBarDidSelectQuit {
    self.quitting = YES;
    self.sessionWantsAudioCapture = NO;
    self.hotkeyMonitor.suspended = YES;
    self.translateHotkeyMonitor.suspended = YES;
    self.askHotkeyMonitor.suspended = YES;
    self.editHotkeyMonitor.suspended = YES;

    // Stop the hotkey monitor FIRST, before any slow teardown (audio, Rust):
    // while a CONSUMING tap is alive (non-modifier triggers), a blocked
    // process would stall the session's keyboard stream for every app.
    // (The historical phantom-keys-at-quit bug, issues #57/#65, turned out
    // to be SPPermissionManager's leaked probe taps, not this teardown.)
    [self.hotkeyMonitor stop];
    [self.translateHotkeyMonitor stop];
    [self.askHotkeyMonitor stop];
    [self.editHotkeyMonitor stop];
    [self.undoHotkeyMonitor stop];
    [self.repasteHotkeyMonitor stop];
    [self.lipsHotkeyMonitor stop];

    // Cancel any pending session-end block so it cannot trigger a paste
    // during the run-loop draining inside [NSApp terminate:].
    [self cancelPendingSessionEnd];
    // Cancel any scheduled CGEventPost paste/undo blocks so they cannot leak
    // synthetic key events into whichever app gains focus after this app quits.
    [self.pasteManager cancel];
    [self.audioCaptureManager shutdown];
    [self.rustBridge cancelSession];
    [NSApp terminate:nil];
}

- (void)statusBarDidSelectToggleVoiceInput {
    // Reuse the hotkey toggle path verbatim so a menu-driven session is
    // indistinguishable from a tap-started one, and keep the hotkey state
    // machine in sync so the trigger key stops (not restarts) this session.
    if ([self.sessionState hasPrefix:@"recording"]) {
        NSLog(@"[VelikiyMoguchiy] Voice input stopped from menu");
        [self endHandsFreeRecordingLikeSecondTap];
        return;
    }
    NSLog(@"[VelikiyMoguchiy] Voice input started from menu");
    [self hotkeyMonitorDidBeginTrigger];
    // Arm before starting: if the session fails to begin, the resetToIdle
    // inside handleAudioCaptureError must be the last write to the state
    // machine, otherwise it is left in a recording state with no session.
    [self.hotkeyMonitor markExternalToggleRecording];
    [self hotkeyMonitorDidDetectTapStart];
}

#pragma mark - Voice edit, undo and re-paste (hotkey.edit_key / undo_key / repaste_key)

/// Remember `text` as the last thing put into the focused field (undo).
- (void)recordInsertionOfText:(NSString *)text originalText:(NSString *)originalText {
    if (text.length == 0) return;
    self.lastInsertion = [SPInsertionRecord recordInsertedText:text originalText:originalText];
}

/// A short result pill: "↩︎ Отменено", "✓ Заменено".
- (void)showQuickBadge:(NSString *)badge {
    [self.statusBarManager updateState:@"idle"];
    [self.overlayPanel updateState:@"pasting"];
    [self.overlayPanel showResultBadge:badge];
    [self.overlayPanel lingerAndDismissWithDuration:kQuickBadgeLingerDuration];
}

/// A notification ("Нечего отменить"); the overlay pill when notifications are off.
- (void)showInfoMessage:(NSString *)message {
    NSLog(@"[VelikiyMoguchiy] %@", message);
    [self.permissionManager checkNotificationPermissionWithCompletion:^(BOOL granted) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.quitting) return;
            if (granted) {
                UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
                content.title = @"Великий & Могучий";
                content.body = message;
                content.sound = nil;
                // One fixed identifier: the newest message replaces the previous banner.
                UNNotificationRequest *request =
                    [UNNotificationRequest requestWithIdentifier:@"velikiy-moguchiy-info" content:content trigger:nil];
                [[UNUserNotificationCenter currentNotificationCenter]
                    addNotificationRequest:request
                     withCompletionHandler:^(NSError *_Nullable error) {
                    if (error) NSLog(@"[VelikiyMoguchiy] Failed to deliver notification: %@", error.localizedDescription);
                }];
            } else if (sessionStateAllowsConfigReload(self.sessionState)) {
                [self.statusBarManager updateState:@"idle"];
                [self.overlayPanel showMessage:message icon:SPOverlayMessageIconNotice];
            }
        });
    }];
}

/// The result of a voice edit goes over the selection captured at the trigger:
/// in place through Accessibility when the field and selection are untouched,
/// else Cmd+V over the still-active unchanged selection, else the clipboard.
- (void)applyEditResult:(NSString *)text toSelection:(SPSelectionAnchor *)anchor {
    uint64_t token = self.rustBridge.currentSessionToken;
    [self.overlayPanel updateDisplayText:text];
    [self.overlayPanel updateState:@"pasting"];

    if (text.length == 0) {
        [self.statusBarManager updateState:@"idle"];
        [self.overlayPanel showMessage:@"Правка пустая — текст не тронут" icon:SPOverlayMessageIconNotice];
        return;
    }

    BOOL canApply = anchor && [self.permissionManager isAccessibilityGranted] && [self shouldAutoPasteProcessedText];
    SPEditApplyPlan plan = SPEditApplyPlanClipboardOnly;
    if (canApply) {
        plan = [SPTextEditPolicy planWithSelectionUnchanged:[anchor selectionStillUnchanged]
                                               textSettable:anchor.textSettable];
    }

    if (plan == SPEditApplyPlanInPlace) {
        if ([anchor replaceSelectionWithText:text]) {
            self.lastInsertion = [SPInsertionRecord recordInsertedText:text
                                                          originalText:anchor.selectedText
                                                                anchor:anchor];
            if (keepLastDictationEnabled()) {
                [self.clipboardManager cancelPendingRestore];
                [self.clipboardManager writeTransientText:text];
            }
            [self.overlayPanel showResultBadge:@"✓ Заменено"];
            [self.statusBarManager updateState:@"idle"];
            [self showPromptTemplateButtonsIfNeededOrDismiss];
            return;
        }
        plan = [SPTextEditPolicy planAfterFailedInPlaceWithSelectionUnchanged:[anchor selectionStillUnchanged]];
    }

    if (plan == SPEditApplyPlanPasteOverSelection) {
        BOOL keepLast = keepLastDictationEnabled();
        if (keepLast) {
            [self.clipboardManager cancelPendingRestore];
        } else {
            [self.clipboardManager backup];
        }
        [self.clipboardManager writeTransientText:text];
        [self.clipboardRestorePolicy
            captureSessionRestoreDelayMs:sp_core_get_clipboard_config().restore_delay_ms];
        __weak typeof(self) weakSelf = self;
        SPPasteInjectionGuard guard = ^BOOL{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || strongSelf.quitting) return NO;
            if (token != strongSelf.rustBridge.currentSessionToken) return NO;
            // Pasting over anything but the captured selection would destroy text.
            return [anchor selectionStillUnchanged];
        };
        [self.pasteManager simulatePasteWithGuard:guard completion:^(BOOL posted) {
            if (token != self.rustBridge.currentSessionToken) return;
            if (posted) {
                self.lastInsertion = [SPInsertionRecord recordInsertedText:text
                                                              originalText:anchor.selectedText
                                                                    anchor:anchor];
                if (!keepLast) [self.clipboardRestorePolicy scheduleRestoreForCurrentSession];
                [self.overlayPanel showResultBadge:@"✓ Заменено"];
                [self.statusBarManager updateState:@"idle"];
                [self showPromptTemplateButtonsIfNeededOrDismiss];
            } else {
                [self.clipboardManager cancelPendingRestore];
                [self.clipboardManager writeText:text];
                [self.statusBarManager updateState:@"idle"];
                [self.overlayPanel showMessage:@"Не заменилось — правка в буфере, ⌘V"
                                          icon:SPOverlayMessageIconClipboard];
            }
        }];
        return;
    }

    [self.clipboardManager cancelPendingRestore];
    [self.clipboardManager writeText:text];
    [self.statusBarManager updateState:@"idle"];
    [self.overlayPanel showMessage:@"Выделение изменилось — правка в буфере, ⌘V"
                              icon:SPOverlayMessageIconClipboard];
}

/// The paste replaced a clipboard that the backup could not keep: once the
/// pill has shown the result, it says the old content will not come back.
- (void)noteClipboardThatCannotComeBack {
    if (!self.clipboardManager.lastBackupLostContent) return;
    self.pendingPillMessage =
        [SPErrorExplainer explanationWithKind:SPErrorKindUnknown
                                    shortText:@"Скопированное раньше не вернётся в буфер: его не удалось сохранить"
                                       detail:@""
                                       action:SPErrorActionNone];
}

/// Takes back the text the app inserted last, when it is still there: within two
/// minutes, same field, the text right before the caret is exactly that text.
/// An edit gets its original selection back.
- (void)undoLastInsertion {
    if (self.quitting) return;
    if (!sessionStateAllowsConfigReload(self.sessionState)) {
        NSLog(@"[VelikiyMoguchiy] Undo ignored: a session is running (state=%@)", self.sessionState);
        return;
    }
    SPInsertionRecord *record = self.lastInsertion;
    SPUndoVerdict verdict = SPUndoVerdictNothingRecorded;
    BOOL rangeSelected = NO;
    SPUndoOutcome outcome = [SPSelectionEditor undoInsertion:record
                                                         now:[NSDate date]
                                                     verdict:&verdict
                                               rangeSelected:&rangeSelected];
    if (outcome == SPUndoOutcomeDone) {
        NSLog(@"[VelikiyMoguchiy] Undo: removed %lu chars%@", (unsigned long)record.text.length,
              record.originalText ? @" and restored the original selection" : @"");
        self.lastInsertion = nil;
        [self showQuickBadge:@"↩︎ Отменено"];
    } else if (outcome == SPUndoOutcomeNeedsKeys) {
        [self undoByKeysForRecord:record rangeSelected:rangeSelected];
    } else {
        NSLog(@"[VelikiyMoguchiy] Undo refused (verdict %ld)", (long)verdict);
        [self showInfoMessage:@"Нечего отменить"];
    }
}

/// The field accepted neither a range nor a text write over the insertion:
/// delete it with Backspace (one press when it is selected) and, for an edit,
/// paste the original back.
- (void)undoByKeysForRecord:(SPInsertionRecord *)record rangeSelected:(BOOL)rangeSelected {
    __weak typeof(self) weakSelf = self;
    SPPasteInjectionGuard guard = ^BOOL{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.quitting) return NO;
        if (!sessionStateAllowsConfigReload(strongSelf.sessionState)) return NO;
        return [SPSelectionEditor focusMatchesRecord:record];
    };
    NSUInteger presses = rangeSelected ? 1 : [SPTextEditPolicy backspaceCountForText:record.text];
    if (![self.pasteManager simulateBackspaces:presses withGuard:guard]) {
        [self showInfoMessage:@"Нечего отменить"];
        return;
    }
    self.lastInsertion = nil;
    NSString *replacement = [SPTextEditPolicy undoReplacementForOriginalText:record.originalText];
    if (replacement.length == 0) {
        [self showQuickBadge:@"↩︎ Отменено"];
        return;
    }
    BOOL keepLast = keepLastDictationEnabled();
    if (keepLast) {
        [self.clipboardManager cancelPendingRestore];
    } else {
        [self.clipboardManager backup];
    }
    [self.clipboardManager writeTransientText:replacement];
    [self.clipboardRestorePolicy captureSessionRestoreDelayMs:sp_core_get_clipboard_config().restore_delay_ms];
    uint64_t token = self.rustBridge.currentSessionToken;
    [self.pasteManager simulatePasteWithGuard:guard completion:^(BOOL posted) {
        if (token != self.rustBridge.currentSessionToken) return;
        if (posted) {
            if (!keepLast) [self.clipboardRestorePolicy scheduleRestoreForCurrentSession];
            [self showQuickBadge:@"↩︎ Отменено"];
        } else {
            [self.clipboardManager cancelPendingRestore];
            [self.clipboardManager writeText:replacement];
            [self showQuickBadge:@"Исходный текст в буфере, ⌘V"];
        }
    }];
}

/// Pastes the last dictation of this run (or the newest successful history row)
/// at the cursor, through the normal paste path with its clipboard
/// backup / restore rules.
- (void)repasteLastDictation {
    if (self.quitting) return;
    if (!sessionStateAllowsConfigReload(self.sessionState)) {
        NSLog(@"[VelikiyMoguchiy] Re-paste ignored: a session is running (state=%@)", self.sessionState);
        return;
    }
    NSString *text = [SPTextEditPolicy
        repasteTextWithLastDictation:self.lastDictationText
                         historyRows:[[SPHistoryManager sharedManager] recentSessionsWithLimit:20]];
    if (text.length == 0) {
        [self showInfoMessage:@"Нечего вставлять"];
        return;
    }
    [self pasteTextAtCursor:text];
}

/// Pastes `text` at the cursor outside a dictation session, through the
/// normal paste path with its clipboard backup / restore rules.
- (void)pasteTextAtCursor:(NSString *)text {
    if ([self.permissionManager isAccessibilityGranted] &&
        [self.accessibilityManager pasteTargetForFocusedElement] == SPPasteTargetSecure) {
        [self showInfoMessage:@"Поле пароля — текст не вставлен"];
        return;
    }
    BOOL keepLast = keepLastDictationEnabled();
    [self.clipboardManager cancelPendingRestore];
    if (![self.permissionManager isAccessibilityGranted] || ![self shouldAutoPasteProcessedText]) {
        if (keepLast) {
            [self.clipboardManager writeTransientText:text];
        } else {
            [self.clipboardManager writeText:text];
        }
        [self showQuickBadge:@"✓ Скопировано"];
        return;
    }
    if (!keepLast) [self.clipboardManager backup];
    [self.clipboardManager writeTransientText:text];
    [self.clipboardRestorePolicy captureSessionRestoreDelayMs:sp_core_get_clipboard_config().restore_delay_ms];

    uint64_t token = self.rustBridge.currentSessionToken;
    pid_t targetPid = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    __weak typeof(self) weakSelf = self;
    SPPasteInjectionGuard guard = ^BOOL{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.quitting) return NO;
        // A dictation started meanwhile, or the user switched apps: not the target any more.
        if (token != strongSelf.rustBridge.currentSessionToken) return NO;
        return NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier == targetPid;
    };
    [self.pasteManager simulatePasteWithGuard:guard completion:^(BOOL posted) {
        if (token != self.rustBridge.currentSessionToken) return;
        if (posted) {
            [self recordInsertionOfText:text originalText:nil];
            if (!keepLast) [self.clipboardRestorePolicy scheduleRestoreForCurrentSession];
            [self showQuickBadge:@"✓ Вставлено"];
        } else {
            [self.clipboardManager cancelPendingRestore];
            [self.clipboardManager writeText:text];
            [self showQuickBadge:@"Не вставилось — в буфере, ⌘V"];
        }
    }];
}

#pragma mark - Lips (experimental.lips, hotkey.lips_key)

- (void)rebuildLipsMonitor {
    [self.lipsHotkeyMonitor stop];
    self.lipsHotkeyMonitor = nil;
    if (!configFlagEnabled("experimental.lips")) {
        [[SPLipsService sharedService] shutdown];
        return;
    }
    struct SPHotkeyConfig config = sp_core_get_extra_hotkey_config(8);
    if (config.trigger_key_code == 0) {
        NSLog(@"[VelikiyMoguchiy] experimental.lips is on but hotkey.lips_key is unset, invalid or taken by another hotkey");
        return;
    }
    if (!self.lipsHotkeyProxy) {
        self.lipsHotkeyProxy = [[SPLipsHotkeyProxy alloc] init];
        self.lipsHotkeyProxy.target = self;
    }
    SPHotkeyMonitor *monitor = [[SPHotkeyMonitor alloc] initWithDelegate:self.lipsHotkeyProxy];
    monitor.targetKeyCode = config.trigger_key_code;
    monitor.altKeyCode = config.trigger_alt_key_code;
    monitor.targetModifierFlag = config.trigger_modifier_flag;
    monitor.targetMatchKind = config.trigger_match_kind;
    // The camera records exactly while the key is held, whatever trigger_mode says.
    monitor.triggerMode = SPHotkeyTriggerModeHold;
    [monitor start];
    self.lipsHotkeyMonitor = monitor;
}

/// Key down: the camera starts at once so the first syllable is not lost while
/// the press is still being classified, and the service starts loading the model.
- (void)lipsKeyDown {
    if (self.quitting || self.lipsClip || self.lipsBusy) return;
    SPLipsRuntime *runtime = [SPLipsRuntime sharedRuntime];
    if (![runtime isReady]) {
        if (runtime.setupDeclined && !runtime.isInstalling) {
            [self showInfoMessage:@"Режим «губы» не установлен. Установить: Настройки → «Данные для чтения по губам»"];
            return;
        }
        // Not from inside the hotkey callback: the offer is a modal alert. The
        // key-up that follows finds no clip and does nothing.
        dispatch_async(dispatch_get_main_queue(), ^{
            [runtime offerSetupWithCompletion:nil];
        });
        return;
    }
    if (!sessionStateAllowsConfigReload(self.sessionState)) {
        NSLog(@"[VelikiyMoguchiy] lips: ignored, a dictation is running (state=%@)", self.sessionState);
        return;
    }
    AVAuthorizationStatus status = [SPLipCaptureManager authorizationStatus];
    if (status == AVAuthorizationStatusNotDetermined) {
        [SPLipCaptureManager requestAccessIfNeeded:nil];
        return;
    }
    if (status != AVAuthorizationStatusAuthorized) {
        [self showInfoMessage:@"Для губ нужен доступ к камере: Системные настройки → Конфиденциальность → Камера"];
        return;
    }
    self.lipsClip = [[SPLipCaptureManager sharedManager] beginLipsClip];
    if (!self.lipsClip) {
        [self showInfoMessage:@"Камера недоступна"];
        return;
    }
    [[SPLipsService sharedService] warmUp];
}

- (void)lipsHoldStarted {
    if (!self.lipsClip) return;
    [self.statusBarManager updateState:@"recording"];
    [self.overlayPanel updateState:@"recording"];
}

/// A short tap, or the key combined with another key: not a lips dictation.
- (void)lipsKeyCancelled {
    SPLipClip *clip = self.lipsClip;
    self.lipsClip = nil;
    if (!clip) return;
    [[SPLipCaptureManager sharedManager] discardClip:clip];
    [self.statusBarManager updateState:@"idle"];
    [self.overlayPanel dismissToIdle];
}

- (void)lipsKeyUp {
    SPLipClip *clip = self.lipsClip;
    self.lipsClip = nil;
    if (!clip) return;
    self.lipsBusy = YES;
    [self.statusBarManager updateState:@"correcting"];
    [self.overlayPanel updateState:@"processing"];
    SPLipCaptureManager *camera = [SPLipCaptureManager sharedManager];
    [camera endClip:clip];
    NSString *context = NSWorkspace.sharedWorkspace.frontmostApplication.localizedName;
    uint64_t token = self.rustBridge.currentSessionToken;
    CFAbsoluteTime keyUp = CFAbsoluteTimeGetCurrent();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL finalized = [clip waitUntilFinalizedWithTimeout:5.0];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!finalized || !clip.usable) {
                [camera discardClip:clip];
                self.lipsBusy = NO;
                [self finishLipsWithError:@"Видео с камеры не записалось"];
                return;
            }
            NSLog(@"[VelikiyMoguchiy] lips: clip %.2fs, reading it", clip.durationSec);
            [[SPLipsService sharedService]
                transcribeClipAtPath:clip.temporaryPath
                             context:context
                          completion:^(NSDictionary *reply, NSString *errorMessage) {
                [camera discardClip:clip];
                self.lipsBusy = NO;
                if (self.quitting) return;
                NSLog(@"[VelikiyMoguchiy] lips: %.2fs from key-up to text, service timings %@, model said \"%@\"",
                      CFAbsoluteTimeGetCurrent() - keyUp, reply[@"timings"], reply[@"raw"]);
                NSString *text = [SPLipsPolicy insertableTextFromServiceReply:reply];
                if (!text) {
                    [self finishLipsWithError:errorMessage ?: @"Губы: ничего не распознано"];
                    return;
                }
                if (token != self.rustBridge.currentSessionToken ||
                    !sessionStateAllowsConfigReload(self.sessionState)) {
                    [self.clipboardManager cancelPendingRestore];
                    [self.clipboardManager writeText:text];
                    NSLog(@"[VelikiyMoguchiy] lips: a dictation started meanwhile; the text went to the clipboard");
                    return;
                }
                self.lastDictationText = text;
                [self pasteTextAtCursor:text];
            }];
        });
    });
}

- (void)finishLipsWithError:(NSString *)message {
    [self.statusBarManager updateState:@"idle"];
    [self.overlayPanel updateState:@"error"];
    [self showInfoMessage:message];
}

- (void)statusBarDidSelectUndoLastInsertion {
    [self undoLastInsertion];
}

- (void)statusBarDidSelectRepasteLastDictation {
    [self repasteLastDictation];
}

#pragma mark - Output mode (hotkey.mode_key, menu)

/// Raw → light → structured → formal → raw, for the global asr.qwen.output_mode.
- (void)cycleOutputMode {
    NSString *next = SPNextOutputMode(configStringValue("asr.qwen.output_mode"));
    [self applyOutputMode:next];
}

- (void)applyOutputMode:(NSString *)mode {
    NSString *normalized = SPNormalizedOutputMode(mode);
    if (sp_config_set("asr.qwen.output_mode", normalized.UTF8String) != 0) {
        NSLog(@"[VelikiyMoguchiy] Failed to save asr.qwen.output_mode=%@", normalized);
        return;
    }
    // The core re-reads the config at every session start, so our own write
    // needs no reload; mark it seen so the watcher does not rebuild the hotkeys.
    struct stat st;
    NSString *configPath = SPAppDataPath(@"config.yaml");
    if (stat(configPath.UTF8String, &st) == 0) {
        self.lastConfigModTime = st.st_mtime;
    }
    NSLog(@"[VelikiyMoguchiy] Output mode set to %@", normalized);

    if (sessionStateAllowsConfigReload(self.sessionState)) {
        [self.overlayPanel showModeIndicator:SPOutputModeLetter(normalized)];
    }
    [self sendOutputModeNotification:normalized];
}

/// "Режим: Лёгкая правка", plus a line when the frontmost app has its own mode
/// that wins over the global one.
- (void)sendOutputModeNotification:(NSString *)mode {
    NSMutableString *body =
        [NSMutableString stringWithFormat:@"Режим: %@", SPOutputModeTitle(mode)];
    NSRunningApplication *frontmost = NSWorkspace.sharedWorkspace.frontmostApplication;
    NSString *bundleId = frontmost.bundleIdentifier;
    if (bundleId.length > 0) {
        char *override = sp_core_output_mode_override(bundleId.UTF8String);
        if (override) {
            NSString *appMode = [NSString stringWithUTF8String:override] ?: @"";
            sp_core_free_string(override);
            if (![SPNormalizedOutputMode(appMode) isEqualToString:SPNormalizedOutputMode(mode)]) {
                [body appendFormat:@"\nВ «%@» действует свой режим: %@",
                                   frontmost.localizedName ?: bundleId, SPOutputModeTitle(appMode)];
            } else {
                [body appendFormat:@"\nВ «%@» режим задан приложением",
                                   frontmost.localizedName ?: bundleId];
            }
        }
    }

    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = @"Великий & Могучий";
    content.body = body;
    content.sound = nil;
    // One fixed identifier: the newest mode replaces the previous banner.
    UNNotificationRequest *request =
        [UNNotificationRequest requestWithIdentifier:@"velikiy-moguchiy-output-mode" content:content trigger:nil];
    [[UNUserNotificationCenter currentNotificationCenter]
        addNotificationRequest:request
         withCompletionHandler:^(NSError *_Nullable error) {
        if (error) {
            NSLog(@"[VelikiyMoguchiy] Failed to deliver output mode notification: %@", error.localizedDescription);
        }
    }];
}

- (void)statusBarDidSelectOutputMode:(NSString *)mode {
    [self applyOutputMode:mode];
}

- (void)statusBarDidSelectAudioDeviceWithUID:(NSString *)uid {
    NSLog(@"[VelikiyMoguchiy] Audio input device changed: %@", uid ?: @"System Default");
    if (self.audioCaptureManager.isCapturing) return;

    [self.audioCaptureManager shutdown];
    [self prepareAudioQueueForResolvedDevice];
}

- (void)statusBarDidSelectSetupWizard {
    [self showSettingsPane:nil];
}

- (void)statusBarDidSelectOnboarding {
    if (!self.onboarding) {
        self.onboarding = [[SPOnboardingWindowController alloc] initWithPermissionManager:self.permissionManager
                                                                            localAsrOffer:self.localAsrOffer];
        __weak typeof(self) weakSelf = self;
        self.onboarding.openSettingsPane = ^(NSString *pane) {
            [weakSelf showSettingsPane:pane];
        };
    }
    [self.onboarding present];
}

/// The Settings window, on `pane` when given (asr, llm, hotkey, …).
- (void)showSettingsPane:(NSString *)pane {
    if (!self.setupWizard) {
        self.setupWizard = [[SPSetupWizardWindowController alloc] init];
        self.setupWizard.delegate = self;
        self.setupWizard.rustBridge = self.rustBridge;
    }
    if (pane.length > 0) {
        [self.setupWizard showPane:pane];
    } else {
        [self.setupWizard showWindow:nil];
    }
}

- (void)statusBarDidSelectRecentDictations {
    if (!self.recentDictations) {
        self.recentDictations = [[SPRecentDictationsWindowController alloc] init];
        self.recentDictations.clipboardManager = self.clipboardManager;
    }
    [self.recentDictations present];
}

#pragma mark - SPSetupWizardDelegate

- (void)setupWizardDidSaveConfig {
    NSLog(@"[VelikiyMoguchiy] Setup wizard saved config, scheduling reload...");

    if (![self shouldShowPromptTemplateButtons]) {
        [self stopNumberKeyMonitoring];
        [self stopAnyKeyDismissMonitoring];
        [self.overlayPanel hideTemplateButtons];
    }

    [self reloadConfigAndApplyHotkeyIfSafe];
    if (!self.hasPendingConfigReload) {
        NSLog(@"[VelikiyMoguchiy] Config reloaded after setup wizard save");
    }
}

#pragma mark - SPOverlayPanelDelegate

- (void)overlayPanelDidDismiss:(id)panel {
    [self deactivateRawAsrFallbackInteraction];
    [self stopNumberKeyMonitoring];
    [self stopAnyKeyDismissMonitoring];
    SPErrorExplanation *pending = self.pendingPillMessage;
    self.pendingPillMessage = nil;
    if (pending && sessionStateAllowsConfigReload(self.sessionState)) {
        [self.overlayPanel showMessage:pending.shortText icon:SPOverlayMessageIconNotice];
    }
}

#pragma mark - UNUserNotificationCenterDelegate

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    // Shown while the Settings window is in front too: that is when a key gets fixed.
    completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionList);
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
    didReceiveNotificationResponse:(UNNotificationResponse *)response
             withCompletionHandler:(void (^)(void))completionHandler {
    NSNumber *action = response.notification.request.content.userInfo[@"action"];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self performErrorAction:(SPErrorAction)action.integerValue];
    });
    completionHandler();
}

- (void)performErrorAction:(SPErrorAction)action {
    switch (action) {
        case SPErrorActionAsrSettings:
            [self showSettingsPane:@"asr"];
            break;
        case SPErrorActionLlmSettings:
            [self showSettingsPane:@"llm"];
            break;
        case SPErrorActionMicrophonePrivacy:
            [[NSWorkspace sharedWorkspace]
                openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"]];
            break;
        case SPErrorActionRecentDictations:
            [self statusBarDidSelectRecentDictations];
            break;
        case SPErrorActionNone:
            break;
    }
}

- (void)overlayPanelDidRequestRawAsrFallback:(id)panel {
    [self requestRawAsrFallbackFromUserAction:@"overlay-click"];
}

- (void)overlayPanel:(id)panel didSelectTemplateAtIndex:(NSInteger)templateIndex {
    NSLog(@"[VelikiyMoguchiy] Template selected: index %ld", (long)templateIndex);
    [self stopNumberKeyMonitoring];
    [self stopAnyKeyDismissMonitoring];
    [self.clipboardManager cancelPendingRestore];

    // Show rewriting state
    [self.overlayPanel updateState:@"correcting"];

    // Trigger rewrite
    if (![self.rustBridge rewriteWithTemplateIndex:templateIndex asrText:self.lastAsrText]) {
        NSLog(@"[VelikiyMoguchiy] Rewrite failed to start");
        [self.overlayPanel lingerAndDismiss];
    }
}

#pragma mark - Number Key Monitoring

- (void)startNumberKeyMonitoringWithVisibleCount:(NSInteger)visibleCount {
    __weak typeof(self) weakSelf = self;
    // Limit the capture to digits that actually map to a visible template so
    // unassigned digits are never swallowed globally. Set BEFORE the handler:
    // assigning the handler arms the capture backend (Carbon hotkeys for
    // modifier-only triggers, the consuming tap otherwise), so
    // canConsumeHandlerKeyEvents is meaningful only after that assignment.
    self.hotkeyMonitor.numberKeyCaptureLimit = visibleCount;
    self.hotkeyMonitor.numberKeyHandler = ^BOOL(NSInteger number) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return NO;

        BOOL handled = [strongSelf.overlayPanel handleNumberKey:number];
        if (handled) {
            NSLog(@"[VelikiyMoguchiy] Template shortcut triggered: %ld", (long)number);
        }
        return handled;
    };

    if (!self.hotkeyMonitor.canConsumeHandlerKeyEvents) {
        self.hotkeyMonitor.numberKeyHandler = nil;
        NSLog(@"[VelikiyMoguchiy] Template selector visible (click-only; global number shortcuts unavailable)");
        return;
    }
    NSLog(@"[VelikiyMoguchiy] Template selector visible (global number shortcuts active)");
}

- (void)stopNumberKeyMonitoring {
    self.hotkeyMonitor.numberKeyHandler = nil;
    NSLog(@"[VelikiyMoguchiy] Template selector hidden");
}

#pragma mark - Any-Key Dismiss Monitoring

- (void)startAnyKeyDismissMonitoring {
    __weak typeof(self) weakSelf = self;
    self.hotkeyMonitor.anyKeyDismissHandler = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        NSLog(@"[VelikiyMoguchiy] Key press detected — dismissing overlay immediately");
        [strongSelf stopNumberKeyMonitoring];
        [strongSelf stopAnyKeyDismissMonitoring];
        [strongSelf.overlayPanel dismissToIdle];
    };
    NSLog(@"[VelikiyMoguchiy] Any-key dismiss monitoring active");
}

- (void)stopAnyKeyDismissMonitoring {
    self.hotkeyMonitor.anyKeyDismissHandler = nil;
}

@end


@implementation SPModeHotkeyProxy

- (void)hotkeyMonitorDidBeginTrigger {
}

- (void)hotkeyMonitorDidCancelTrigger {
}

- (void)hotkeyMonitorDidDetectHoldStart {
}

- (void)hotkeyMonitorDidDetectHoldEnd {
}

- (void)hotkeyMonitorDidDetectTapStart {
    if (self.onPress) {
        self.onPress();
    } else {
        [self.target cycleOutputMode];
    }
    // Toggle mode parked the monitor in "recording"; there is none.
    [self.monitor resetToIdle];
}

- (void)hotkeyMonitorDidDetectTapEnd {
}

@end

@implementation SPLipsHotkeyProxy

- (void)hotkeyMonitorDidBeginTrigger {
    [self.target lipsKeyDown];
}

- (void)hotkeyMonitorDidCancelTrigger {
    [self.target lipsKeyCancelled];
}

- (void)hotkeyMonitorDidDetectHoldStart {
    [self.target lipsHoldStarted];
}

- (void)hotkeyMonitorDidDetectHoldEnd {
    [self.target lipsKeyUp];
}

- (void)hotkeyMonitorDidDetectTapStart {
}

- (void)hotkeyMonitorDidDetectTapEnd {
}

- (void)hotkeyMonitorDidCancelHoldForCompanionInput {
    [self.target lipsKeyCancelled];
}

@end

@implementation SPHotkeyPurposeProxy

- (void)hotkeyMonitorDidBeginTrigger {
    [self.target beginTriggerForPurpose:self.purpose];
}

- (void)hotkeyMonitorDidCancelTrigger {
    [self.target hotkeyMonitorDidCancelTrigger];
}

- (void)hotkeyMonitorDidDetectHoldStart {
    self.target.pendingSessionPurpose = self.purpose;
    [self.target hotkeyMonitorDidDetectHoldStart];
}

- (void)hotkeyMonitorDidDetectHoldEnd {
    [self.target hotkeyMonitorDidDetectHoldEnd];
}

- (void)hotkeyMonitorDidDetectTapStart {
    self.target.pendingSessionPurpose = self.purpose;
    [self.target hotkeyMonitorDidDetectTapStart];
}

- (void)hotkeyMonitorDidDetectTapEnd {
    [self.target hotkeyMonitorDidDetectTapEnd];
}

- (void)hotkeyMonitorDidCancelHoldForCompanionInput {
    [self.target hotkeyMonitorDidCancelHoldForCompanionInput];
}

@end
