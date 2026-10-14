#import "SPHotkeyMonitor.h"
#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <stdatomic.h>

// Everything one tap thread owns, handed to it at creation. The thread never
// reads the monitor's shared tap properties: after a teardown that timed out,
// those may already belong to a replacement thread, and a late worker reading
// them could disable the new tap or signal the wrong semaphore. The monitor
// publishes the live context under @synchronized(self) and only ever clears
// state belonging to the context it still considers current.
@class SPHotkeyMonitor;

@interface SPTapContext : NSObject
// The monitor this generation belongs to. Weak: the context outlives a
// timed-out teardown, and a late callback must not resurrect the monitor.
@property (nonatomic, weak) SPHotkeyMonitor *monitor;
@property (nonatomic, strong) dispatch_semaphore_t ready;
@property (nonatomic, strong) dispatch_semaphore_t shutdown;
// Set by stopTapThread. A thread that is still starting up checks this
// before installing its tap, so a stop that raced the launch cannot leave a
// live tap behind.
@property (atomic, assign) BOOL stopRequested;
@property (atomic, assign) CFRunLoopRef runLoop;
// The tap this thread created, published so a stop can disable it promptly.
// Only ever released by the owning thread.
@property (atomic, assign) CFMachPortRef tap;

/// The monitor, but only while this context is still its live generation and
/// no stop has been requested. nil otherwise, so callbacks from a superseded
/// tap become no-ops.
- (SPHotkeyMonitor *)currentMonitor;
@end

typedef NS_ENUM(NSInteger, SPHotkeyState) {
    SPHotkeyStateIdle,
    SPHotkeyStatePending,        // Trigger key pressed, waiting to determine tap vs hold
    SPHotkeyStateDoubleTapFirstDown, // First press is down; no audio starts yet
    SPHotkeyStateDoubleTapWaiting,   // First tap completed; waiting for second press
    SPHotkeyStateDoubleTapSecondDown, // Second press confirmed; pre-capture is active
    SPHotkeyStateRecordingHold,  // Confirmed hold, recording
    SPHotkeyStateRecordingToggle, // Confirmed tap, free-hands recording
    SPHotkeyStateDoubleTapStopPending, // Trigger is down; wait to rule out a shortcut
    SPHotkeyStateConsumeKeyUp,   // Waiting to consume keyUp after toggle-stop
};

@interface SPHotkeyMonitor ()

@property (nonatomic, weak) id<SPHotkeyMonitorDelegate> delegate;
@property (nonatomic, assign) SPHotkeyState state;
@property (nonatomic, strong) NSTimer *holdTimer;
@property (nonatomic, strong) NSTimer *doubleTapTimer;
@property (nonatomic, assign) BOOL triggerDown;
@property (nonatomic, assign) CFMachPortRef eventTap;
@property (nonatomic, assign) CFRunLoopSourceRef runLoopSource;
@property (nonatomic, strong) id globalMonitorRef;
@property (nonatomic, strong) id localMonitorRef;
@property (nonatomic, assign) BOOL running;
// The CGEventTap lives on this dedicated thread. A consuming tap's callback
// gates every keyboard event in the session, so it must never share the
// main thread: when the main thread stalls (ASR finalization, paste,
// overlay work — exactly when the user releases the trigger key), a
// main-thread tap would delay or swallow in-flight events for the whole
// system. A dedicated thread also keeps trigger latency independent of
// main-thread load for listen-only taps.
// (History: the phantom-keys-at-quit bug, issues #57/#65, was long blamed
// on tap behavior here; the actual culprit was SPPermissionManager leaking
// its permission-probe taps — see isInputMonitoringGranted.)
@property (nonatomic, strong) NSThread *tapThread;
// The context of the tap thread the monitor currently considers live. Read
// and written under @synchronized(self); a worker compares its own context
// against this before touching any shared state.
@property (nonatomic, strong) SPTapContext *tapContext;
// Whether the tap can consume events (an ACTIVE/filtering tap was created).
// Internal only — callers consult canConsumeHandlerKeyEvents, which also
// covers the Carbon capture used for modifier-only triggers.
@property (nonatomic, assign) BOOL canConsumeGlobalKeyEvents;
// Carbon RegisterEventHotKey capture for the template number shortcuts and
// the raw-ASR Return accept, used whenever the trigger is modifier-only.
// Rationale: a consuming CGEventTap gates every keystroke in the session,
// so a busy app adds latency to all typing system-wide; Carbon hotkeys
// swallow exactly the wanted keys inside WindowServer with no tap at all,
// letting the tap stay listen-only for its entire life on modifier-only
// triggers. Non-modifier triggers still need the consuming tap.
// `carbonCaptureActive` is atomic: read from the tap thread.
@property (assign) BOOL carbonCaptureActive;
@property (nonatomic, assign) EventHandlerRef carbonHotKeyHandler;
@property (nonatomic, strong) NSMutableArray<NSValue *> *carbonHotKeyRefs;
// Key codes whose keyUp must also be swallowed after a handled keyDown
// (template number shortcuts and the raw-ASR-accept Return key).
@property (nonatomic, strong) NSMutableSet<NSNumber *> *suppressedKeyCodes;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *suppressedHotkeyKeyCodes;
@property (nonatomic, strong) dispatch_block_t pendingModifierReleaseBlock;
// Presses at the start of the current trigger gesture: the system count and
// the monitor's own observedPressCount. Main thread.
@property (nonatomic, assign) uint64_t gestureSystemPressBase;
@property (nonatomic, assign) uint64_t gestureObservedPressBase;

- (void)handleFlagsChangedEvent:(CGEventRef)event;
- (BOOL)handleNSEvent:(NSEvent *)event;
- (BOOL)isTargetKeyCode:(NSInteger)keyCode;
- (BOOL)isModifierOnlyMatchKind:(uint8_t)matchKind;
- (BOOL)isMouseMatchKind;
- (BOOL)handleMouseButtonEvent:(CGEventRef)event type:(CGEventType)type;
- (void)handleMouseNSEvent:(NSEvent *)event;
- (BOOL)keyModifiers:(NSUInteger)flags matchRequiredModifiers:(NSUInteger)requiredFlags;
- (BOOL)isRecordingState;
- (BOOL)hasUnconfirmedPreCapture;
- (BOOL)handleNumberKeyWithKeyCode:(NSInteger)keyCode;
- (BOOL)handleEnterKeyWithKeyCode:(NSInteger)keyCode;
- (BOOL)handleAbortKeyWithKeyCode:(NSInteger)keyCode;
- (BOOL)consumeSuppressedKeyForKeyCode:(NSInteger)keyCode isKeyUp:(BOOL)isKeyUp;
- (BOOL)isSuppressedHotkeyKeyCode:(NSNumber *)keyCodeNumber;
- (void)addSuppressedHotkeyKeyCode:(NSNumber *)keyCodeNumber;
- (BOOL)removeSuppressedHotkeyKeyCodeIfPresent:(NSNumber *)keyCodeNumber;
- (void)tapThreadMain:(SPTapContext *)context;
- (BOOL)needsEventConsumption;
- (void)startTapThread;
- (void)stopTapThread;
- (void)updateCarbonKeyCaptureIfNeeded;
- (void)unregisterCarbonHotKeys;
- (void)handleCarbonHotKeyID:(UInt32)identifier;
- (BOOL)isCarbonCapturedKeyCode:(NSInteger)keyCode;
- (NSUInteger)currentModifierFlags;
- (void)cancelPendingModifierRelease;
- (void)scheduleModifierRelease;
- (void)cancelDoubleTapTimer;
- (void)cancelDoubleTapCandidateForInterveningInput;
- (void)handleTriggerDown;
- (void)handleTriggerUp;
- (void)handleCompanionInput;
- (void)cancelTriggerForCompanionInput;
- (void)noteObservedPress;
- (void)beginGesturePressCount;
- (BOOL)gestureHadUnobservedPress;

@end

@implementation SPTapContext

- (SPHotkeyMonitor *)currentMonitor {
    if (self.stopRequested) return nil;
    SPHotkeyMonitor *monitor = self.monitor;
    if (!monitor) return nil;
    @synchronized (monitor) {
        // `tapContext` is the monitor's live generation; anything else is a
        // tap whose teardown has already been ordered.
        if (monitor.tapContext != self) return nil;
    }
    return monitor;
}

@end

static NSInteger numberForKeyCode(NSInteger keyCode) {
    switch (keyCode) {
        case 18: return 1;
        case 19: return 2;
        case 20: return 3;
        case 21: return 4;
        case 23: return 5;
        case 22: return 6;
        case 26: return 7;
        case 28: return 8;
        case 25: return 9;
        default: return 0;
    }
}

static BOOL isReturnKeyCode(NSInteger keyCode) {
    return keyCode == 36 || keyCode == 76; // Return or keypad Enter
}

