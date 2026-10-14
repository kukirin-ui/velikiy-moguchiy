#import <Cocoa/Cocoa.h>

@class SPRustBridge;

@protocol SPSetupWizardDelegate <NSObject>
@optional
/// Called after the wizard saves config, so the app can reload.
- (void)setupWizardDidSaveConfig;
@end

/// Draws `view` into a PNG at its window's backing scale.
void SPWriteViewSnapshot(NSView *view, NSString *path);

@interface SPSetupWizardWindowController : NSWindowController

@property (nonatomic, weak) id<SPSetupWizardDelegate> delegate;
@property (nonatomic, strong) SPRustBridge *rustBridge;
/// Brings the window up on `pane` (asr, llm, hotkey, …).
- (void)showPane:(NSString *)pane;
/// Design preview: shows the window on `screen` at `pane` (asr, llm, hotkey,
/// overlay, dictionary, snippets, system_prompt, templates, about) without
/// activating the app or taking focus.
- (void)showForDesignPreviewOnScreen:(NSScreen *)screen pane:(NSString *)pane;
/// Design preview: every pane in turn, drawn by the window itself into
/// `<directory>/settings-<pane><suffix>.png`.
- (void)writeDesignSnapshotsToDirectory:(NSString *)directory suffix:(NSString *)suffix;

@end
