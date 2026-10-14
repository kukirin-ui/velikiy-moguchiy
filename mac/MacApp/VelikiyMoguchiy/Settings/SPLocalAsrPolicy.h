#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// When to offer on-device recognition instead of a cloud provider that has
/// no key. Pure, for unit tests: the caller passes the `asr` section of the
/// config as JSON.
@interface SPLocalAsrPolicy : NSObject

/// Providers that run on the Mac and need no key.
+ (BOOL)isLocalProvider:(nullable NSString *)provider;

/// Whether the cloud provider has what it needs to connect: a DashScope key
/// (`api_key` or `api_keys`) for qwen, an `api_key` or `app_key` with
/// `access_key` for doubao, an `api_key` for glm and mimo.
+ (BOOL)hasCredentialsForProvider:(nullable NSString *)provider asrConfig:(nullable NSDictionary *)asrConfig;

/// The local model to offer, as {provider, model}: Qwen3-ASR on MLX when this
/// build has MLX, else the Russian sherpa-onnx model. Nil when the build has
/// neither.
+ (nullable NSDictionary<NSString *, NSString *> *)localChoiceForSupportedProviders:(nullable NSArray<NSString *> *)providers;

/// Offer only for a cloud provider without credentials, and only when a local
/// model can be offered. A configured key always wins: the user's choice is
/// never replaced silently.
+ (BOOL)shouldOfferLocalAsrWithAsrConfig:(nullable NSDictionary *)asrConfig
                 supportedLocalProviders:(nullable NSArray<NSString *> *)providers;

@end

NS_ASSUME_NONNULL_END
