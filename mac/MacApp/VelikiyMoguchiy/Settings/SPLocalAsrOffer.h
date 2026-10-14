#import <Foundation/Foundation.h>

@class SPRustBridge;

NS_ASSUME_NONNULL_BEGIN

/// Offers on-device recognition when the chosen cloud provider has no key:
/// explains, downloads the model with progress, then switches asr.provider.
/// Nothing changes until the user agrees, and a key added meanwhile wins.
@interface SPLocalAsrOffer : NSObject

- (instancetype)initWithRustBridge:(SPRustBridge *)rustBridge;

/// Called after the config was changed, so the app reloads it.
@property (nonatomic, copy, nullable) void (^configChangedHandler)(void);
/// «Указать ключ…»: opens the settings.
@property (nonatomic, copy, nullable) void (^openSettingsHandler)(void);

/// Shows the offer when SPLocalAsrPolicy says so, at most once per launch.
- (void)offerIfNeeded;

@end

NS_ASSUME_NONNULL_END
