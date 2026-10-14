#import "SPTheme.h"
#import <CoreText/CoreText.h>

static NSColor *sRGB(uint32_t hex, CGFloat alpha) {
  return [NSColor colorWithSRGBRed:((hex >> 16) & 0xFF) / 255.0
                             green:((hex >> 8) & 0xFF) / 255.0
                              blue:(hex & 0xFF) / 255.0
                             alpha:alpha];
}

// The owner's palette (an aged-varnish painting): parchment E8DCC8, light
// CEBAA6, umber 32261E, ink 170F0C, ochre 9A7A3C, olive 6B6433, dusty rose
// B98A78, smoky sky 87785C, cinnabar 9B3A2C.

@implementation SPTheme

+ (NSColor *)dynamicLight:(uint32_t)lightHex
               lightAlpha:(CGFloat)lightAlpha
                     dark:(uint32_t)darkHex
                darkAlpha:(CGFloat)darkAlpha {
  return [NSColor
      colorWithName:nil
    dynamicProvider:^NSColor *(NSAppearance *appearance) {
      NSAppearanceName name = [appearance
          bestMatchFromAppearancesWithNames:@[
            NSAppearanceNameAqua, NSAppearanceNameDarkAqua
          ]];
      BOOL dark = [name isEqualToString:NSAppearanceNameDarkAqua];
      return dark ? sRGB(darkHex, darkAlpha) : sRGB(lightHex, lightAlpha);
    }];
}

// ─── Backdrop ───────────────────────────────────────────────────────

// Parchment lit from the top-left, darkening toward the bottom-right; in the
// dark appearance the same fall-off on an ink page.
+ (NSColor *)windowGradientTop {
  return [self dynamicLight:0xF0E7D7 lightAlpha:1 dark:0x1A1310 darkAlpha:1];
}
+ (NSColor *)windowGradientMid {
  return [self dynamicLight:0xE8DCC8 lightAlpha:1 dark:0x110C0A darkAlpha:1];
}
+ (NSColor *)windowGradientBottom {
  return [self dynamicLight:0xDCCBB4 lightAlpha:1 dark:0x080605 darkAlpha:1];
}

+ (NSColor *)cardBackground {
  return [self dynamicLight:0xF6EFE2 lightAlpha:0.72 dark:0x1C1512 darkAlpha:0.9];
}
+ (NSColor *)cardBorder {
  return [self dynamicLight:0xB08A3A lightAlpha:0.9 dark:0xC9A24A darkAlpha:0.75];
}
+ (NSColor *)fieldBackground {
  return [self dynamicLight:0xFAF5EC lightAlpha:1 dark:0x241B16 darkAlpha:1];
}
+ (NSColor *)grainTint {
  return [self dynamicLight:0x32261E lightAlpha:0.10 dark:0x000000 darkAlpha:0.0];
}
+ (NSColor *)sidebarBackground { return NSColor.clearColor; }

// ─── Text ───────────────────────────────────────────────────────────

+ (NSColor *)primaryText {
  return [self dynamicLight:0x32261E lightAlpha:1 dark:0xE8DCC8 darkAlpha:1];
}
+ (NSColor *)headingText {
  return [self dynamicLight:0x9B3A2C lightAlpha:1 dark:0xD9B865 darkAlpha:1];
}
+ (NSColor *)label {
  return [self dynamicLight:0x32261E lightAlpha:1 dark:0xEADFCB darkAlpha:1];
}
+ (NSColor *)secondaryLabel {
  return [self dynamicLight:0x5A4C38 lightAlpha:1 dark:0xA89A82 darkAlpha:1];
}
+ (NSColor *)sidebarTitle {
  return [self dynamicLight:0x32261E lightAlpha:1 dark:0xE8DCC8 darkAlpha:1];
}
+ (NSColor *)sidebarHeader {
  return [self dynamicLight:0x6B5220 lightAlpha:1 dark:0xC9A24A darkAlpha:1];
}

// ─── Lines ──────────────────────────────────────────────────────────

+ (NSColor *)separator {
  return [self dynamicLight:0x9A7A3C lightAlpha:0.38 dark:0xC9A24A darkAlpha:0.3];
}
+ (NSColor *)ornament {
  return [self dynamicLight:0x7E6226 lightAlpha:1 dark:0xC9A24A darkAlpha:1];
}
+ (NSColor *)accent {
  return [self dynamicLight:0x9B3A2C lightAlpha:1 dark:0xB8442F darkAlpha:1];
}

