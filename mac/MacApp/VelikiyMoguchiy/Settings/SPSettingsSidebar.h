#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// The settings window's left-hand navigation. Its background is clear so it
/// shares the window gradient with the content area — there is no seam between
/// chrome and content.
@interface SPSettingsSidebarViewController : NSViewController

/// Called with the pane identifier when a row is clicked.
@property(nonatomic, copy, nullable) void (^onSelect)(NSString *paneIdentifier);

/// Move the selection without invoking `onSelect`.
- (void)selectPaneIdentifier:(NSString *)identifier;

@end

NS_ASSUME_NONNULL_END
