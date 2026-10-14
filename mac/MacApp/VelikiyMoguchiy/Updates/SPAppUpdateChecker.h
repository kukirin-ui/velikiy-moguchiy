#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Looks for a newer «Великий & Могучий» on GitHub Releases at most once a
/// day. The builds are not signed by Apple, so it never installs anything: it
/// only reports the version and the release page.
@interface SPAppUpdateChecker : NSObject

/// The newer version found by an earlier check, so the menu can show it at
/// once after a restart. Nil when this build is current.
+ (nullable NSString *)knownNewerVersion;
+ (nullable NSURL *)knownReleasePage;

/// Checks when due; calls the handler on the main queue only when a newer
/// version is known, and `isNew` is YES the first time this version is seen.
+ (void)checkIfDueWithHandler:(void (^)(NSString *version, NSURL *page, BOOL isNew))handler;

@end

NS_ASSUME_NONNULL_END
