#import <Cocoa/Cocoa.h>

@protocol SPOverlayPanelDelegate <NSObject>
@optional
/// Called when user selects a prompt template (by click or keyboard shortcut).
/// templateIndex is 0-based index into the prompt_templates array.
- (void)overlayPanel:(id)panel didSelectTemplateAtIndex:(NSInteger)templateIndex;
/// Called when the overlay dismisses itself (e.g. linger timer expired).
- (void)overlayPanelDidDismiss:(id)panel;
/// Called when the user clicks the pill to use raw ASR text.
- (void)overlayPanelDidRequestRawAsrFallback:(id)panel;
@end

/// The icon in front of a message on the pill.
typedef NS_ENUM(NSInteger, SPOverlayMessageIcon) {
    SPOverlayMessageIconError,
    SPOverlayMessageIconClipboard,
    SPOverlayMessageIconSuccess,
    SPOverlayMessageIconNoSpeech,
    SPOverlayMessageIconNotice,
};

/// Small status pill displayed at bottom-center of screen, above the Dock:
/// mic bars while recording, dots while processing, then a checkmark
/// (delivered), a clipboard (copied only), an xmark (cancelled) or a red xmark
/// (error) before it hides. Transcripts never appear on it; only a short
/// message (an error, "nothing heard") widens it for a few seconds.
@interface SPOverlayPanel : NSObject

@property (nonatomic, weak) id<SPOverlayPanelDelegate> delegate;
/// The screen the pill sits on; nil means the main screen.
@property (nonatomic, strong) NSScreen *screenOverride;

- (instancetype)init;

/// Update displayed state.
- (void)updateState:(NSString *)state;

/// No-op: the pill shows no text.
- (void)updateInterimText:(NSString *)text;

/// No-op: the pill shows no text.
- (void)updateDisplayText:(NSString *)text;

/// Enable clicking the pill to accept the raw ASR result.
- (void)setRawAsrFallbackClickEnabled:(BOOL)enabled;

/// Switch the pill to the clipboard icon: the text was copied but not pasted.
/// The badge text itself is not shown (use showMessage:icon: for that). Call after updateState:.
- (void)showResultBadge:(NSString *)badgeText;

/// Widen the pill with one line of text after `icon`, then hide it once the
/// text had time to be read. A session going idle meanwhile does not cut it short.
- (void)showMessage:(NSString *)text icon:(SPOverlayMessageIcon)icon;

/// While recording: a line next to the level bars ("Микрофон молчит"), nil to drop it.
- (void)setRecordingHint:(NSString *)hint;

/// Whether a message from showMessage:icon: is on screen.
@property (nonatomic, readonly, getter=isShowingMessage) BOOL showingMessage;

/// Flash one letter (the new text mode: R, L, S, F) in the pill for a moment.
/// Same pill size as every other state; call only while no dictation is running.
- (void)showModeIndicator:(NSString *)letter;

/// Dismiss the overlay after the linger period of the icon on screen.
- (void)lingerAndDismiss;
/// Same as lingerAndDismiss; the duration is ignored, the icon decides.
- (void)lingerAndDismissWithDuration:(NSTimeInterval)duration;

/// Dismiss the overlay immediately (with exit animation, no linger delay).
- (void)dismissToIdle;

/// Reload the bottom position from config.yaml.
- (void)reloadAppearanceFromConfig;

/// Show a temporary on-screen preview of the pill at the unsaved bottom margin.
/// Text and typography arguments are ignored.
- (void)showPreviewWithText:(NSString *)text
                   fontSize:(CGFloat)fontSize
                 fontFamily:(NSString *)fontFamily
               bottomMargin:(CGFloat)bottomMargin
          limitVisibleLines:(BOOL)limitVisibleLines
            maxVisibleLines:(NSInteger)maxVisibleLines;

/// Hide the temporary on-screen preview and restore configured appearance.
- (void)hidePreview;

/// Template buttons are gone; these only dismiss the pill.
- (void)showTemplateButtons:(NSArray<NSDictionary *> *)templates;
- (void)showTemplateButtons:(NSArray<NSDictionary *> *)templates lingerDuration:(NSTimeInterval)lingerDuration;

/// No-op.
- (void)hideTemplateButtons;

/// Always NO: there are no templates to trigger.
- (BOOL)handleNumberKey:(NSInteger)number;

@end
