#import "SPLocalAsrPolicy.h"

static BOOL hasText(id value) {
    return [value isKindOfClass:[NSString class]] &&
           [(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length > 0;
}

static NSDictionary *section(NSDictionary *asr, NSString *name) {
    id value = asr[name];
    return [value isKindOfClass:[NSDictionary class]] ? value : @{};
}

@implementation SPLocalAsrPolicy

+ (BOOL)isLocalProvider:(NSString *)provider {
    return [@[ @"apple-speech", @"mlx", @"sherpa-onnx", @"wetype" ] containsObject:provider ?: @""];
}

+ (NSString *)providerOf:(NSDictionary *)asrConfig {
    id provider = [asrConfig isKindOfClass:[NSDictionary class]] ? asrConfig[@"provider"] : nil;
    // The core's default provider when the config names none.
    return hasText(provider) ? provider : @"qwen";
}

+ (BOOL)hasCredentialsForProvider:(NSString *)provider asrConfig:(NSDictionary *)asrConfig {
    NSDictionary *asr = [asrConfig isKindOfClass:[NSDictionary class]] ? asrConfig : @{};
    NSDictionary *config = section(asr, provider ?: @"");
    if ([provider isEqualToString:@"qwen"]) {
        if (hasText(config[@"api_key"])) return YES;
        id keys = config[@"api_keys"];
        if ([keys isKindOfClass:[NSArray class]]) {
            for (id key in keys) {
                if (hasText(key)) return YES;
            }
        }
        return NO;
    }
    if ([provider isEqualToString:@"doubao"]) {
        return hasText(config[@"api_key"]) || (hasText(config[@"app_key"]) && hasText(config[@"access_key"]));
    }
    if ([provider isEqualToString:@"glm"] || [provider isEqualToString:@"mimo"]) {
        return hasText(config[@"api_key"]);
    }
    // A provider this policy does not know: never second-guess it.
    return YES;
}

+ (NSDictionary<NSString *, NSString *> *)localChoiceForSupportedProviders:(NSArray<NSString *> *)providers {
    if ([providers containsObject:@"mlx"]) return @{@"provider" : @"mlx", @"model" : @"mlx/Qwen3-ASR-0.6B-4bit"};
    if ([providers containsObject:@"sherpa-onnx"]) {
        return @{@"provider" : @"sherpa-onnx", @"model" : @"sherpa-onnx/ru-vosk-small"};
    }
    return nil;
}

+ (BOOL)shouldOfferLocalAsrWithAsrConfig:(NSDictionary *)asrConfig supportedLocalProviders:(NSArray<NSString *> *)providers {
    NSString *provider = [self providerOf:asrConfig];
    if ([self isLocalProvider:provider]) return NO;
    if ([self hasCredentialsForProvider:provider asrConfig:asrConfig]) return NO;
    return [self localChoiceForSupportedProviders:providers] != nil;
}

@end