// IOKit hidsystem/ev_keymap.h. systemDefined subtype 8 carries the keyboard's
// auxiliary control keys: data1's high 16 bits are the key type (0..23 is the
// scanned brightness / volume / media / illumination family), bits 8-15 the
// state (0x0A down, 0x0B up). Brightness, volume and backlight keys pressed
// with Fn held never produce a keyDown, only this event, so a modifier-only
// trigger can only learn about them here. Behaviour specified by OpenLess
// 6a7cd5f (AGPL-3.0, specification only; this implementation is our own).
static const int16_t SPAuxControlButtonsSubtype = 8;
static const uint16_t SPScannedSpecialKeyCount = 24;
static const uint8_t SPAuxKeyStateDown = 0x0A;

BOOL SPHotkeyMouseButtonMatches(int64_t cgButtonNumber, NSInteger configuredButton) {
    return configuredButton >= 3 && cgButtonNumber >= 2 && cgButtonNumber + 1 == configuredButton;
}

BOOL SPHotkeyIsFunctionLayerSystemEvent(int16_t subtype, NSInteger data1) {
    if (subtype != SPAuxControlButtonsSubtype) return NO;
    uint16_t keyType = (uint16_t)(((uint64_t)data1 >> 16) & 0xffff);
    uint8_t keyState = (uint8_t)((data1 >> 8) & 0xff);
    return keyType < SPScannedSpecialKeyCount && keyState == SPAuxKeyStateDown;
}

uint64_t SPHotkeySystemPressCount(void) {
    const CGEventSourceStateID state = kCGEventSourceStateHIDSystemState;
    return (uint64_t)CGEventSourceCounterForEventType(state, kCGEventKeyDown) +
           CGEventSourceCounterForEventType(state, kCGEventLeftMouseDown) +
           CGEventSourceCounterForEventType(state, kCGEventRightMouseDown) +
           CGEventSourceCounterForEventType(state, kCGEventOtherMouseDown);
}

static BOOL SPIsMouseDownEventType(CGEventType type) {
    return type == kCGEventLeftMouseDown || type == kCGEventRightMouseDown ||
           type == kCGEventOtherMouseDown;
}


// ANSI key codes for digits 1-9, indexed by the digit itself (index 0 unused).
static const UInt32 SPDigitKeyCodeForNumber[10] = {0, 18, 19, 20, 21, 23, 22, 26, 28, 25};

static const OSType SPCarbonHotKeySignature = 'VMGH';
enum {
    // IDs 1-9 are the template digits; Return/Enter and the abort key get their own IDs.
    SPCarbonHotKeyIDReturn = 100,
    SPCarbonHotKeyIDKeypadEnter = 101,
    SPCarbonHotKeyIDAbort = 102,
};

// Carbon delivers hotkey events through the main event dispatcher, so this
// runs on the main thread — no tap, no gating of the session key stream.
static OSStatus SPCarbonHotKeyPressed(EventHandlerCallRef nextHandler,
                                      EventRef event,
                                      void *userInfo) {
    SPHotkeyMonitor *monitor = (__bridge SPHotkeyMonitor *)userInfo;
    EventHotKeyID hotKeyID = { 0, 0 };
    OSStatus err = GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID,
                                     NULL, sizeof(hotKeyID), NULL, &hotKeyID);
    if (err != noErr || hotKeyID.signature != SPCarbonHotKeySignature) {
        return eventNotHandledErr;
    }
    [monitor handleCarbonHotKeyID:hotKeyID.id];
    return noErr;
}

// Run a block on the main thread in kCFRunLoopCommonModes. Unlike
// dispatch_async(main queue), this also executes while the main run loop is
// in a modal or event-tracking mode (NSAlert, Sparkle update prompts, menu
// tracking) — the main dispatch queue is NOT drained during those loops, and
// trigger handling must not freeze whenever an alert happens to be on screen.
static void SPPerformOnMainRunLoop(dispatch_block_t block) {
    if ([NSThread isMainThread]) {
        block();
        return;
    }
    CFRunLoopRef mainRunLoop = CFRunLoopGetMain();
    CFRunLoopPerformBlock(mainRunLoop, kCFRunLoopCommonModes, block);
    CFRunLoopWakeUp(mainRunLoop);
}

static const NSUInteger SPHotkeyRelevantModifierMask =
    NSEventModifierFlagCommand |
    NSEventModifierFlagOption |
    NSEventModifierFlagControl |
    NSEventModifierFlagShift |
    NSEventModifierFlagFunction;
static const CFTimeInterval SPModifierOnlyReleaseDebounceSeconds = 0.35;

// C callback for CGEventTap
static CGEventRef hotkeyEventCallback(CGEventTapProxy proxy,
                                       CGEventType type,
                                       CGEventRef event,
                                       void *userInfo) {
    // userInfo is the generation's context, not the monitor: after a
    // teardown that timed out, this callback can still fire for a tap the
    // monitor no longer considers live, and acting on it would drive the
    // state machine from a stale generation.
    SPTapContext *context = (__bridge SPTapContext *)userInfo;
    SPHotkeyMonitor *monitor = [context currentMonitor];
    if (!monitor) return event;

    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        // Only re-enable the tap if we are still running.  During teardown
        // the tap may fire one last time — re-enabling it would race with
        // the CFRelease in -stop.
        if (monitor.running && monitor.eventTap) {
            CGEventTapEnable(monitor.eventTap, true);
        }
        return event;
    }

    if (!monitor.running || monitor.suspended) return event;

    if (SPIsMouseDownEventType(type) && ![monitor isMouseMatchKind]) {
        [monitor noteObservedPress];
        SPPerformOnMainRunLoop(^{
            [monitor handleCompanionInput];
        });
        return event;
    }

    if (type == kCGEventOtherMouseDown || type == kCGEventOtherMouseUp) {
        return [monitor handleMouseButtonEvent:event type:type] ? NULL : event;
    }

    if (type == kCGEventFlagsChanged) {
        [monitor handleFlagsChangedEvent:event];
    } else if (type == NSEventTypeSystemDefined) {
        // Fn+brightness/volume/media: not a keyDown, so it is invisible to the
        // key path below. Listen only; the event always passes through.
        NSEvent *nsEvent = [NSEvent eventWithCGEvent:event];
        if (nsEvent && SPHotkeyIsFunctionLayerSystemEvent(nsEvent.subtype, nsEvent.data1)) {
            SPPerformOnMainRunLoop(^{
                [monitor handleCompanionInput];
            });
        }
    } else if (type == kCGEventKeyDown || type == kCGEventKeyUp) {
        NSInteger keyCode = (NSInteger)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        NSNumber *keyCodeNumber = @(keyCode);
        NSUInteger flags = (NSUInteger)CGEventGetFlags(event);
        BOOL isRepeat = CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat) != 0;
        BOOL suppressedTriggerKey = [monitor isSuppressedHotkeyKeyCode:keyCodeNumber];
        if (type == kCGEventKeyDown) {
            [monitor noteObservedPress];
        }

        if ([monitor consumeSuppressedKeyForKeyCode:keyCode isKeyUp:(type == kCGEventKeyUp)]) {
            return monitor.canConsumeGlobalKeyEvents ? NULL : event;
        }

        if (isRepeat) {
            return event;
        }

        // A Command tap that becomes a real keyboard shortcut (for example
        // Command-C) must not count toward the double-tap gesture.
        if (type == kCGEventKeyDown && ![monitor isTargetKeyCode:keyCode]) {
            SPPerformOnMainRunLoop(^{
                [monitor cancelDoubleTapCandidateForInterveningInput];
            });
        }

        // Keys owned by the Carbon hotkey capture (template digits, raw-ASR
        // Return) are swallowed inside WindowServer AFTER taps observe them
        // and are delivered to the app as kEventHotKeyPressed. The listen-only
        // tap must leave them alone: neither invoke the handlers (that would
        // double-fire) nor treat them as overlay-dismissing input.
        if ([monitor isCarbonCapturedKeyCode:keyCode]) {
            return event;
        }

        // Forward number keys 1-9 if handler is set.
        // When handled, suppress both keyDown and keyUp so the typed digit
        // does not leak into the user's target app.
        if (type == kCGEventKeyDown && [monitor handleNumberKeyWithKeyCode:keyCode]) {
            return monitor.canConsumeGlobalKeyEvents ? NULL : event;
        }

        // Forward the abort key while a session is active. When handled,
        // suppress both keyDown and keyUp so it does not leak into the target app.
        if (type == kCGEventKeyDown && [monitor handleAbortKeyWithKeyCode:keyCode]) {
            return monitor.canConsumeGlobalKeyEvents ? NULL : event;
        }

        // Forward Return/Enter to accept the raw ASR result mid-correction.
        // When handled, suppress both keyDown and keyUp so the newline does
        // not leak into the user's target app.
        if (type == kCGEventKeyDown && [monitor handleEnterKeyWithKeyCode:keyCode]) {
            return monitor.canConsumeGlobalKeyEvents ? NULL : event;
        }

        // Any keyDown (not handled by number keys above) dismisses the overlay.
        // The event is NOT consumed — it passes through to the target app.
        if (type == kCGEventKeyDown && monitor.anyKeyDismissHandler) {
            void (^handler)(void) = monitor.anyKeyDismissHandler;
            SPPerformOnMainRunLoop(^{
                handler();
            });
        }

        // Any other key pressed while a modifier-only trigger is held is a
        // combo (Cmd-C, Fn+arrow), not a request to dictate. Queued on main
        // so it is ordered before the trigger's own release.
        if (type == kCGEventKeyDown && ![monitor isTargetKeyCode:keyCode] &&
            CGEventGetIntegerValueField(event, kCGEventSourceUserData) != SPSyntheticEventMarker) {
            SPPerformOnMainRunLoop(^{
                [monitor cancelTriggerForCompanionInput];
            });
        }

        BOOL handlesModifierOnlyTrigger =
            [monitor isModifierOnlyMatchKind:monitor.targetMatchKind] &&
            [monitor isTargetKeyCode:keyCode];
        BOOL handlesKeyDownMatchedTrigger =
            ![monitor isModifierOnlyMatchKind:monitor.targetMatchKind] &&
            [monitor isTargetKeyCode:keyCode] &&
            ([monitor keyModifiers:flags matchRequiredModifiers:monitor.targetModifierFlag] ||
             (type == kCGEventKeyUp && suppressedTriggerKey));

        if (handlesModifierOnlyTrigger || handlesKeyDownMatchedTrigger) {
            NSLog(@"[VelikiyMoguchiy] Key event: type=%d keyCode=%ld", type, (long)keyCode);
            BOOL isDown = (type == kCGEventKeyDown);
            // Dedup and mutate triggerDown ON THE MAIN THREAD, not here. The
            // same physical event also arrives via the NSEvent monitor path
            // on the main thread; if the tap thread flips triggerDown ahead
            // of the main-thread state machine, a fast tap gets processed
            // twice (start + immediate stop). All edges must be decided
            // against triggerDown serially on main.
            SPPerformOnMainRunLoop(^{
                if (isDown == monitor.triggerDown) return;
                monitor.triggerDown = isDown;
                if (isDown) {
                    [monitor handleTriggerDown];
                } else {
                    [monitor handleTriggerUp];
                }
            });
            if (handlesKeyDownMatchedTrigger && isDown) {
                [monitor addSuppressedHotkeyKeyCode:keyCodeNumber];
                return NULL;
            }
            if (handlesKeyDownMatchedTrigger && suppressedTriggerKey) {
                [monitor removeSuppressedHotkeyKeyCodeIfPresent:keyCodeNumber];
                return NULL;
            }
        }

        if (type == kCGEventKeyUp && [monitor removeSuppressedHotkeyKeyCodeIfPresent:keyCodeNumber]) {
            return NULL;
        }
    }

    return event;
}

