#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The «Сообщить о проблеме» report: what the app may put into a GitHub issue
/// and how it is cleaned first. Pure, for unit tests; collecting the log and
/// showing the preview are SPProblemReportWindowController's job.
@interface SPProblemReport : NSObject

/// The log with keys and tokens, e-mail addresses, dictated text (quoted text
/// and what follows text markers) and the user's name in paths replaced.
+ (NSString *)redactedLog:(NSString *)log homeDirectory:(nullable NSString *)homeDirectory;

/// A pre-filled issue on the «Сообщить о проблеме» form. When the URL would
/// be too long for GitHub the oldest log lines are dropped first.
+ (NSURL *)issueURLWithAppVersion:(NSString *)appVersion
                           system:(NSString *)system
                         provider:(NSString *)provider
                              log:(NSString *)log;

/// GitHub refuses longer issue URLs.
@property (class, nonatomic, readonly) NSUInteger maxURLLength;

@end

NS_ASSUME_NONNULL_END
