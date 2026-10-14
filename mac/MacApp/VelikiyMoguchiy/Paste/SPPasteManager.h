#import <Foundation/Foundation.h>

/// Evaluated on the main thread immediately before a synthetic event is
/// injected. Return NO to abort the injection.
///
/// Every injection carries its OWN guard, captured when the paste was
/// scheduled: injection happens after a delay, and by then a newer dictation
/// session may have started with a different destination. A guard that read
/// shared state would authorize an old session's text against the new
/// session's target.
typedef BOOL (^SPPasteInjectionGuard)(void);

@interface SPPasteManager : NSObject

/// Simulate Cmd+V paste via CGEvent injection, if `guard` still allows it at
/// the moment of injection.
/// The completion block is called after a short delay to allow the paste to
/// take effect. `posted` is NO when the guard vetoed the injection or the
/// synthetic events could not be created, so nothing was injected. NOTE:
/// `posted` means "events were injected", not "the target accepted them" —
/// CGEventPost reports no delivery status, and a target app may ignore Cmd+V.
- (void)simulatePasteWithGuard:(SPPasteInjectionGuard)guard
                    completion:(void (^)(BOOL posted))completion;

/// Simulate Cmd+Z undo, then Cmd+V paste. Used to replace previously pasted
/// text. `posted` reflects the paste step.
- (void)simulateUndoThenPasteWithGuard:(SPPasteInjectionGuard)guard
                            completion:(void (^)(BOOL posted))completion;

/// Simulate a bare Return keypress via CGEvent injection. Used by the
/// "auto Return after paste" option to submit the pasted text (e.g. send a
/// chat message) without the user touching the keyboard. `guard` is
/// re-evaluated here — Return fires later than the paste it follows, and
/// submitting into the wrong app is this class's worst failure mode.
/// Returns whether the key was injected.
- (BOOL)simulateReturnKeyWithGuard:(SPPasteInjectionGuard)guard;

/// Press Backspace `count` times in the focused app, if `guard` allows it at the
/// moment of injection. Used to take back inserted text where Accessibility
/// cannot replace a range. Returns whether the keys were injected.
- (BOOL)simulateBackspaces:(NSUInteger)count withGuard:(SPPasteInjectionGuard)guard;

/// Cancel any scheduled paste/undo blocks. Called on quit so that pending
/// CGEventPost injections cannot leak into the user's target app after the
/// hotkey monitor and event tap have been torn down.
- (void)cancel;

@end
