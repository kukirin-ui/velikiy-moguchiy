#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// A small window for a long download or setup: what is happening, a progress
/// bar and a cancel button. Closing the window while it works cancels too.
@interface SPProgressPanel : NSWindowController

- (instancetype)initWithTitle:(NSString *)title;

/// Runs once, on the main queue, when the user cancels the work.
@property (nonatomic, copy, nullable) void (^cancelHandler)(void);

- (void)present;
- (void)setStep:(NSString *)step detail:(nullable NSString *)detail;
/// 0...1; a negative value shows an indeterminate bar.
- (void)setProgress:(double)fraction;
/// The work is over: shows the message and turns the cancel button into «Закрыть».
- (void)finishWithMessage:(NSString *)message success:(BOOL)success;

@end

NS_ASSUME_NONNULL_END