@implementation SPHotkeyMonitor {
    // Key and mouse-button presses this monitor was shown, from the tap thread
    // or the NSEvent monitors.
    _Atomic uint64_t _observedPressCount;
}

- (instancetype)initWithDelegate:(id<SPHotkeyMonitorDelegate>)delegate {
    self = [super init];
    if (self) {
        _delegate = delegate;
        _holdThresholdMs = 180.0;
        _doubleTapThresholdMs = NSEvent.doubleClickInterval * 1000.0;
        _state = SPHotkeyStateIdle;
        _triggerDown = NO;
        _targetKeyCode = 63;       // kVK_Function (Fn)
        _altKeyCode = 179;         // Globe key on newer keyboards
        _targetModifierFlag = 0x00800000; // NX_SECONDARYFNMASK
        _targetMatchKind = SPHotkeyMatchKindModifierOnly;
        _canConsumeGlobalKeyEvents = NO;
        _suppressedKeyCodes = [NSMutableSet set];
        _suppressedHotkeyKeyCodes = [NSMutableSet set];
        _numberKeyCaptureLimit = 9;
        _carbonHotKeyRefs = [NSMutableArray array];
        _systemPressCounter = ^uint64_t {
            return SPHotkeySystemPressCount();
        };
    }
    return self;
}

- (BOOL)isMouseMatchKind {
    return self.targetMatchKind == SPHotkeyMatchKindMouseButton;
}

- (void)start {
    if (self.globalMonitorRef) return;
    self.running = YES;

    __weak typeof(self) weakSelf = self;

    if ([self isMouseMatchKind]) {
        // Only the tap sees the button early enough to swallow it. The NSEvent
        // monitor is the fallback for when the tap cannot be created; it can
        // observe the button but not consume it.
        self.globalMonitorRef = [NSEvent addGlobalMonitorForEventsMatchingMask:(NSEventMaskOtherMouseDown | NSEventMaskOtherMouseUp)
                                                                      handler:^(NSEvent *event) {
            [weakSelf handleMouseNSEvent:event];
        }];
        NSLog(@"[VelikiyMoguchiy] Mouse button monitor started (button=%ld threshold=%.0fms)",
              (long)self.targetKeyCode, self.holdThresholdMs);
        [self startTapThread];
        return;
    }

    // Use both global + local NSEvent monitors for maximum coverage.
    // Global monitor catches events when other apps are focused.
    // Local monitor catches events when our app (menu bar) is focused.
    NSEventMask keyboardTriggerMask = NSEventMaskFlagsChanged | NSEventMaskKeyDown | NSEventMaskKeyUp |
                                      NSEventMaskSystemDefined | NSEventMaskLeftMouseDown |
                                      NSEventMaskRightMouseDown | NSEventMaskOtherMouseDown;
    self.globalMonitorRef = [NSEvent addGlobalMonitorForEventsMatchingMask:keyboardTriggerMask
                                                                  handler:^(NSEvent *event) {
        [weakSelf handleNSEvent:event];
    }];

    self.localMonitorRef = [NSEvent addLocalMonitorForEventsMatchingMask:keyboardTriggerMask
                                                                handler:^NSEvent *(NSEvent *event) {
        return [weakSelf handleNSEvent:event] ? nil : event;
    }];

    NSLog(@"[VelikiyMoguchiy] Hotkey monitor started via NSEvent monitors (trigger=%ld/%ld flag=0x%lx kind=%u threshold=%.0fms)",
          (long)self.targetKeyCode,
          (long)self.altKeyCode,
          (unsigned long)self.targetModifierFlag,
          self.targetMatchKind,
          self.holdThresholdMs);

    // Also try CGEventTap as additional source, hosted on a dedicated thread
    // (see tapThread property for why it must never share the main thread).
    [self startTapThread];

    // Handlers may already be installed (e.g. monitor restart after a config
    // reload mid-session); rebuild the Carbon capture to match them.
    [self updateCarbonKeyCaptureIfNeeded];
}

- (BOOL)needsEventConsumption {
    // Modifier-only triggers (Fn, Option, …) NEVER consume via the tap: the
    // template number shortcuts and the raw-ASR Enter accept are swallowed
    // with Carbon RegisterEventHotKey instead (see carbonCaptureActive), so
    // the tap stays listen-only for its entire life — created once at start,
    // destroyed once at stop, never upgraded or cycled mid-run.
    // Non-modifier triggers consume their keyDown/keyUp so the trigger key
    // does not leak into the focused app.
    if ([self isMouseMatchKind]) return YES;
    return ![self isModifierOnlyMatchKind:self.targetMatchKind];
}

- (void)startTapThread {
    if (self.tapThread) return;
    SPTapContext *context = [[SPTapContext alloc] init];
    context.monitor = self;
    context.ready = dispatch_semaphore_create(0);
    context.shutdown = dispatch_semaphore_create(0);
    @synchronized (self) {
        self.tapContext = context;
    }
    NSThread *thread = [[NSThread alloc] initWithTarget:self
                                               selector:@selector(tapThreadMain:)
                                                 object:context];
    thread.name = @"velikiy-moguchiy.hotkey-tap";
    thread.qualityOfService = NSQualityOfServiceUserInteractive;
    self.tapThread = thread;
    [thread start];
    // Wait for the tap to be installed so canConsumeGlobalKeyEvents is
    // accurate for callers that read it right after this returns.
    dispatch_semaphore_wait(context.ready, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)));

    if (!self.eventTap) {
        NSLog(@"[VelikiyMoguchiy] CGEventTap unavailable (ok, NSEvent monitors active)");
    }
}