+ (NSColor *)success {
  return [self dynamicLight:0x5A5A22 lightAlpha:1 dark:0xA9A15E darkAlpha:1];
}
+ (NSColor *)warning {
  return [self dynamicLight:0x8A6420 lightAlpha:1 dark:0xD0A85A darkAlpha:1];
}
+ (NSColor *)failure {
  return [self dynamicLight:0x9B3A2C lightAlpha:1 dark:0xD9826C darkAlpha:1];
}

// ─── Interaction ────────────────────────────────────────────────────

+ (NSColor *)selectionBackground {
  return [self dynamicLight:0x9B3A2C lightAlpha:0.13 dark:0xC9A24A darkAlpha:0.16];
}
+ (NSColor *)sidebarSelection {
  return [self dynamicLight:0x9B3A2C lightAlpha:1 dark:0x8E2F22 darkAlpha:1];
}
+ (NSColor *)primaryButton {
  return [self dynamicLight:0x9B3A2C lightAlpha:1 dark:0xA33826 darkAlpha:1];
}
+ (NSColor *)primaryButtonText {
  return [self dynamicLight:0xF6EEDF lightAlpha:1 dark:0xFFF1D6 darkAlpha:1];
}
+ (NSColor *)sidebarSelectionText {
  return [self dynamicLight:0xF6EEDF lightAlpha:1 dark:0xF2DC9A darkAlpha:1];
}
+ (NSColor *)sidebarHover {
  return [self dynamicLight:0x32261E lightAlpha:0.07 dark:0xC9A24A darkAlpha:0.10];
}

// ─── Metrics ────────────────────────────────────────────────────────

+ (CGFloat)sidebarWidth { return 208.0; }
+ (CGFloat)pageTitleBaseline { return 84.0; }
+ (CGFloat)pageContentTop { return 108.0; }
+ (CGFloat)pageMargin { return 28.0; }
+ (CGFloat)cardCornerRadius { return 8.0; }
+ (CGFloat)cardPadding { return 18.0; }
+ (CGFloat)sectionGap { return 26.0; }
+ (CGFloat)sectionHeadingGap { return 12.0; }
+ (NSSize)windowContentSize { return NSMakeSize(940.0, 726.0); }

// ─── Type ───────────────────────────────────────────────────────────

+ (void)registerFonts {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    for (NSString *extension in @[ @"ttf", @"otf" ]) {
      for (NSURL *url in [NSBundle.mainBundle URLsForResourcesWithExtension:extension
                                                               subdirectory:nil]) {
        CTFontManagerRegisterFontsForURL((__bridge CFURLRef)url,
                                         kCTFontManagerScopeProcess, NULL);
      }
    }
  });
}

+ (NSFont *)fontNamed:(NSString *)name size:(CGFloat)size fallback:(NSFont *)fallback {
  [self registerFonts];
  return [NSFont fontWithName:name size:size] ?: fallback;
}

+ (NSFont *)vyazFontOfSize:(CGFloat)size {
  return [self fontNamed:@"OglavieUnicode"
                    size:size
                fallback:[NSFont fontWithName:@"Georgia-Bold" size:size]
                             ?: [NSFont boldSystemFontOfSize:size]];
}

+ (NSFont *)bookHandFontOfSize:(CGFloat)size {
  return [self fontNamed:@"MonomakhUnicode"
                    size:size
                fallback:[NSFont fontWithName:@"Georgia" size:size]
                             ?: [NSFont systemFontOfSize:size]];
}

+ (NSFont *)oldStyleFontOfSize:(CGFloat)size bold:(BOOL)bold {
  return [self fontNamed:bold ? @"OldStandardTT-Bold" : @"OldStandardTT-Regular"
                    size:size
                fallback:[NSFont fontWithName:bold ? @"Georgia-Bold" : @"Georgia" size:size]
                             ?: [NSFont systemFontOfSize:size]];
}

