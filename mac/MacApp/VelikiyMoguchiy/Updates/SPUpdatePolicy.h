#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Pure decisions of the update checks (the app on GitHub Releases, the lips
/// model on velikiy-moguchiy-models), apart from the network so they can be
/// unit tested.
@interface SPUpdatePolicy : NSObject

/// Compares dotted numeric versions ("0.10.0" > "0.9.2", "1.0" == "1.0.0").
/// A "-suffix" (pre-release, build) is ignored; non-numeric parts count as 0.
+ (NSComparisonResult)compareVersion:(NSString *)version toVersion:(NSString *)other;

/// The version in a release tag with this prefix ("v0.2.0" and "v" -> "0.2.0",
/// "lips-0.1" and "lips-" -> "0.1"), or nil when the tag does not have the
/// prefix or nothing numeric follows it.
+ (nullable NSString *)versionFromTag:(nullable NSString *)tag prefix:(NSString *)prefix;

/// Whether a check is due: never checked, at least a day since the last one,
/// or the last one is in the future (the clock was changed).
+ (BOOL)isCheckDueWithLastCheck:(nullable NSDate *)lastCheck now:(NSDate *)now;

/// The release with the highest version among the published ones (no drafts,
/// no pre-releases) whose tag has the prefix, from a GitHub
/// `GET /repos/{owner}/{repo}/releases` reply. Nil when there is none.
+ (nullable NSDictionary *)newestReleaseIn:(nullable id)releases tagPrefix:(NSString *)prefix;

@end

NS_ASSUME_NONNULL_END