- (void)stopTapThread {
    if (!self.tapThread) return;
    SPTapContext *context;
    @synchronized (self) {
        context = self.tapContext;
        // Unpublish first: from here on the worker owns its teardown alone
        // and can no longer touch the monitor's shared tap state, so a
        // replacement thread started right after this is safe from it.
        self.tapContext = nil;
        self.eventTap = NULL;
        self.runLoopSource = NULL;
    }
    // Tell a thread that has not finished starting up not to install a tap,
    // and disable one that already exists so it stops gating the session
    // event stream immediately.
    context.stopRequested = YES;
    CFMachPortRef tap = context.tap;
    if (tap) {
        CGEventTapEnable(tap, false);
    }
    CFRunLoopRef tapRunLoop = context.runLoop;
    if (tapRunLoop) {
        CFRunLoopStop(tapRunLoop);
    }
    if (context.shutdown &&
        dispatch_semaphore_wait(context.shutdown,
                                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC))) != 0) {
        // The worker did not exit in time. Everything it still has to tear
        // down belongs to its own context, so a replacement thread cannot be
        // clobbered by its late cleanup.
        NSLog(@"[VelikiyMoguchiy] Tap thread teardown timed out; late cleanup is context-owned");
    }
    self.tapThread = nil;
    self.canConsumeGlobalKeyEvents = NO;
}

#pragma mark - Carbon hotkey capture

- (void)installCarbonHotKeyHandlerIfNeeded {
    if (self.carbonHotKeyHandler) return;
    EventTypeSpec spec = { kEventClassKeyboard, kEventHotKeyPressed };
    EventHandlerRef handler = NULL;
    OSStatus err = InstallEventHandler(GetEventDispatcherTarget(),
                                       SPCarbonHotKeyPressed,
                                       1, &spec,
                                       (__bridge void *)self,
                                       &handler);
    if (err == noErr) {
        self.carbonHotKeyHandler = handler;
    } else {
        NSLog(@"[VelikiyMoguchiy] InstallEventHandler for hotkey capture failed (err=%d)", (int)err);
    }
}

- (void)registerCarbonHotKeyForKeyCode:(UInt32)keyCode identifier:(UInt32)identifier {
    EventHotKeyID hotKeyID = { SPCarbonHotKeySignature, identifier };
    EventHotKeyRef ref = NULL;
    OSStatus err = RegisterEventHotKey(keyCode, 0, hotKeyID,
                                       GetEventDispatcherTarget(), 0, &ref);
    if (err == noErr && ref) {
        [self.carbonHotKeyRefs addObject:[NSValue valueWithPointer:ref]];
    } else {
        NSLog(@"[VelikiyMoguchiy] RegisterEventHotKey failed for keyCode=%u (err=%d)", keyCode, (int)err);
    }
}

- (void)unregisterCarbonHotKeys {
    for (NSValue *value in self.carbonHotKeyRefs) {
        EventHotKeyRef ref = (EventHotKeyRef)value.pointerValue;
        if (ref) UnregisterEventHotKey(ref);
    }
    [self.carbonHotKeyRefs removeAllObjects];
    self.carbonCaptureActive = NO;
}

// (Re)build the Carbon hotkey registrations from the current handler state.
// Main thread only: Carbon registration and the handler setters both live
// there, so carbonCaptureActive is accurate as soon as a setter returns.
- (void)updateCarbonKeyCaptureIfNeeded {
    if (![NSThread isMainThread]) {
        SPPerformOnMainRunLoop(^{ [self updateCarbonKeyCaptureIfNeeded]; });
        return;
    }
    [self unregisterCarbonHotKeys];
    if (!self.running) return;
    if (![self isModifierOnlyMatchKind:self.targetMatchKind]) return;

    BOOL wantsNumbers = (self.numberKeyHandler != nil);
    BOOL wantsEnter = (self.enterKeyHandler != nil);
    BOOL wantsAbort = (self.abortKeyHandler != nil && self.abortKeyCode != 0);
    if (!wantsNumbers && !wantsEnter && !wantsAbort) return;

    [self installCarbonHotKeyHandlerIfNeeded];
    if (!self.carbonHotKeyHandler) return;

    if (wantsNumbers) {
        NSInteger limit = MIN(MAX(self.numberKeyCaptureLimit, (NSInteger)0), (NSInteger)9);
        for (NSInteger number = 1; number <= limit; number++) {
            [self registerCarbonHotKeyForKeyCode:SPDigitKeyCodeForNumber[number]
                                      identifier:(UInt32)number];
        }
    }
    if (wantsEnter) {
        [self registerCarbonHotKeyForKeyCode:36 identifier:SPCarbonHotKeyIDReturn];
        [self registerCarbonHotKeyForKeyCode:76 identifier:SPCarbonHotKeyIDKeypadEnter];
    }
    if (wantsAbort) {
        [self registerCarbonHotKeyForKeyCode:(UInt32)self.abortKeyCode identifier:SPCarbonHotKeyIDAbort];
    }
    self.carbonCaptureActive = (self.carbonHotKeyRefs.count > 0);
    NSLog(@"[VelikiyMoguchiy] Carbon key capture %@ (numbers=%d enter=%d abort=%d registered=%lu)",
          self.carbonCaptureActive ? @"active" : @"unavailable",
          wantsNumbers, wantsEnter, wantsAbort, (unsigned long)self.carbonHotKeyRefs.count);
}

- (BOOL)isCarbonCapturedKeyCode:(NSInteger)keyCode {
    if (!self.carbonCaptureActive) return NO;
    if (self.numberKeyHandler) {
        NSInteger number = numberForKeyCode(keyCode);
        NSInteger limit = MIN(MAX(self.numberKeyCaptureLimit, (NSInteger)0), (NSInteger)9);
        if (number >= 1 && number <= limit) return YES;
    }
    if (self.enterKeyHandler && isReturnKeyCode(keyCode)) return YES;
    if (self.abortKeyHandler && self.abortKeyCode != 0 && keyCode == self.abortKeyCode) return YES;
    return NO;
}

- (void)handleCarbonHotKeyID:(UInt32)identifier {
    if (!self.running || self.suspended) return;
    if (identifier >= 1 && identifier <= 9) {
        BOOL (^numberHandler)(NSInteger) = self.numberKeyHandler;
        if (numberHandler && numberHandler((NSInteger)identifier)) {
            NSLog(@"[VelikiyMoguchiy] Carbon capture consumed digit %u", identifier);
        }
        return;
    }
    if (identifier == SPCarbonHotKeyIDReturn || identifier == SPCarbonHotKeyIDKeypadEnter) {
        BOOL (^enterHandler)(void) = self.enterKeyHandler;
        if (enterHandler) {
            enterHandler();
        }
        return;
    }
    if (identifier == SPCarbonHotKeyIDAbort) {
        BOOL (^abortHandler)(void) = self.abortKeyHandler;
        if (abortHandler) {
            abortHandler();
        }
    }
}

- (BOOL)canConsumeHandlerKeyEvents {
    if ([self isModifierOnlyMatchKind:self.targetMatchKind]) {
        return self.carbonCaptureActive;
    }
    return self.canConsumeGlobalKeyEvents;
}

