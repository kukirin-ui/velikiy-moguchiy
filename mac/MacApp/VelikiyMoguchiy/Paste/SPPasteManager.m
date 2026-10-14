#import "SPPasteManager.h"
#import "SPHotkeyMonitor.h"
#import <Carbon/Carbon.h>
#import <ApplicationServices/ApplicationServices.h>

@interface SPPasteManager ()
@property (nonatomic, assign) BOOL cancelled;
@end

@implementation SPPasteManager

// Create an event source with a *private* modifier state so that synthetic
// Cmd+V / Cmd+Z events do not merge with whatever modifier keys the user is
// physically holding at the moment of injection. Using
// kCGEventSourceStateHIDSystemState (the previous behavior) caused injected
// events to pick up real hardware flags — e.g. if the user was still holding
// Control (the LLM-invert modifier) when a paste fired, the posted Cmd+V
// became Control+Cmd+V, and similar bleed turned Cmd+Z into Control+Cmd+Z or
// dropped the Cmd entirely, resulting in random letters typed into the
// target app.
static CGEventSourceRef createPrivateEventSource(void) {
    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStatePrivate);
    if (source) {
        // Lets the hotkey monitor tell our own Cmd+V from the user's keys.
        CGEventSourceSetUserData(source, SPSyntheticEventMarker);
        CGEventSourceSetLocalEventsFilterDuringSuppressionState(
            source,
            kCGEventFilterMaskPermitLocalMouseEvents | kCGEventFilterMaskPermitSystemDefinedEvents,
            kCGEventSuppressionStateSuppressionInterval);
    }
    return source;
}

// Post a down/up pair for `keyCode` with `flags` from a private source at
// the session level. Returns NO (posting nothing) if any allocation fails.
static BOOL postKeyPair(CGKeyCode keyCode, CGEventFlags flags) {
    CGEventSourceRef source = createPrivateEventSource();
    if (!source) {
        NSLog(@"[VelikiyMoguchiy] Failed to create event source for key injection");
        return NO;
    }

    CGEventRef down = CGEventCreateKeyboardEvent(source, keyCode, true);
    CGEventRef up = CGEventCreateKeyboardEvent(source, keyCode, false);
    if (!down || !up) {
        NSLog(@"[VelikiyMoguchiy] Failed to create keyboard events for key injection");
        if (down) CFRelease(down);
        if (up) CFRelease(up);
        CFRelease(source);
        return NO;
    }

    // Set the modifier flags on the synthetic events. Because `source` has a
    // private modifier state, these flags will not merge with real hardware
    // modifiers.
    CGEventSetFlags(down, flags);
    CGEventSetFlags(up, flags);

    // Post at the session level — NOT kCGHIDEventTap. HID-level posting
    // re-merges the physical keyboard's current modifier state, which means
    // a private-source event with CMD set can still arrive at a target app
    // as CMD+CONTROL (or with CMD dropped entirely) if the user is holding
    // a modifier when the paste fires. Session-level posting honors the
    // private source's clean flag state.
    CGEventPost(kCGSessionEventTap, down);
    CGEventPost(kCGSessionEventTap, up);

    CFRelease(down);
    CFRelease(up);
    CFRelease(source);
    return YES;
}

- (void)simulatePasteWithGuard:(SPPasteInjectionGuard)guard
                    completion:(void (^)(BOOL posted))completion {
    // NOTE: `cancelled` is sticky. Once -cancel is called (at quit) it stays
    // YES for the lifetime of this manager, so any subsequent simulate* calls
    // become no-ops. This is intentional: during quit, in-flight Rust
    // callbacks can still land on the main queue after `quitting=YES` is set
    // on the app delegate, and we must never fire a synthetic paste after
    // cancel.
    if (self.cancelled) return;
    // Small delay after clipboard write to ensure it's ready
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(50 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        if (self.cancelled) return;
        BOOL posted = [self performPasteWithGuard:guard];

        // Delay after paste to let the target app process it
        if (completion) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(100 * NSEC_PER_MSEC)),
                           dispatch_get_main_queue(), ^{
                if (self.cancelled) return;
                completion(posted);
            });
        }
    });
}

