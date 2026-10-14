#import <Foundation/Foundation.h>

@interface SPCuePlayer : NSObject

/// Refresh feedback settings from Rust core config.
/// Call this at session start to pick up config changes.
- (void)reloadFeedbackConfig;

- (void)playStart;
- (void)playStop;
- (void)playError;

@end
