#import <Foundation/Foundation.h>

/// Where a paste at the focused element would land.
typedef NS_ENUM(NSInteger, SPPasteTarget) {
    /// A text field, or an element the app cannot judge (many apps expose
    /// little through Accessibility): paste as always.
    SPPasteTargetPaste,
    /// A password field: never paste dictated text there.
    SPPasteTargetSecure,
    /// Nothing that takes text has focus (the desktop, a file list): the
    /// text would vanish.
    SPPasteTargetNone,
};

/// The decision from what Accessibility reports about the focused element.
/// `role` and `subrole` are nil when there is no focused element.
SPPasteTarget SPPasteTargetForFocus(NSString *role, NSString *subrole, BOOL valueSettable, NSString *bundleId);

@interface SPAccessibilityManager : NSObject

/// SPPasteTargetForFocus for the element focused right now.
- (SPPasteTarget)pasteTargetForFocusedElement;

/// Check if the currently focused element is a text input field.
- (BOOL)isFocusedElementTextInput;

/// Check if the currently focused element is a secure (password) field.
- (BOOL)isFocusedElementSecure;

/// Get the bundle ID of the frontmost application.
- (NSString *)frontmostAppBundleId;

/// Get the PID of the frontmost application.
- (pid_t)frontmostAppPid;

@end
