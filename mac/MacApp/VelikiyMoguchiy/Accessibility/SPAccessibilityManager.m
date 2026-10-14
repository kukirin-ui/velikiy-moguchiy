#import "SPAccessibilityManager.h"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>

SPPasteTarget SPPasteTargetForFocus(NSString *role, NSString *subrole, BOOL valueSettable, NSString *bundleId) {
    if ([role isEqualToString:@"AXSecureTextField"] || [subrole isEqualToString:@"AXSecureTextField"]) {
        return SPPasteTargetSecure;
    }
    if (role.length == 0) {
        // No focused element: on the desktop that is certain, elsewhere it is
        // usually an app that does not report its focus.
        return [bundleId isEqualToString:@"com.apple.finder"] ? SPPasteTargetNone : SPPasteTargetPaste;
    }
    // Roles that never take typed text. Tables, rows and cells are left out:
    // a spreadsheet cell does.
    static NSSet<NSString *> *notText;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        notText = [NSSet setWithArray:@[ @"AXList", @"AXOutline", @"AXBrowser", @"AXImage", @"AXButton",
                                         @"AXCheckBox", @"AXRadioButton", @"AXPopUpButton", @"AXMenuButton",
                                         @"AXSlider", @"AXMenu", @"AXMenuBar", @"AXMenuItem", @"AXDockItem" ]];
    });
    if ([notText containsObject:role] && !valueSettable) return SPPasteTargetNone;
    return SPPasteTargetPaste;
}

@implementation SPAccessibilityManager

- (SPPasteTarget)pasteTargetForFocusedElement {
    NSString *bundleId = [self frontmostAppBundleId];
    AXUIElementRef systemWide = AXUIElementCreateSystemWide();
    AXUIElementRef focused = NULL;
    AXError error = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute, (CFTypeRef *)&focused);
    CFRelease(systemWide);
    if (error != kAXErrorSuccess || !focused) {
        return SPPasteTargetForFocus(nil, nil, NO, bundleId);
    }
    CFTypeRef role = NULL;
    CFTypeRef subrole = NULL;
    AXUIElementCopyAttributeValue(focused, kAXRoleAttribute, &role);
    AXUIElementCopyAttributeValue(focused, kAXSubroleAttribute, &subrole);
    Boolean settable = false;
    AXUIElementIsAttributeSettable(focused, kAXValueAttribute, &settable);
    CFRelease(focused);
    NSString *roleString = role && CFGetTypeID(role) == CFStringGetTypeID() ? (__bridge NSString *)role : nil;
    NSString *subroleString =
        subrole && CFGetTypeID(subrole) == CFStringGetTypeID() ? (__bridge NSString *)subrole : nil;
    // An element that answers with no role still has focus: judged as "unknown".
    SPPasteTarget target = SPPasteTargetForFocus(roleString ?: @"AXUnknown", subroleString, settable, bundleId);
    if (role) CFRelease(role);
    if (subrole) CFRelease(subrole);
    return target;
}

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
