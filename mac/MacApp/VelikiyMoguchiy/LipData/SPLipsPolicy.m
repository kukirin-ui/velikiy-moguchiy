#import "SPLipsPolicy.h"

static const NSInteger kDefaultPort = 8766;
static const double kDefaultIdleMinutes = 10.0;

@implementation SPLipsPolicy

+ (NSString *)insertableTextFromServiceReply:(NSDictionary *)reply {
    if (![reply isKindOfClass:[NSDictionary class]]) return nil;
    id raw = reply[@"text"];
    if (![raw isKindOfClass:[NSString class]]) return nil;
    NSString *text = [(NSString *)raw stringByTrimmingCharactersInSet:
                                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (text.length == 0) return nil;
    NSRange first = [text rangeOfComposedCharacterSequenceAtIndex:0];
    return [[[text substringWithRange:first] uppercaseString] stringByAppendingString:[text substringFromIndex:NSMaxRange(first)]];
}

+ (NSArray<NSString *> *)serviceArgumentsWithScript:(NSString *)scriptPath
                                               port:(NSInteger)port
                                        idleMinutes:(double)idleMinutes
                                          parentPid:(pid_t)parentPid {
    return @[
        scriptPath,
        @"--port", [NSString stringWithFormat:@"%ld", (long)port],
        @"--idle-sec", [NSString stringWithFormat:@"%.0f", idleMinutes * 60.0],
        @"--parent-pid", [NSString stringWithFormat:@"%d", parentPid],
    ];
}

+ (NSInteger)portFromConfigValue:(NSString *)value {
    NSString *trimmed = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSScanner *scanner = [NSScanner scannerWithString:trimmed ?: @""];
    NSInteger port = 0;
    if (![scanner scanInteger:&port] || !scanner.isAtEnd) return kDefaultPort;
    return (port >= 1024 && port <= 65535) ? port : kDefaultPort;
}

+ (double)idleMinutesFromConfigValue:(NSString *)value {
    NSString *trimmed = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSScanner *scanner = [NSScanner scannerWithString:trimmed ?: @""];
    double minutes = 0;
    if (![scanner scanDouble:&minutes] || !scanner.isAtEnd || minutes <= 0) return kDefaultIdleMinutes;
    return minutes;
}

@end
