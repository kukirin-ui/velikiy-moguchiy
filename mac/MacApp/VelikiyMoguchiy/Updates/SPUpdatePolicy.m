#import "SPUpdatePolicy.h"

static const NSTimeInterval kCheckInterval = 24 * 60 * 60;

@implementation SPUpdatePolicy

+ (NSArray<NSNumber *> *)componentsOfVersion:(NSString *)version {
    NSString *core = [version componentsSeparatedByString:@"-"].firstObject ?: @"";
    NSMutableArray<NSNumber *> *parts = [NSMutableArray array];
    for (NSString *part in [core componentsSeparatedByString:@"."]) {
        [parts addObject:@(part.integerValue)];
    }
    return parts;
}

+ (NSComparisonResult)compareVersion:(NSString *)version toVersion:(NSString *)other {
    NSArray<NSNumber *> *a = [self componentsOfVersion:version ?: @""];
    NSArray<NSNumber *> *b = [self componentsOfVersion:other ?: @""];
    NSUInteger count = MAX(a.count, b.count);
    for (NSUInteger i = 0; i < count; i++) {
        NSInteger x = i < a.count ? a[i].integerValue : 0;
        NSInteger y = i < b.count ? b[i].integerValue : 0;
        if (x < y) return NSOrderedAscending;
        if (x > y) return NSOrderedDescending;
    }
    return NSOrderedSame;
}

+ (NSString *)versionFromTag:(NSString *)tag prefix:(NSString *)prefix {
    if (![tag isKindOfClass:[NSString class]] || ![tag hasPrefix:prefix]) return nil;
    NSString *version = [tag substringFromIndex:prefix.length];
    if (version.length == 0) return nil;
    unichar first = [version characterAtIndex:0];
    if (first < '0' || first > '9') return nil;
    return version;
}

+ (BOOL)isCheckDueWithLastCheck:(NSDate *)lastCheck now:(NSDate *)now {
    if (!lastCheck) return YES;
    NSTimeInterval elapsed = [now timeIntervalSinceDate:lastCheck];
    return elapsed < 0 || elapsed >= kCheckInterval;
}

+ (NSDictionary *)newestReleaseIn:(id)releases tagPrefix:(NSString *)prefix {
    if (![releases isKindOfClass:[NSArray class]]) return nil;
    NSDictionary *best = nil;
    NSString *bestVersion = nil;
    for (id release in releases) {
        if (![release isKindOfClass:[NSDictionary class]]) continue;
        if ([release[@"draft"] boolValue] || [release[@"prerelease"] boolValue]) continue;
        NSString *version = [self versionFromTag:release[@"tag_name"] prefix:prefix];
        if (!version) continue;
        if (!bestVersion || [self compareVersion:version toVersion:bestVersion] == NSOrderedDescending) {
            best = release;
            bestVersion = version;
        }
    }
    return best;
}

@end
