#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The Qwen realtime models offered in Settings → Распознавание, and the mapping
/// between `asr.qwen.model` and the picker. Only models the Qwen provider can
/// drive are listed: the realtime protocol at /api-ws/v1/realtime (Omni and
/// Qwen-ASR). fun-asr and paraformer speak a different DashScope protocol.
@interface SPQwenModelChoice : NSObject

/// Same value as `default_qwen_model` in velikiy-moguchiy-core/src/config.rs.
@property (class, nonatomic, readonly) NSString *defaultModel;

/// Model ids in picker order; the default comes first.
@property (class, nonatomic, readonly) NSArray<NSString *> *presetModels;

+ (NSString *)titleForPresetModel:(NSString *)model;

/// The configured model, or the default when the config has none.
+ (NSString *)effectiveModelForConfigValue:(nullable NSString *)configValue;

+ (BOOL)isPresetModel:(NSString *)model;

/// What to write to `asr.qwen.model`: the preset id, or the trimmed custom
/// text when `presetModel` is nil ("Другая…"). nil when the custom text is
/// empty, so an unfinished entry never overwrites the saved model.
+ (nullable NSString *)modelToSaveForPreset:(nullable NSString *)presetModel
                                 customText:(nullable NSString *)customText;

@end

NS_ASSUME_NONNULL_END
