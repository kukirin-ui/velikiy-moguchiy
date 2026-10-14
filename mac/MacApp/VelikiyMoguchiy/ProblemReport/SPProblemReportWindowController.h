#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// «Сообщить о проблеме»: gathers the app version, the macOS version and the
/// last lines of this run's log, cleaned by SPProblemReport, and shows all of
/// it for review and editing. Only «Открыть на GitHub» sends anything: it
/// opens a pre-filled issue form in the browser, which the user submits.
@interface SPProblemReportWindowController : NSWindowController

- (instancetype)init;
- (void)present;

@end

NS_ASSUME_NONNULL_END
