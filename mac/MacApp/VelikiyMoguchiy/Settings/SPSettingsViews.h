#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// The primary container: a sheet of vellum (lacquer in the dark appearance)
/// edged with a gold rule, a cinnabar hairline and gilded corner brackets.
@interface SPCardView : NSView
@property(nonatomic, assign) CGFloat cornerRadius; // default 8
@end

/// A section caption: the book hand in cinnabar (gold on lacquer) after a small lily.
/// Every section heading in the window is one of these.
@interface SPCaptionLabel : NSTextField
+ (instancetype)captionWithString:(NSString *)text;
@end

/// Paints the window backdrop behind the *entire* window, sidebar included: a
/// parchment (or black lacquer) wash at 315°, the parchment grain, the band
/// along the sidebar and the page frame with the title arch.
@interface SPGradientBackdropView : NSView
@end

/// A horizontal Bilibin-style divider: ochre rules running out from a centred
/// ornament (a rosette between scrolls). Height 20.
@interface SPOrnamentDividerView : NSView
@end

/// A концовка (tailpiece) closing a page that does not fill the window.
@interface SPTailpieceView : NSView
@end

/// Restyles the AppKit controls under `root` in the house style: push buttons
/// and pop-ups become vellum plates edged in gold (the default button cinnabar),
/// editable fields take the vellum background.
void SPApplyHouseStyle(NSView *root);

NS_ASSUME_NONNULL_END
