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

/// Small fixed-size status pill displayed at bottom-center of screen, above the
/// Dock. It never shows text: mic bars while recording, dots while processing,
/// then a checkmark (delivered), a clipboard (copied only), an xmark
/// (cancelled) or a red xmark (error) before it hides.
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
/// The badge text itself is not shown. Call after updateState:.
- (void)showResultBadge:(NSString *)badgeText;

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
