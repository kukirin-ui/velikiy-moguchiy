#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Design tokens for the app's windows, menu and overlay.
///
/// The look is a page of an old Russian illuminated book: parchment in the light
/// appearance, black Palekh lacquer with gold in the dark one, cinnabar headings, ochre rules and
/// Bilibin-style ornaments. Every colour here is *dynamic* — it resolves against
/// the view's effective appearance — so light and dark are one code path and no
/// call site branches on the appearance itself.
///
/// Layer colours are the exception: a `CGColor` snapshots the appearance that
/// was current when it was read, so anything assigned to a layer must be
/// re-read in `-viewDidChangeEffectiveAppearance`.
@interface SPTheme : NSObject

#pragma mark - Backdrop

/// The three stops of the window's diagonal wash, top-left → bottom-right.
@property(class, readonly) NSColor *windowGradientTop;
@property(class, readonly) NSColor *windowGradientMid;
@property(class, readonly) NSColor *windowGradientBottom;

/// Translucent vellum laid over the page; the grain shows through it.
@property(class, readonly) NSColor *cardBackground;
@property(class, readonly) NSColor *cardBorder;
/// Multi-line editors and lists inside cards.
@property(class, readonly) NSColor *fieldBackground;
/// The parchment grain drawn over the backdrop gradient.
@property(class, readonly) NSColor *grainTint;
/// Clear: the sidebar shares the window gradient with the content area, so
/// there is no seam between chrome and content.
@property(class, readonly) NSColor *sidebarBackground;

#pragma mark - Text

@property(class, readonly) NSColor *primaryText;    // strong body text
@property(class, readonly) NSColor *headingText;    // cinnabar page titles and captions
@property(class, readonly) NSColor *label;          // body values
@property(class, readonly) NSColor *secondaryLabel; // descriptions, captions
@property(class, readonly) NSColor *sidebarTitle;   // sidebar rows
@property(class, readonly) NSColor *sidebarHeader;  // sidebar section captions

#pragma mark - Lines

@property(class, readonly) NSColor *separator;
/// Ochre of the ornaments and rules.
@property(class, readonly) NSColor *ornament;
/// Cinnabar: the accent of buttons and selected items.
@property(class, readonly) NSColor *accent;
/// Status text: olive for success, ochre for warnings, cinnabar for failures.
@property(class, readonly) NSColor *success;
@property(class, readonly) NSColor *warning;
@property(class, readonly) NSColor *failure;

#pragma mark - Interaction

/// A translucent grey darkening, like macOS System Settings — not a white
/// elevated pill and not the system blue. It has to read correctly straight
/// over the gradient.
@property(class, readonly) NSColor *selectionBackground;
@property(class, readonly) NSColor *sidebarHover;
/// The selected sidebar row: a cinnabar plate with gold edge and light text.
@property(class, readonly) NSColor *sidebarSelection;
@property(class, readonly) NSColor *sidebarSelectionText;
/// The default (Return) button: a cinnabar plate with light text.
@property(class, readonly) NSColor *primaryButton;
@property(class, readonly) NSColor *primaryButtonText;

#pragma mark - Metrics

@property(class, readonly) CGFloat sidebarWidth;      // 208
@property(class, readonly) CGFloat pageTitleBaseline; // 84 — inside the arch of the page frame
@property(class, readonly) CGFloat pageContentTop;    // 108 — below the arch's base rule
@property(class, readonly) CGFloat pageMargin;        // 28
@property(class, readonly) CGFloat cardCornerRadius;  // 8
@property(class, readonly) CGFloat cardPadding;       // 18
@property(class, readonly) CGFloat sectionGap;        // 26 — between sections
@property(class, readonly) CGFloat sectionHeadingGap; // 12 — caption → row
@property(class, readonly) NSSize windowContentSize;  // 940 × 726

#pragma mark - Type

/// Registers the bundled OFL fonts (Oglavie, Monomakh, Old Standard TT) for this
/// process. Safe to call more than once; every font accessor calls it.
+ (void)registerFonts;
/// Oglavie: the condensed vyaz of titles (write it in capitals).
+ (NSFont *)vyazFontOfSize:(CGFloat)size;
/// Monomakh: the Old Russian book hand for captions, sidebar rows and capitals.
+ (NSFont *)bookHandFontOfSize:(CGFloat)size;
/// A heading in the house style: gilded book-hand capitals, vyaz for the rest.
+ (NSAttributedString *)titleString:(NSString *)text size:(CGFloat)size;
/// Gold leaf for capitals and fine rules.
@property(class, readonly) NSColor *gold;
/// Old Standard TT: headings and captions in the old typographic style.
+ (NSFont *)oldStyleFontOfSize:(CGFloat)size bold:(BOOL)bold;
+ (NSFont *)oldStyleItalicFontOfSize:(CGFloat)size;

+ (NSFont *)pageTitleFont;   // vyaz 31
+ (NSFont *)cardTitleFont;   // book hand 16
+ (NSFont *)bodyFont;        // 12.5 regular
+ (NSFont *)descriptionFont; // 11.5 regular
+ (NSFont *)captionFont;     // book hand 16
+ (NSFont *)sidebarRowFont;  // book hand 16
/// Form field captions. Kept at the AppKit control size so a caption reads as
/// the same weight as the field it labels.
+ (NSFont *)formLabelFont;   // 13 medium

#pragma mark - Ornament

/// A caption after a small gilded lily, as an attributed string.
+ (NSAttributedString *)ornamentedCaption:(NSString *)text
                                     font:(NSFont *)font
                                    color:(NSColor *)color;

#pragma mark - Construction

/// Build a dynamic colour from light/dark sRGB hex plus alpha.
+ (NSColor *)dynamicLight:(uint32_t)lightHex
               lightAlpha:(CGFloat)lightAlpha
                     dark:(uint32_t)darkHex
                darkAlpha:(CGFloat)darkAlpha;

@end

NS_ASSUME_NONNULL_END