- (void)tapThreadMain:(SPTapContext *)context {
    @autoreleasepool {
        // Everything this thread owns lives in `context` and in locals. The
        // monitor's shared properties are published for the callback and for
        // a prompt disable, but are never read back here: after a timed-out
        // stop they may already belong to a replacement thread, and touching
        // them would let this worker disable or release the NEW tap.
        CFMachPortRef ownTap = NULL;
        CFRunLoopSourceRef ownSource = NULL;
        // When consumption is needed, prefer active taps that can swallow
        // handled events so they do not leak into the user's focused app;
        // some systems reject one tap location but allow another, so try
        // both before degrading to listen-only. When nothing needs to be
        // consumed, go straight to listen-only (see needsEventConsumption).
        CGEventMask mask = CGEventMaskBit(kCGEventFlagsChanged)
                         | CGEventMaskBit(kCGEventKeyDown)
                         | CGEventMaskBit(kCGEventKeyUp)
                         | CGEventMaskBit(NSEventTypeSystemDefined)
                         | CGEventMaskBit(kCGEventLeftMouseDown)
                         | CGEventMaskBit(kCGEventRightMouseDown)
                         | CGEventMaskBit(kCGEventOtherMouseDown);
        if ([self isMouseMatchKind]) {
            mask = CGEventMaskBit(kCGEventOtherMouseDown) | CGEventMaskBit(kCGEventOtherMouseUp);
        }
        struct {
            CGEventTapLocation location;
            CGEventTapOptions options;
            NSString *logMessage;
        } activeAttempts[] = {
            { kCGSessionEventTap, kCGEventTapOptionDefault, @"[VelikiyMoguchiy] CGEventTap active on session stream (event suppression enabled)" },
            { kCGHIDEventTap, kCGEventTapOptionDefault, @"[VelikiyMoguchiy] CGEventTap active on HID stream (event suppression enabled)" },
            { kCGSessionEventTap, kCGEventTapOptionListenOnly, @"[VelikiyMoguchiy] CGEventTap active in listen-only fallback mode on session stream" },
            { kCGHIDEventTap, kCGEventTapOptionListenOnly, @"[VelikiyMoguchiy] CGEventTap active in listen-only fallback mode on HID stream" },
        }, listenAttempts[] = {
            { kCGSessionEventTap, kCGEventTapOptionListenOnly, @"[VelikiyMoguchiy] CGEventTap listening on session stream (no event consumption needed)" },
            { kCGHIDEventTap, kCGEventTapOptionListenOnly, @"[VelikiyMoguchiy] CGEventTap listening on HID stream (no event consumption needed)" },
        };
        BOOL wantActive = [self needsEventConsumption];
        __typeof__(activeAttempts[0]) *attempts = wantActive ? activeAttempts : listenAttempts;
        NSUInteger attemptCount = wantActive
            ? sizeof(activeAttempts) / sizeof(activeAttempts[0])
            : sizeof(listenAttempts) / sizeof(listenAttempts[0]);

        context.runLoop = CFRunLoopGetCurrent();
        BOOL consumes = NO;
        for (NSUInteger i = 0; i < attemptCount; i++) {
            // A stop that raced this launch must not leave a live tap behind.
            if (context.stopRequested) break;

            ownTap = CGEventTapCreate(attempts[i].location,
                                      kCGHeadInsertEventTap,
                                      attempts[i].options,
                                      mask,
                                      hotkeyEventCallback,
                                      (__bridge void *)context);
            if (!ownTap) {
                continue;
            }

            ownSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, ownTap, 0);
            if (!ownSource) {
                NSLog(@"[VelikiyMoguchiy] CFMachPortCreateRunLoopSource failed; trying next tap location");
                CFRelease(ownTap);
                ownTap = NULL;
                continue;
            }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), ownSource, kCFRunLoopCommonModes);
            CGEventTapEnable(ownTap, true);
            context.tap = ownTap;
            consumes = (attempts[i].options == kCGEventTapOptionDefault);
            NSLog(@"%@", attempts[i].logMessage);
            break;
        }

        // Publish for the callback and for a prompt disable, but only while
        // this thread is still the live one — and re-check stopRequested
        // under the lock so a stop that ran between the loop and here does
        // not leave a live tap published.
        BOOL abandoned = NO;
        @synchronized (self) {
            if (self.tapContext == context && !context.stopRequested) {
                self.eventTap = ownTap;
                self.runLoopSource = ownSource;
                self.canConsumeGlobalKeyEvents = consumes;
            } else {
                abandoned = YES;
            }
        }
        dispatch_semaphore_signal(context.ready);

        if (ownSource && !abandoned) {
            CFRunLoopRun(); // exits via CFRunLoopStop from -stop
        }

        // Tear the tap down on the thread that owns it, so the callback can
        // never race the release. The shared properties are unpublished under
        // the lock, and only while this thread is still the live one — after
        // a timed-out stop they belong to a replacement thread.
        @synchronized (self) {
            if (self.tapContext == context) {
                self.eventTap = NULL;
                self.runLoopSource = NULL;
                self.canConsumeGlobalKeyEvents = NO;
            }
        }
        if (ownTap) {
            CGEventTapEnable(ownTap, false);
        }
        if (ownSource) {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), ownSource, kCFRunLoopCommonModes);
            CFRelease(ownSource);
        }
        if (ownTap) {
            context.tap = NULL;
            CFRelease(ownTap);
        }
        context.runLoop = NULL;
        if (context.shutdown) {
            dispatch_semaphore_signal(context.shutdown);
        }
    }
}

- (void)setSuspended:(BOOL)suspended {
    _suspended = suspended;
    if (suspended && [self hasUnconfirmedPreCapture]) {
        [self cancelHoldTimer];
        [self cancelDoubleTapTimer];
        self.triggerDown = NO;
        self.state = SPHotkeyStateIdle;
        [self.delegate hotkeyMonitorDidCancelTrigger];
    } else if (suspended &&
               (self.state == SPHotkeyStateDoubleTapFirstDown ||
                self.state == SPHotkeyStateDoubleTapWaiting)) {
        [self cancelDoubleTapTimer];
        self.triggerDown = NO;
        self.state = SPHotkeyStateIdle;
    } else if (!suspended) {
        // Reset state machine on unsuspend — key events were missed while
        // suspended, so triggerDown and state may be out of sync with reality.
        // Without this, stale state can cause phantom key-up/down firings.
        [self cancelHoldTimer];
        [self cancelDoubleTapTimer];
        [self cancelPendingModifierRelease];
        self.triggerDown = NO;
        // A confirmed toggle recording is hands-free: no key is held, so
        // nothing about it can be stale. It must survive the menu round-trip,
        // otherwise the next trigger press starts a second session on top of
        // the running one instead of stopping it.
        if (self.state != SPHotkeyStateRecordingToggle) {
            self.state = SPHotkeyStateIdle;
        }
    }
}

- (BOOL)isTargetKeyCode:(NSInteger)keyCode {
    return keyCode == self.targetKeyCode || (self.altKeyCode != 0 && keyCode == self.altKeyCode);
}

- (BOOL)isModifierOnlyMatchKind:(uint8_t)matchKind {
    return matchKind == SPHotkeyMatchKindModifierOnly;
}

- (BOOL)keyModifiers:(NSUInteger)flags matchRequiredModifiers:(NSUInteger)requiredFlags {
    NSUInteger relevantFlags = flags & SPHotkeyRelevantModifierMask;
    return relevantFlags == requiredFlags;
}

- (BOOL)isRecordingState {
    return self.state == SPHotkeyStateRecordingHold || self.state == SPHotkeyStateRecordingToggle;
}

- (BOOL)hasUnconfirmedPreCapture {
    return self.state == SPHotkeyStatePending ||
           self.state == SPHotkeyStateDoubleTapSecondDown;
}

@synthesize numberKeyHandler = _numberKeyHandler;

- (BOOL (^)(NSInteger))numberKeyHandler {
    @synchronized (self) {
        return _numberKeyHandler;
    }
}

- (void)setNumberKeyHandler:(BOOL (^)(NSInteger))handler {
    BOOL hadHandler;
    BOOL hasHandler;
    @synchronized (self) {
        hadHandler = (_numberKeyHandler != nil);
        _numberKeyHandler = [handler copy];
        hasHandler = (_numberKeyHandler != nil);
    }
    // For modifier-only triggers the digits are captured with Carbon
    // hotkeys while the template selector is visible — the tap itself
    // stays listen-only and is never cycled.
    if (hadHandler != hasHandler) {
        [self updateCarbonKeyCaptureIfNeeded];
    }
}

- (BOOL)handleNumberKeyWithKeyCode:(NSInteger)keyCode {
    // While the Carbon capture owns the digits, the tap/NSEvent copies of the
    // same keystrokes must not invoke the handler a second time.
    if (self.carbonCaptureActive) return NO;
    if (!self.numberKeyHandler) return NO;

    NSInteger number = numberForKeyCode(keyCode);
    if (number <= 0) return NO;

    // The handler consults overlay UI state, so it must run on the main
    // thread, and the tap callback needs the consume decision synchronously.
    // Wait with a short timeout: if the main thread is too busy to answer,
    // let the key pass through rather than stall the session event stream
    // (a stalled consuming tap delays every keystroke in the session).
    BOOL (^handler)(NSInteger) = self.numberKeyHandler;
    __block BOOL handled = NO;
    if ([NSThread isMainThread]) {
        handled = handler(number);
    } else {
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block BOOL mainResult = NO;
        SPPerformOnMainRunLoop(^{
            mainResult = handler(number);
            dispatch_semaphore_signal(done);
        });
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW,
                                                        (int64_t)(100 * NSEC_PER_MSEC))) == 0) {
            handled = mainResult;
        }
    }

    if (handled) {
        @synchronized (self) {
            [self.suppressedKeyCodes addObject:@(keyCode)];
        }
    }
    return handled;
}

@synthesize enterKeyHandler = _enterKeyHandler;

- (BOOL (^)(void))enterKeyHandler {
    @synchronized (self) {
        return _enterKeyHandler;
    }
}

- (void)setEnterKeyHandler:(BOOL (^)(void))handler {
    BOOL hadHandler;
    BOOL hasHandler;
    @synchronized (self) {
        hadHandler = (_enterKeyHandler != nil);
        _enterKeyHandler = [handler copy];
        hasHandler = (_enterKeyHandler != nil);
    }
    // Like number-key capture, the Enter accept is a Carbon hotkey while the
    // raw-ASR fallback is armed — never a tap upgrade.
    if (hadHandler != hasHandler) {
        [self updateCarbonKeyCaptureIfNeeded];
    }
}

