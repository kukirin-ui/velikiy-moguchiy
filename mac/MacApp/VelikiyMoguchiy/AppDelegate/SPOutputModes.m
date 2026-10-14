#import "SPOutputModes.h"

NSArray<NSString *> *SPOutputModeIds(void) {
    return @[ @"raw", @"light", @"structured", @"formal" ];
}

NSString *SPNormalizedOutputMode(NSString *mode) {
    NSString *trimmed = [[mode ?: @"" stringByTrimmingCharactersInSet:
                                          [NSCharacterSet whitespaceAndNewlineCharacterSet]]
        lowercaseString];
    return [SPOutputModeIds() containsObject:trimmed] ? trimmed : @"raw";
}

NSString *SPNextOutputMode(NSString *mode) {
    NSArray<NSString *> *ids = SPOutputModeIds();
    NSUInteger index = [ids indexOfObject:SPNormalizedOutputMode(mode)];
    return ids[(index + 1) % ids.count];
}

NSString *SPOutputModeTitle(NSString *mode) {
    NSString *normalized = SPNormalizedOutputMode(mode);
    if ([normalized isEqualToString:@"light"]) return @"Лёгкая правка";
    if ([normalized isEqualToString:@"structured"]) return @"Структура";
    if ([normalized isEqualToString:@"formal"]) return @"Деловой стиль";
    return @"Как сказал";
}

NSString *SPOutputModeLetter(NSString *mode) {
    NSString *normalized = SPNormalizedOutputMode(mode);
    if ([normalized isEqualToString:@"light"]) return @"L";
    if ([normalized isEqualToString:@"structured"]) return @"S";
    if ([normalized isEqualToString:@"formal"]) return @"F";
    return @"R";
}