// Every injection point funnels through here so the "is this still the right
// target?" question is answered at the moment of injection rather than when
// the paste was scheduled (the delays in between are exactly when focus can
// move, or a whole new dictation session can begin).
- (BOOL)injectionAllowedForGuard:(SPPasteInjectionGuard)guard {
    if (self.cancelled) return NO;
    // Fails closed: an injection with no guard has no session identity and
    // no destination to check, so it must not be posted.
    if (!guard) {
        NSLog(@"[VelikiyMoguchiy] Injection refused: no session guard supplied");
        return NO;
    }
    return guard();
}

- (BOOL)performPasteWithGuard:(SPPasteInjectionGuard)guard {
    if (![self injectionAllowedForGuard:guard]) {
        NSLog(@"[VelikiyMoguchiy] Paste injection vetoed (target changed, superseded, or cancelled)");
        return NO;
    }

    BOOL posted = postKeyPair((CGKeyCode)kVK_ANSI_V, kCGEventFlagMaskCommand);
    if (posted) {
        NSLog(@"[VelikiyMoguchiy] Cmd+V simulated");
    }
    return posted;
}

- (void)simulateUndoThenPasteWithGuard:(SPPasteInjectionGuard)guard
                            completion:(void (^)(BOOL posted))completion {
    if (self.cancelled) return;
    // First simulate Cmd+Z to undo previous paste
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(50 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        if (self.cancelled) return;
        [self performUndoWithGuard:guard];

        // Wait for undo to take effect, then paste new content
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(150 * NSEC_PER_MSEC)),
                       dispatch_get_main_queue(), ^{
            if (self.cancelled) return;
            BOOL posted = [self performPasteWithGuard:guard];

            if (completion) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(100 * NSEC_PER_MSEC)),
                               dispatch_get_main_queue(), ^{
                    if (self.cancelled) return;
                    completion(posted);
                });
            }
        });
    });
}

- (BOOL)performUndoWithGuard:(SPPasteInjectionGuard)guard {
    if (![self injectionAllowedForGuard:guard]) return NO;

    BOOL posted = postKeyPair((CGKeyCode)kVK_ANSI_Z, kCGEventFlagMaskCommand);
    if (posted) {
        NSLog(@"[VelikiyMoguchiy] Cmd+Z simulated");
    }
    return posted;
}

- (BOOL)simulateReturnKeyWithGuard:(SPPasteInjectionGuard)guard {
    // Re-checked here rather than trusting the paste's earlier check: Return
    // is posted ~100ms after the paste, and submitting into whatever app is
    // now focused is the worst failure mode this class has (in a terminal it
    // executes a command).
    if (![self injectionAllowedForGuard:guard]) {
        NSLog(@"[VelikiyMoguchiy] Return injection vetoed (target changed or cancelled)");
        return NO;
    }

    // A bare Return: zero flags so the private source cannot carry anything
    // over, and so a user still holding the trigger modifier (e.g. Fn)
    // cannot turn this into a modified keypress.
    if (!postKeyPair((CGKeyCode)kVK_Return, 0)) return NO;
    NSLog(@"[VelikiyMoguchiy] Return simulated");
    return YES;
}

- (BOOL)simulateBackspaces:(NSUInteger)count withGuard:(SPPasteInjectionGuard)guard {
    if (count == 0) return NO;
    if (![self injectionAllowedForGuard:guard]) {
        NSLog(@"[VelikiyMoguchiy] Backspace injection vetoed (target changed or cancelled)");
        return NO;
    }
    // One guard check covers the whole burst: it is posted synchronously.
    for (NSUInteger i = 0; i < count; i++) {
        if (!postKeyPair((CGKeyCode)kVK_Delete, 0)) return NO;
    }
    NSLog(@"[VelikiyMoguchiy] %lu Backspace presses simulated", (unsigned long)count);
    return YES;
}

- (void)cancel {
    self.cancelled = YES;
}

@end