- (BOOL)handleEnterKeyWithKeyCode:(NSInteger)keyCode {
    if (!isReturnKeyCode(keyCode)) return NO;
    // See handleNumberKeyWithKeyCode: Carbon owns the key while active.
    if (self.carbonCaptureActive) return NO;
    if (!self.enterKeyHandler) return NO;

    // Same main-thread contract and timeout rationale as
    // handleNumberKeyWithKeyCode above.
    BOOL (^handler)(void) = self.enterKeyHandler;
    __block BOOL handled = NO;
    if ([NSThread isMainThread]) {
        handled = handler();
    } else {
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block BOOL mainResult = NO;
        SPPerformOnMainRunLoop(^{
            mainResult = handler();
            dispatch_semaphore_signal(done);
        });
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW,
                                                        (int64_t)(100 * NSEC_PER_MSEC))) == 0) {
            handled = mainResult;
        }
    }

    if (handled) {
        @synchronized (self) {
            [self.suppressedKeyCodes addObject:@(keyCode)];
        }
    }
    return handled;
}

@synthesize abortKeyHandler = _abortKeyHandler;

- (BOOL (^)(void))abortKeyHandler {
    @synchronized (self) {
        return _abortKeyHandler;
    }
}

- (void)setAbortKeyHandler:(BOOL (^)(void))handler {
    BOOL hadHandler;
    BOOL hasHandler;
    @synchronized (self) {
        hadHandler = (_abortKeyHandler != nil);
        _abortKeyHandler = [handler copy];
        hasHandler = (_abortKeyHandler != nil);
    }
    if (hadHandler != hasHandler) {
        [self updateCarbonKeyCaptureIfNeeded];
    }
}

- (void)setAbortKeyCode:(NSInteger)abortKeyCode {
    if (_abortKeyCode == abortKeyCode) return;
    _abortKeyCode = abortKeyCode;
    if (self.abortKeyHandler) {
        [self updateCarbonKeyCaptureIfNeeded];
    }
}

- (BOOL)handleAbortKeyWithKeyCode:(NSInteger)keyCode {
    if (self.abortKeyCode == 0 || keyCode != self.abortKeyCode) return NO;
    // See handleNumberKeyWithKeyCode: Carbon owns the key while active.
    if (self.carbonCaptureActive) return NO;
    if (!self.abortKeyHandler) return NO;

    // Same main-thread contract and timeout rationale as
    // handleNumberKeyWithKeyCode above.
    BOOL (^handler)(void) = self.abortKeyHandler;
    __block BOOL handled = NO;
    if ([NSThread isMainThread]) {
        handled = handler();
    } else {
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block BOOL mainResult = NO;
        SPPerformOnMainRunLoop(^{
            mainResult = handler();
            dispatch_semaphore_signal(done);
        });
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW,
                                                        (int64_t)(100 * NSEC_PER_MSEC))) == 0) {
            handled = mainResult;
        }
    }

    if (handled) {
        @synchronized (self) {
            [self.suppressedKeyCodes addObject:@(keyCode)];
        }
    }
    return handled;
}

- (BOOL)consumeSuppressedKeyForKeyCode:(NSInteger)keyCode isKeyUp:(BOOL)isKeyUp {
    NSNumber *keyCodeNumber = @(keyCode);
    @synchronized (self) {
        if (![self.suppressedKeyCodes containsObject:keyCodeNumber]) {
            return NO;
        }
        if (isKeyUp) {
            [self.suppressedKeyCodes removeObject:keyCodeNumber];
        }
    }
    return YES;
}

- (BOOL)isSuppressedHotkeyKeyCode:(NSNumber *)keyCodeNumber {
    @synchronized (self) {
        return [self.suppressedHotkeyKeyCodes containsObject:keyCodeNumber];
    }
}

- (void)addSuppressedHotkeyKeyCode:(NSNumber *)keyCodeNumber {
    @synchronized (self) {
        [self.suppressedHotkeyKeyCodes addObject:keyCodeNumber];
    }
}

- (BOOL)removeSuppressedHotkeyKeyCodeIfPresent:(NSNumber *)keyCodeNumber {
    @synchronized (self) {
        if (![self.suppressedHotkeyKeyCodes containsObject:keyCodeNumber]) {
            return NO;
        }
        [self.suppressedHotkeyKeyCodes removeObject:keyCodeNumber];
        return YES;
    }
}

- (NSUInteger)currentModifierFlags {
    return [NSEvent modifierFlags] & SPHotkeyRelevantModifierMask;
}

- (BOOL)handleNSEvent:(NSEvent *)event {
    if (!self.running || self.suspended) return NO;
    if ([self isMouseMatchKind]) return NO;

    // The NSEvent monitors exist only as a fallback for when the CGEventTap
    // is unavailable (no Input Monitoring permission) or disabled. While the
    // tap is live it already sees every one of these events — earlier, on
    // its own thread. Also acting on the monitor copy would double-process
    // each physical keystroke: the tap thread outruns NSEvent delivery, so
    // a fast trigger tap arrives as down/up (tap) followed by down/up
    // (monitor) and the triggerDown dedup reads the late copies as a second
    // tap — starting a session and instantly ending it.
    CFMachPortRef tap = self.eventTap;
    if (tap && CGEventTapIsEnabled(tap)) return NO;

    if (event.type == NSEventTypeLeftMouseDown || event.type == NSEventTypeRightMouseDown ||
        event.type == NSEventTypeOtherMouseDown) {
        [self noteObservedPress];
        [self handleCompanionInput];
        return NO;
    }
    if (event.type == NSEventTypeKeyDown) {
        [self noteObservedPress];
    }

    if (event.type == NSEventTypeFlagsChanged) {
        NSUInteger flags = event.modifierFlags;
        NSInteger keyCode = event.keyCode;
        NSLog(@"[VelikiyMoguchiy] NSEvent FlagsChanged: keyCode=%ld flags=0x%lx", (long)keyCode, (unsigned long)flags);

        if ([self isModifierOnlyMatchKind:self.targetMatchKind]) {
            if (![self isTargetKeyCode:keyCode]) {
                if (self.triggerDown && (flags & self.targetModifierFlag) != 0) {
                    [self cancelDoubleTapCandidateForInterveningInput];
                }
                return NO;
            }
            BOOL keyNow = (flags & self.targetModifierFlag) != 0;
            if (keyNow != self.triggerDown) {
                self.triggerDown = keyNow;
                if (keyNow) {
                    [self handleTriggerDown];
                } else if ([self isModifierOnlyMatchKind:self.targetMatchKind]) {
                    [self scheduleModifierRelease];
                } else {
                    [self handleTriggerUp];
                }
            }
        }
    } else if (event.type == NSEventTypeSystemDefined) {
        if (SPHotkeyIsFunctionLayerSystemEvent(event.subtype, event.data1)) {
            [self handleCompanionInput];
        }
    } else if (event.type == NSEventTypeKeyDown || event.type == NSEventTypeKeyUp) {
        NSInteger keyCode = event.keyCode;
        if (event.type == NSEventTypeKeyDown && ![self isTargetKeyCode:keyCode]) {
            [self cancelDoubleTapCandidateForInterveningInput];
            CGEventRef cgEvent = event.CGEvent;
            BOOL ownEvent = cgEvent &&
                CGEventGetIntegerValueField(cgEvent, kCGEventSourceUserData) == SPSyntheticEventMarker;
            if (!ownEvent && ![self isCarbonCapturedKeyCode:keyCode]) {
                [self cancelTriggerForCompanionInput];
            }
        }
        if ([self consumeSuppressedKeyForKeyCode:keyCode isKeyUp:(event.type == NSEventTypeKeyUp)]) {
            return YES;
        }
        if ([event isARepeat]) return NO;
        NSUInteger flags = event.modifierFlags;

        if (event.type == NSEventTypeKeyDown && [self handleNumberKeyWithKeyCode:keyCode]) {
            return YES;
        }

        if (event.type == NSEventTypeKeyDown && [self handleAbortKeyWithKeyCode:keyCode]) {
            return YES;
        }

        // Some macOS versions send modifier keys as keyDown/keyUp events. Keep
        // a direct keyDown/keyUp fallback for modifier-only triggers like Fn.
        BOOL shouldHandleTriggerKeyEvent = NO;
        if ([self isTargetKeyCode:keyCode]) {
            if ([self isModifierOnlyMatchKind:self.targetMatchKind]) {
                shouldHandleTriggerKeyEvent = YES;
            } else if ([self keyModifiers:flags matchRequiredModifiers:self.targetModifierFlag]) {
                shouldHandleTriggerKeyEvent = YES;
            }
        }

        if (shouldHandleTriggerKeyEvent) {
            BOOL isDown;
            if ([self isModifierOnlyMatchKind:self.targetMatchKind]) {
                isDown = (flags & self.targetModifierFlag) != 0;
            } else {
                isDown = (event.type == NSEventTypeKeyDown);
            }
            NSLog(@"[VelikiyMoguchiy] NSEvent Key%@: keyCode=%ld", isDown ? @"Down" : @"Up", (long)keyCode);
            if (isDown != self.triggerDown) {
                self.triggerDown = isDown;
                if (isDown) {
                    [self handleTriggerDown];
                } else if ([self isModifierOnlyMatchKind:self.targetMatchKind]) {
                    [self scheduleModifierRelease];
                } else {
                    [self handleTriggerUp];
                }
            }
        }
    }
    return NO;
}

