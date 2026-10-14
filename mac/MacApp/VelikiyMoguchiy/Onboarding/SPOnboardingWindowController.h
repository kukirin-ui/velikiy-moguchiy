#import <Cocoa/Cocoa.h>

@class SPPermissionManager;
@class SPLocalAsrOffer;

NS_ASSUME_NONNULL_BEGIN

/// «Начало работы»: the permissions with live checkmarks, the recognition key
/// (or local recognition), the dictation key, and a field to try a dictation in.
@interface SPOnboardingWindowController : NSWindowController

- (instancetype)initWithPermissionManager:(SPPermissionManager *)permissionManager
                            localAsrOffer:(SPLocalAsrOffer *)localAsrOffer;

/// Opens a Settings pane (asr, hotkey, …).
@property (nonatomic, copy, nullable) void (^openSettingsPane)(NSString *pane);

/// A first launch: the window was never finished and recognition has neither a
/// key nor a local model.
+ (BOOL)shouldShowAtLaunch;

- (void)present;

@end

NS_ASSUME_NONNULL_END
