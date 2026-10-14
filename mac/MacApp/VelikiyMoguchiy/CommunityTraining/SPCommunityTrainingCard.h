#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// «Помочь обучить» in the settings' lip-reading section: the separate consent, GitHub login
/// (device code), the button that starts a community training job, its progress with pause and
/// cancel, and «Что будет отправлено» with «Отправить» / «Не отправлять». A section caption plus
/// a card of fixed height, laid out by the pane like the other cards.
@interface SPCommunityTrainingCard : NSView

- (instancetype)initWithWidth:(CGFloat)width;

/// Reads the client's status again.
- (void)refresh;

@end

NS_ASSUME_NONNULL_END