/// Called by the tap thread. Returns YES when the event is this monitor's
/// button and the tap can swallow it, so a side button used as push-to-talk does
/// not also navigate back in the browser.
- (BOOL)handleMouseButtonEvent:(CGEventRef)event type:(CGEventType)type {
    int64_t button = CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber);
    if (!SPHotkeyMouseButtonMatches(button, self.targetKeyCode)) return NO;
    BOOL isDown = (type == kCGEventOtherMouseDown);
    // Edges are decided against triggerDown serially on the main thread, as for
    // keys (see hotkeyEventCallback).
    SPPerformOnMainRunLoop(^{
        if (isDown == self.triggerDown) return;
        self.triggerDown = isDown;
        if (isDown) {
            [self handleTriggerDown];
        } else {
            [self handleTriggerUp];
        }
    });
    return self.canConsumeGlobalKeyEvents;
}

- (void)handleMouseNSEvent:(NSEvent *)event {
    if (!self.running || self.suspended) return;
    CFMachPortRef tap = self.eventTap;
    if (tap && CGEventTapIsEnabled(tap)) return;
    if (!SPHotkeyMouseButtonMatches(event.buttonNumber, self.targetKeyCode)) return;
    BOOL isDown = (event.type == NSEventTypeOtherMouseDown);
    if (isDown == self.triggerDown) return;
    self.triggerDown = isDown;
    if (isDown) {
        [self handleTriggerDown];
    } else {
        [self handleTriggerUp];
    }
}

- (void)stop {
    // Set running=NO first so that any in-flight callbacks or dispatched
    // blocks see the flag before we tear down the monitors.
    self.running = NO;

    if (self.globalMonitorRef) {
        [NSEvent removeMonitor:self.globalMonitorRef];
        self.globalMonitorRef = nil;
    }
    if (self.localMonitorRef) {
        [NSEvent removeMonitor:self.localMonitorRef];
        self.localMonitorRef = nil;
    }
    [self unregisterCarbonHotKeys];
    [self stopTapThread];

    BOOL hadPendingTrigger = [self hasUnconfirmedPreCapture];
    [self cancelHoldTimer];
    [self cancelDoubleTapTimer];
    [self cancelPendingModifierRelease];
    self.state = SPHotkeyStateIdle;
    self.canConsumeGlobalKeyEvents = NO;
    @synchronized (self) {
        [self.suppressedKeyCodes removeAllObjects];
        [self.suppressedHotkeyKeyCodes removeAllObjects];
    }
    if (hadPendingTrigger) {
        [self.delegate hotkeyMonitorDidCancelTrigger];
    }
    NSLog(@"[VelikiyMoguchiy] Hotkey monitor stopped");
}

- (void)handleFlagsChangedEvent:(CGEventRef)event {
    CGEventFlags flags = CGEventGetFlags(event);
    NSInteger keyCode = (NSInteger)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);

    // Log every flags-changed event for debugging
    NSLog(@"[VelikiyMoguchiy] FlagsChanged: keyCode=%ld flags=0x%llx", (long)keyCode, (unsigned long long)flags);

    // Target key detection:
    // 1. Check if keyCode matches the configured trigger key
    // 2. Check modifier flag bit for key state
    BOOL triggerNow;
    if ([self isModifierOnlyMatchKind:self.targetMatchKind]) {
        triggerNow = (flags & self.targetModifierFlag) != 0;
        BOOL isReleaseFallback = self.triggerDown && !triggerNow;
        if (![self isTargetKeyCode:keyCode] && !isReleaseFallback) {
            if (self.triggerDown && triggerNow) {
                SPPerformOnMainRunLoop(^{
                    [self cancelDoubleTapCandidateForInterveningInput];
                });
            }
            return;
        }
    } else {
        return;
    }

    // Dedup and mutate triggerDown ON THE MAIN THREAD (see the keyDown path
    // in hotkeyEventCallback for why): the NSEvent monitor delivers the same
    // physical event on the main thread, and deciding edges against a
    // triggerDown that the tap thread already flipped lets a fast tap be
    // processed twice — starting a session and instantly ending it.
    if (triggerNow) {
        SPPerformOnMainRunLoop(^{
            if (self.triggerDown) return;
            self.triggerDown = YES;
            [self handleTriggerDown];
        });
    } else {
        SPPerformOnMainRunLoop(^{
            if (!self.triggerDown) return;
            self.triggerDown = NO;
            [self scheduleModifierRelease];
        });
    }
}

- (void)cancelPendingModifierRelease {
    if (self.pendingModifierReleaseBlock) {
        dispatch_block_cancel(self.pendingModifierReleaseBlock);
        self.pendingModifierReleaseBlock = nil;
    }
}

- (void)scheduleModifierRelease {
    [self cancelPendingModifierRelease];

    // An unconfirmed gesture must resolve key-up immediately. In particular,
    // delaying double-tap releases by the modifier debounce window would make
    // it impossible for the second press to arrive within the gesture window.
    if (self.state == SPHotkeyStatePending ||
        self.state == SPHotkeyStateDoubleTapFirstDown ||
        self.state == SPHotkeyStateDoubleTapSecondDown ||
        self.state == SPHotkeyStateDoubleTapStopPending) {
        self.triggerDown = NO;
        [self handleTriggerUp];
        return;
    }

    // The debounce timer fires on a global queue and hops back to the main
    // thread in common modes. dispatch_after onto the main queue would not
    // fire while a modal loop runs (Sparkle update prompt, NSAlert) — the
    // release would freeze there while trigger-down events keep arriving,
    // wedging the state machine.
    __block dispatch_block_t scheduled = nil;
    scheduled = dispatch_block_create(0, ^{
        SPPerformOnMainRunLoop(^{
            // Superseded or cancelled while we hopped threads.
            if (self.pendingModifierReleaseBlock != scheduled) return;
            self.pendingModifierReleaseBlock = nil;
            if (([self currentModifierFlags] & self.targetModifierFlag) != 0) {
                self.triggerDown = YES;
                return;
            }
            self.triggerDown = NO;
            [self handleTriggerUp];
        });
    });
    self.pendingModifierReleaseBlock = scheduled;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SPModifierOnlyReleaseDebounceSeconds * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0),
                   scheduled);
}

- (void)handleTriggerDown {
    if (!self.running) return;
    [self cancelPendingModifierRelease];
    NSLog(@"[VelikiyMoguchiy] Trigger DOWN (state=%ld)", (long)self.state);
    switch (self.state) {
        case SPHotkeyStateIdle:
            [self beginGesturePressCount];
            if (self.triggerMode == SPHotkeyTriggerModeDoubleTap) {
                self.state = SPHotkeyStateDoubleTapFirstDown;
                [self startDoubleTapTimer];
            } else {
                self.state = SPHotkeyStatePending;
                [self startHoldTimer];
                [self.delegate hotkeyMonitorDidBeginTrigger];
            }
            break;

        case SPHotkeyStateDoubleTapWaiting:
            [self cancelDoubleTapTimer];
            self.state = SPHotkeyStateDoubleTapSecondDown;
            [self.delegate hotkeyMonitorDidBeginTrigger];
            break;

        case SPHotkeyStateRecordingToggle:
            if (self.triggerMode == SPHotkeyTriggerModeDoubleTap) {
                self.state = SPHotkeyStateDoubleTapStopPending;
            } else {
                self.state = SPHotkeyStateConsumeKeyUp;
                [self.delegate hotkeyMonitorDidDetectTapEnd];
            }
            break;

        default:
            break;
    }
}

