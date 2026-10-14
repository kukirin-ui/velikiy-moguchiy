#import "SPQwenModelChoice.h"

@implementation SPQwenModelChoice

+ (NSString *)defaultModel {
    return @"qwen3.8-omni-flash-realtime";
}

+ (NSArray<NSString *> *)presetModels {
    return @[ self.defaultModel, @"qwen3-asr-flash-realtime" ];
}

+ (NSString *)titleForPresetModel:(NSString *)model {
    if ([model isEqualToString:self.defaultModel]) {
        return [model stringByAppendingString:@" — умная, точнее (по умолчанию)"];
    }
    return [model stringByAppendingString:@" — дословная"];
}

+ (NSString *)effectiveModelForConfigValue:(NSString *)configValue {
    NSString *model = [configValue
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return model.length > 0 ? model : self.defaultModel;
}

+ (BOOL)isPresetModel:(NSString *)model {
    return [self.presetModels containsObject:model];
}

+ (NSString *)modelToSaveForPreset:(NSString *)presetModel customText:(NSString *)customText {
    if (presetModel.length > 0) return presetModel;
    NSString *custom = [customText
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return custom.length > 0 ? custom : nil;
}

@end