+ (NSFont *)oldStyleItalicFontOfSize:(CGFloat)size {
  return [self fontNamed:@"OldStandardTT-Italic"
                    size:size
                fallback:[NSFont fontWithName:@"Georgia-Italic" size:size]
                             ?: [NSFont systemFontOfSize:size]];
}

+ (NSFont *)pageTitleFont { return [self vyazFontOfSize:36]; }
+ (NSFont *)cardTitleFont { return [self bookHandFontOfSize:16]; }
+ (NSFont *)bodyFont { return [self oldStyleFontOfSize:14 bold:NO]; }
+ (NSFont *)descriptionFont { return [self oldStyleFontOfSize:13 bold:NO]; }
+ (NSFont *)captionFont { return [self bookHandFontOfSize:16]; }
+ (NSFont *)sidebarRowFont { return [self bookHandFontOfSize:16]; }
+ (NSFont *)formLabelFont { return [self oldStyleFontOfSize:14 bold:YES]; }

+ (NSColor *)gold {
  return [self dynamicLight:0xB8902F lightAlpha:1 dark:0xD9B865 darkAlpha:1];
}

+ (NSAttributedString *)titleString:(NSString *)text size:(CGFloat)size {
  // House style: each word's first letter is a gilded capital in the book hand,
  // the rest is vyaz in capitals, cinnabar on parchment and gold on lacquer.
  NSMutableAttributedString *out = [NSMutableAttributedString new];
  NSShadow *shadow = [NSShadow new];
  shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.25];
  shadow.shadowOffset = NSMakeSize(0.6, -0.8);
  shadow.shadowBlurRadius = 0.8;
  NSDictionary *capital = @{
    NSFontAttributeName : [self bookHandFontOfSize:round(size * 1.18)],
    NSForegroundColorAttributeName : self.gold,
    NSStrokeColorAttributeName : [self dynamicLight:0x32261E lightAlpha:1 dark:0x000000 darkAlpha:1],
    NSStrokeWidthAttributeName : @(-2.5),
    NSShadowAttributeName : shadow,
  };
  NSDictionary *vyaz = @{
    NSFontAttributeName : [self vyazFontOfSize:size],
    NSForegroundColorAttributeName : self.headingText,
    NSKernAttributeName : @0.6,
  };
  NSArray<NSString *> *words = [text componentsSeparatedByString:@" "];
  [words enumerateObjectsUsingBlock:^(NSString *word, NSUInteger i, BOOL *stop) {
    if (i > 0)
      [out appendAttributedString:[[NSAttributedString alloc] initWithString:@" " attributes:vyaz]];
    if (word.length == 0)
      return;
    BOOL gild = [word isEqualToString:@"&"] ||
                [NSCharacterSet.uppercaseLetterCharacterSet characterIsMember:[word characterAtIndex:0]];
    if (gild) {
      [out appendAttributedString:[[NSAttributedString alloc] initWithString:[word substringToIndex:1]
                                                                  attributes:capital]];
      word = [word substringFromIndex:1];
    }
    [out appendAttributedString:[[NSAttributedString alloc] initWithString:word.uppercaseString
                                                                attributes:vyaz]];
  }];
  return out;
}

// ─── Ornament ───────────────────────────────────────────────────────

+ (NSAttributedString *)ornamentedCaption:(NSString *)text
                                     font:(NSFont *)font
                                    color:(NSColor *)color {
  NSMutableAttributedString *out = [NSMutableAttributedString new];
  NSImage *rosette = [NSImage imageNamed:@"Krin"];
  if (rosette) {
    NSTextAttachment *attachment = [NSTextAttachment new];
    attachment.image = rosette;
    CGFloat side = round(font.capHeight * 1.9);
    attachment.bounds = NSMakeRect(0, round((font.capHeight - side) / 2.0), side, side);
    [out appendAttributedString:[NSAttributedString attributedStringWithAttachment:attachment]];
    [out appendAttributedString:[[NSAttributedString alloc] initWithString:@"  "]];
  }
  [out appendAttributedString:[[NSAttributedString alloc]
                                  initWithString:text
                                      attributes:@{
                                        NSFontAttributeName : font,
                                        NSForegroundColorAttributeName : color,
                                        NSKernAttributeName : @0.4,
                                      }]];
  [out addAttribute:NSFontAttributeName value:font range:NSMakeRange(0, out.length - text.length)];
  return out;
}

@end
