#import "SPAccessibilityManager.h"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>

@implementation SPAccessibilityManager

- (NSString *)frontmostAppBundleId {
    NSRunningApplication *app = [[NSWorkspace sharedWorkspace] frontmostApplication];
    return app.bundleIdentifier;
}

- (pid_t)frontmostAppPid {
    NSRunningApplication *app = [[NSWorkspace sharedWorkspace] frontmostApplication];
    return app.processIdentifier;
}

- (BOOL)isFocusedElementTextInput {
    AXUIElementRef systemWide = AXUIElementCreateSystemWide();
    AXUIElementRef focusedElement = NULL;

    AXError error = AXUIElementCopyAttributeValue(systemWide,
                                                   kAXFocusedUIElementAttribute,
                                                   (CFTypeRef *)&focusedElement);
    CFRelease(systemWide);

    if (error != kAXErrorSuccess || focusedElement == NULL) {
        return NO;
    }

    CFStringRef role = NULL;
    AXUIElementCopyAttributeValue(focusedElement, kAXRoleAttribute, (CFTypeRef *)&role);
    CFRelease(focusedElement);

    if (role == NULL) {
        return NO;
    }

    BOOL isTextInput = (CFStringCompare(role, CFSTR("AXTextField"), 0) == kCFCompareEqualTo ||
                        CFStringCompare(role, CFSTR("AXTextArea"), 0) == kCFCompareEqualTo ||
                        CFStringCompare(role, CFSTR("AXComboBox"), 0) == kCFCompareEqualTo ||
                        CFStringCompare(role, CFSTR("AXSearchField"), 0) == kCFCompareEqualTo ||
                        CFStringCompare(role, CFSTR("AXWebArea"), 0) == kCFCompareEqualTo);
    CFRelease(role);
    return isTextInput;
}

- (BOOL)isFocusedElementSecure {
    AXUIElementRef systemWide = AXUIElementCreateSystemWide();
    AXUIElementRef focusedElement = NULL;

    AXError error = AXUIElementCopyAttributeValue(systemWide,
                                                   kAXFocusedUIElementAttribute,
                                                   (CFTypeRef *)&focusedElement);
    CFRelease(systemWide);

    if (error != kAXErrorSuccess || focusedElement == NULL) {
        return NO;
    }

    CFStringRef role = NULL;
    AXUIElementCopyAttributeValue(focusedElement, kAXRoleAttribute, (CFTypeRef *)&role);
    CFRelease(focusedElement);

    if (role == NULL) {
        return NO;
    }

    BOOL isSecure = (CFStringCompare(role, CFSTR("AXSecureTextField"), 0) == kCFCompareEqualTo);
    CFRelease(role);
    return isSecure;
}

@end
