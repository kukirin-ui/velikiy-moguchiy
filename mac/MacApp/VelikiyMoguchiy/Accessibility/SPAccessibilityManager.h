#import <Foundation/Foundation.h>

@interface SPAccessibilityManager : NSObject

/// Check if the currently focused element is a text input field.
- (BOOL)isFocusedElementTextInput;

/// Check if the currently focused element is a secure (password) field.
- (BOOL)isFocusedElementSecure;

/// Get the bundle ID of the frontmost application.
- (NSString *)frontmostAppBundleId;

/// Get the PID of the frontmost application.
- (pid_t)frontmostAppPid;

@end
