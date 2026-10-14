#import <Foundation/Foundation.h>

typedef void (^SPPermissionCheckCompletion)(BOOL micGranted, BOOL accessibilityGranted, BOOL inputMonitoringGranted);

/// Permission identifiers for alert throttling.
typedef NS_ENUM(NSInteger, SPPermissionType) {
    SPPermissionTypeMicrophone = 0,
    SPPermissionTypeAccessibility,
    SPPermissionTypeInputMonitoring,
    SPPermissionTypeSpeechRecognition,
};

@interface SPPermissionManager : NSObject

- (void)checkAllPermissionsWithCompletion:(SPPermissionCheckCompletion)completion;
/// Same, without the system's Accessibility prompt (it cannot help when the
/// grant was lost to an update, see lostPermissionTypes).
- (void)checkAllPermissionsPromptingAccessibility:(BOOL)prompt completion:(SPPermissionCheckCompletion)completion;
- (BOOL)isMicrophoneGranted;
/// The user has not answered the microphone prompt yet.
- (BOOL)isMicrophoneUndetermined;
/// Asks for the microphone (the system prompt when undetermined); completion on any queue.
- (void)requestMicrophonePermissionWithCompletion:(void (^)(BOOL granted))completion;
- (BOOL)isCameraGranted;
- (BOOL)isAccessibilityGranted;
- (void)requestAccessibilityPermission;
- (BOOL)isInputMonitoringGranted;

/// Check whether speech recognition permission has been granted.
- (BOOL)isSpeechRecognitionGranted;

/// Request speech recognition permission from the user.
- (void)requestSpeechRecognitionPermissionWithCompletion:(void (^)(BOOL granted))completion;

/// Request notification permission from the user.
- (void)requestNotificationPermission;

/// Check whether notification permission has been granted.
/// @param completion Called on main queue with the current authorization status.
- (void)checkNotificationPermissionWithCompletion:(void (^)(BOOL granted))completion;

/// Show a permission alert for the given permission type. Respects
/// per-permission "don't remind again" preference stored in NSUserDefaults.
/// Returns YES if the alert was shown, NO if suppressed.
/// @param type The permission to alert about.
/// @param settingsURL If non-nil, the primary button opens this URL.
- (BOOL)showPermissionAlertForType:(SPPermissionType)type
                       settingsURL:(nullable NSURL *)settingsURL;

/// Reset the "don't remind again" flag for a specific permission.
- (void)resetDontRemindForType:(SPPermissionType)type;

/// System Settings → Privacy at the pane of `type`.
+ (NSURL *)settingsURLForType:(SPPermissionType)type;

/// Remembers which of microphone, Accessibility and Input Monitoring are
/// granted now, so a later launch can tell a lost grant from one never given.
- (void)rememberGrantedPermissions;

/// Permissions this Mac granted to the app before and does not grant now:
/// after an update macOS can keep the checkmark for the previous build while
/// refusing this one. A microphone the system will simply ask for again is not lost.
- (NSArray<NSNumber *> *)lostPermissionTypes;

/// Explains lost grants and offers the System Settings pane of the first one.
- (void)showLostAccessAlertForTypes:(NSArray<NSNumber *> *)types;

@end
