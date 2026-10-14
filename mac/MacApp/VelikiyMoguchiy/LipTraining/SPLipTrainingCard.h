#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// «Обучить на мне» in the settings' lip-reading section: the clips available
/// for a personal fine-tune, the mode (лёгкий / полный), the button, progress
/// with ETA and cancel, the result (old vs new WER on held-out clips),
/// «Вернуть прежнюю модель», and the «Поделиться улучшением» consent (disabled
/// until community training is deployed). A section caption plus a card, laid
/// out by the pane like the other cards; its height is fixed.
@interface SPLipTrainingCard : NSView

- (instancetype)initWithWidth:(CGFloat)width;

/// Counts the clips again and reads the job's status.
- (void)refresh;

@end

NS_ASSUME_NONNULL_END
