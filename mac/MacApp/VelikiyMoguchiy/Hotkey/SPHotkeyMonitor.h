#import <Foundation/Foundation.h>

/// Delegate protocol for hotkey events
@protocol SPHotkeyMonitorDelegate <NSObject>
/// Fired immediately on trigger-down, before tap/hold classification.
- (void)hotkeyMonitorDidBeginTrigger;
/// Fired when an unconfirmed trigger is discarded (for example, a short tap
/// while configured for hold mode).
- (void)hotkeyMonitorDidCancelTrigger;
- (void)hotkeyMonitorDidDetectHoldStart;
- (void)hotkeyMonitorDidDetectHoldEnd;
- (void)hotkeyMonitorDidDetectTapStart;
- (void)hotkeyMonitorDidDetectTapEnd;

@optional
/// A modifier-only trigger that had already started a hold recording was
/// combined with another key or a system function key (Fn+brightness, a
/// shortcut such as Cmd-C): the user is not dictating, so the session must be
/// discarded. Unconfirmed (pending) triggers get hotkeyMonitorDidCancelTrigger.
- (void)hotkeyMonitorDidCancelHoldForCompanionInput;
/// In hold mode the trigger was pressed and let go too quickly to record
/// (after hotkeyMonitorDidCancelTrigger): the user may not know to hold it.
- (void)hotkeyMonitorDidIgnoreShortPress;
@end

/// Stamped (kCGEventSourceUserData) on every key event the app itself posts —
/// streamed typing, Cmd+V — so the hotkey monitor does not mistake its own
/// output for the user pressing a key together with the trigger. The Rust
/// typing path (velikiy-moguchiy-core/src/unicode_typing.rs) uses the same value.
#define SPSyntheticEventMarker 0x56454C494B495931LL // "VELIKIY1"

/// True for a system-defined event that is a keyboard function-layer action
/// (brightness, volume, media, illumination) being pressed: subtype 8 (aux
/// control buttons), key type below 24, key-down state. Globe/Menu (25) is
/// deliberately excluded so the trigger key cannot cancel itself. Pure
/// decoding of NSEvent subtype/data1, exposed for tests.
BOOL SPHotkeyIsFunctionLayerSystemEvent(int16_t subtype, NSInteger data1);

typedef NS_ENUM(uint8_t, SPHotkeyMatchKind) {
    SPHotkeyMatchKindModifierOnly = 0,
    SPHotkeyMatchKindKeyDown = 1,
    /// A mouse button: `targetKeyCode` holds its 1-based number (3 = middle,
    /// 4 / 5 = the side buttons). The monitor then watches only other-mouse
    /// events and swallows that button's events while it runs.
    SPHotkeyMatchKindMouseButton = 2,
};

/// Key-down and mouse-button-down events macOS has counted system-wide
/// (kCGEventSourceStateHIDSystemState). Readable without any permission, so it
/// also reveals presses the monitor itself is never shown.
uint64_t SPHotkeySystemPressCount(void);

/// Whether a CGEvent button number (kCGMouseEventButtonNumber: 0-based, middle
/// is 2) is the configured 1-based button. Only buttons 3 and up can match:
/// left and right clicks are never a trigger.
BOOL SPHotkeyMouseButtonMatches(int64_t cgButtonNumber, NSInteger configuredButton);

typedef NS_ENUM(uint8_t, SPHotkeyTriggerMode) {
    SPHotkeyTriggerModeHold = 0,
    SPHotkeyTriggerModeToggle = 1,
    SPHotkeyTriggerModeDoubleTap = 2,
    SPHotkeyTriggerModeAuto = 3,
};

@interface SPHotkeyMonitor : NSObject

/// Threshold in milliseconds to distinguish tap from hold. Default 180ms.
@property (nonatomic, assign) NSTimeInterval holdThresholdMs;

@property (nonatomic, assign) SPHotkeyTriggerMode triggerMode;

