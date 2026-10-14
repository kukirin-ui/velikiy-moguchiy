#import <Cocoa/Cocoa.h>

/// "Последние диктовки": searchable list of the last dictations with
/// click-to-copy, audio playback, re-transcription, context actions and a ZIP export.
@class SPClipboardManager;

@interface SPRecentDictationsWindowController : NSWindowController

/// Receives the text of a manual re-transcription ("Распознать заново").
@property (nonatomic, strong) SPClipboardManager *clipboardManager;

- (void)present;

@end