- (void)handleTriggerUp {
    if (!self.running) return;
    NSLog(@"[VelikiyMoguchiy] Trigger UP (state=%ld)", (long)self.state);
    BOOL unconfirmed = self.state == SPHotkeyStatePending ||
                       self.state == SPHotkeyStateDoubleTapFirstDown ||
                       self.state == SPHotkeyStateDoubleTapSecondDown;
    if (unconfirmed && [self isModifierOnlyMatchKind:self.targetMatchKind] &&
        [self gestureHadUnobservedPress]) {
        NSLog(@"[VelikiyMoguchiy] Trigger was part of a chord the monitor did not see — ignoring it");
        BOOL began = self.state != SPHotkeyStateDoubleTapFirstDown;
        [self cancelHoldTimer];
        [self cancelDoubleTapTimer];
        self.state = SPHotkeyStateIdle;
        if (began) {
            [self.delegate hotkeyMonitorDidCancelTrigger];
        }
        return;
    }
    switch (self.state) {
        case SPHotkeyStatePending:
            [self cancelHoldTimer];
            if (self.triggerMode == SPHotkeyTriggerModeToggle ||
                self.triggerMode == SPHotkeyTriggerModeAuto) {
                // Toggle and auto modes: short press starts recording
                self.state = SPHotkeyStateRecordingToggle;
                [self.delegate hotkeyMonitorDidDetectTapStart];
            } else {
                // Hold mode: short press is ignored
                self.state = SPHotkeyStateIdle;
                [self.delegate hotkeyMonitorDidCancelTrigger];
                if ([self.delegate respondsToSelector:@selector(hotkeyMonitorDidIgnoreShortPress)]) {
                    [self.delegate hotkeyMonitorDidIgnoreShortPress];
                }
            }
            break;

        case SPHotkeyStateDoubleTapFirstDown:
            self.state = SPHotkeyStateDoubleTapWaiting;
            break;

        case SPHotkeyStateDoubleTapSecondDown:
            self.state = SPHotkeyStateRecordingToggle;
            [self.delegate hotkeyMonitorDidDetectTapStart];
            break;

        case SPHotkeyStateRecordingHold:
            self.state = SPHotkeyStateIdle;
            [self.delegate hotkeyMonitorDidDetectHoldEnd];
            break;

        case SPHotkeyStateDoubleTapStopPending:
            self.state = SPHotkeyStateIdle;
            [self.delegate hotkeyMonitorDidDetectTapEnd];
            break;

        case SPHotkeyStateConsumeKeyUp:
            self.state = SPHotkeyStateIdle;
            break;

        default:
            break;
    }
}

- (void)startHoldTimer {
    [self cancelHoldTimer];
    __weak typeof(self) weakSelf = self;
    // Common modes so hold classification keeps working during modal or
    // menu-tracking run loops (default-mode timers freeze there).
    // Auto mode needs a longer window so a deliberate tap is not read as a hold;
    // 350 ms matches OpenLess' HotkeyMode::Auto threshold.
    double thresholdMs = self.triggerMode == SPHotkeyTriggerModeAuto ? 350.0 : self.holdThresholdMs;
    NSTimer *timer = [NSTimer timerWithTimeInterval:(thresholdMs / 1000.0)
                                            repeats:NO
                                              block:^(NSTimer *t) {
        [weakSelf holdTimerFired];
    }];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    self.holdTimer = timer;
}

- (void)cancelHoldTimer {
    [self.holdTimer invalidate];
    self.holdTimer = nil;
}

- (void)startDoubleTapTimer {
    [self cancelDoubleTapTimer];
    __weak typeof(self) weakSelf = self;
    NSTimer *timer = [NSTimer timerWithTimeInterval:(self.doubleTapThresholdMs / 1000.0)
                                            repeats:NO
                                              block:^(NSTimer *t) {
        [weakSelf doubleTapTimerFired];
    }];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    self.doubleTapTimer = timer;
}

- (void)cancelDoubleTapTimer {
    [self.doubleTapTimer invalidate];
    self.doubleTapTimer = nil;
}

- (void)doubleTapTimerFired {
    self.doubleTapTimer = nil;
    if (self.state == SPHotkeyStateDoubleTapFirstDown ||
        self.state == SPHotkeyStateDoubleTapWaiting) {
        self.state = SPHotkeyStateIdle;
    }
}

- (void)cancelDoubleTapCandidateForInterveningInput {
    if (self.triggerMode != SPHotkeyTriggerModeDoubleTap) return;

    BOOL hadPreCapture = self.state == SPHotkeyStateDoubleTapSecondDown;
    BOOL hadStopCandidate = self.state == SPHotkeyStateDoubleTapStopPending;
    if (self.state != SPHotkeyStateDoubleTapFirstDown &&
        self.state != SPHotkeyStateDoubleTapWaiting &&
        !hadPreCapture &&
        !hadStopCandidate) {
        return;
    }

    [self cancelDoubleTapTimer];
    if (hadStopCandidate) {
        self.state = SPHotkeyStateRecordingToggle;
        return;
    }

    self.state = SPHotkeyStateIdle;
    if (hadPreCapture) {
        [self.delegate hotkeyMonitorDidCancelTrigger];
    }
}

/// A function-layer system key (brightness, volume, media) arrived.
- (void)handleCompanionInput {
    [self cancelDoubleTapCandidateForInterveningInput];
    [self cancelTriggerForCompanionInput];
}

/// Fn+brightness, Cmd-C and similar: while a modifier-only trigger is held,
/// another key makes the press a shortcut, not dictation. A pending press
/// (tap/hold not yet classified) is dropped so its release cannot start a
/// session; a hold that already started recording is discarded. Main thread.
- (void)cancelTriggerForCompanionInput {
    if (!self.running || self.suspended) return;
    if (![self isModifierOnlyMatchKind:self.targetMatchKind]) return;
    if (!self.triggerDown) return;

    switch (self.state) {
        case SPHotkeyStatePending: {
            NSLog(@"[VelikiyMoguchiy] Trigger combined with another key — cancelling pending trigger");
            [self cancelHoldTimer];
            [self cancelPendingModifierRelease];
            // triggerDown drops now so the physical release is ignored instead
            // of being debounced into a stale handleTriggerUp.
            self.triggerDown = NO;
            self.state = SPHotkeyStateIdle;
            [self.delegate hotkeyMonitorDidCancelTrigger];
            break;
        }
        case SPHotkeyStateRecordingHold: {
            NSLog(@"[VelikiyMoguchiy] Trigger combined with another key — discarding hold recording");
            [self cancelHoldTimer];
            [self cancelPendingModifierRelease];
            self.triggerDown = NO;
            self.state = SPHotkeyStateIdle;
            if ([self.delegate respondsToSelector:@selector(hotkeyMonitorDidCancelHoldForCompanionInput)]) {
                [self.delegate hotkeyMonitorDidCancelHoldForCompanionInput];
            } else {
                [self.delegate hotkeyMonitorDidCancelTrigger];
            }
            break;
        }
        default:
            break;
    }
}

- (void)noteObservedPress {
    atomic_fetch_add_explicit(&_observedPressCount, 1, memory_order_relaxed);
}

- (void)beginGesturePressCount {
    self.gestureSystemPressBase = self.systemPressCounter();
    self.gestureObservedPressBase = atomic_load_explicit(&_observedPressCount, memory_order_relaxed);
}

/// A key or click reached macOS during this gesture but never reached the
/// monitor, so the precise companion-key path could not cancel it.
- (BOOL)gestureHadUnobservedPress {
    uint64_t system = self.systemPressCounter() - self.gestureSystemPressBase;
    uint64_t observed = atomic_load_explicit(&_observedPressCount, memory_order_relaxed) -
                        self.gestureObservedPressBase;
    return system > observed;
}

- (void)holdTimerFired {
    if (self.state != SPHotkeyStatePending) return;
    if (self.triggerMode == SPHotkeyTriggerModeToggle) return;

    self.state = SPHotkeyStateRecordingHold;
    [self.delegate hotkeyMonitorDidDetectHoldStart];
}

- (void)resetToIdle {
    BOOL hadPendingTrigger = [self hasUnconfirmedPreCapture];
    [self cancelHoldTimer];
    [self cancelDoubleTapTimer];
    [self cancelPendingModifierRelease];
    self.triggerDown = NO;
    self.state = SPHotkeyStateIdle;
    @synchronized (self) {
        [self.suppressedKeyCodes removeAllObjects];
        [self.suppressedHotkeyKeyCodes removeAllObjects];
    }
    if (hadPendingTrigger) {
        [self.delegate hotkeyMonitorDidCancelTrigger];
    }
}

- (void)dealloc {
    [self unregisterCarbonHotKeys];
    if (_carbonHotKeyHandler) {
        RemoveEventHandler(_carbonHotKeyHandler);
        _carbonHotKeyHandler = NULL;
    }
}

- (void)markExternalToggleRecording {
    [self cancelHoldTimer];
    [self cancelDoubleTapTimer];
    [self cancelPendingModifierRelease];
    self.triggerDown = NO;
    self.state = SPHotkeyStateRecordingToggle;
}

@end