/// Primary key code to monitor (default: 63 = Fn/Globe)
@property (nonatomic, assign) NSInteger targetKeyCode;

/// Alternative key code to monitor (default: 179 = Globe on newer keyboards), 0 to disable
@property (nonatomic, assign) NSInteger altKeyCode;

/// Modifier flag to check for key state (default: 0x800000 = NSEventModifierFlagFunction)
@property (nonatomic, assign) NSUInteger targetModifierFlag;

/// How the trigger hotkey should be matched.
@property (nonatomic, assign) uint8_t targetMatchKind;

/// Maximum interval from the first press to the second press in double-tap
/// mode. Defaults to the user's macOS double-click interval.
@property (nonatomic, assign) NSTimeInterval doubleTapThresholdMs;

- (instancetype)initWithDelegate:(id<SPHotkeyMonitorDelegate>)delegate;
- (void)start;
- (void)stop;

/// Source of the system press count a modifier-only trigger compares against
/// the presses it observed: a key or click made while the trigger was held that
/// the monitor did not see (no Accessibility permission hides key events from
/// it) still turns the press into a chord. Defaults to SPHotkeySystemPressCount.
@property (nonatomic, copy) uint64_t (^systemPressCounter)(void);

/// Temporarily suppress hotkey detection (e.g. while a menu is open).
@property (nonatomic, assign) BOOL suspended;

/// Reset the state machine to idle. Call when an external event (e.g. audio error)
/// terminates a recording session outside the normal hotkey flow.
- (void)resetToIdle;

/// Arm the state machine as a confirmed hands-free (toggle) recording. Call when
/// an external source (e.g. the status bar menu) starts a session outside the
/// hotkey flow, so the next trigger press ends that session instead of starting
/// a second one. Pair with `resetToIdle` when the same source ends the session.
- (void)markExternalToggleRecording;

/// Whether the number/Enter handler keys can actually be swallowed globally
/// right now. For modifier-only triggers this reflects the Carbon hotkey
/// capture (the tap stays listen-only for its whole life); for non-modifier
/// triggers it reflects the consuming tap.
@property (nonatomic, assign, readonly) BOOL canConsumeHandlerKeyEvents;

/// How many number shortcuts (1..limit) the capture should swallow while
/// numberKeyHandler is set. Set BEFORE assigning numberKeyHandler so digits
/// without a template are never consumed. Default 9.
@property (assign) NSInteger numberKeyCaptureLimit;

/// Optional block called when a number key (1-9) is pressed.
/// Return YES to consume the key event so it does not continue to the target app.
/// Atomic: read from the event-tap thread while set/cleared on the main thread.
@property (copy) BOOL (^numberKeyHandler)(NSInteger number);

/// Optional block called when any non-template key is pressed (any key except 1-9).
/// The key event is NOT consumed — it always passes through to the target app.
/// Used to dismiss the overlay when the user resumes typing after text insertion.
/// Atomic: read from the event-tap thread while set/cleared on the main thread.
@property (copy) void (^anyKeyDismissHandler)(void);

/// Optional block called when Return/Enter is pressed.
/// Return YES to consume the key event. It is only honoured when the active
/// CGEventTap can suppress the event globally.
/// Atomic: read from the event-tap thread while set/cleared on the main thread.
@property (copy) BOOL (^enterKeyHandler)(void);

/// Key code (without modifiers) that cancels the active session; 0 disables it.
/// Only takes effect while abortKeyHandler is set.
@property (nonatomic, assign) NSInteger abortKeyCode;

/// Optional block called when abortKeyCode is pressed. Set it only while a
/// session is active so the key stays untouched the rest of the time.
/// Return YES to consume the key event. Like enterKeyHandler, consumption needs
/// the Carbon capture (modifier-only triggers) or a consuming tap.
/// Atomic: read from the event-tap thread while set/cleared on the main thread.
@property (copy) BOOL (^abortKeyHandler)(void);

@end
