#import "SPSettingsViews.h"
#import "SPTheme.h"

@implementation SPCardView

- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    _cornerRadius = SPTheme.cardCornerRadius;
    self.wantsLayer = YES;
    [self applyStyle];
  }
  return self;
}

- (void)setCornerRadius:(CGFloat)cornerRadius {
  _cornerRadius = cornerRadius;
  [self applyStyle];
}

- (void)applyStyle {
  self.layer.cornerRadius = _cornerRadius;
  self.layer.borderWidth = 1.0;
  self.layer.shadowColor = NSColor.blackColor.CGColor;
  self.layer.shadowOpacity = 0.12;
  self.layer.shadowRadius = 6.0;
  self.layer.shadowOffset = CGSizeMake(0, -2);
  // Required — the shadow has to escape the card's bounds.
  self.layer.masksToBounds = NO;
  // Resolve the dynamic fill under THIS view's appearance: a plain `.CGColor`
  // resolves against the *app's* appearance, which is wrong whenever the window
  // renders in the other one.
  [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
    self.layer.backgroundColor = SPTheme.cardBackground.CGColor;
    self.layer.borderColor = SPTheme.cardBorder.CGColor;
  }];
  self.needsDisplay = YES;
}

// The inner hairline of the double rule and gilded corner brackets.
- (void)drawRect:(NSRect)dirtyRect {
  NSRect inner = NSInsetRect(self.bounds, 3.5, 3.5);
  CGFloat radius = MAX(_cornerRadius - 3.0, 0.0);
  NSBezierPath *rule = [NSBezierPath bezierPathWithRoundedRect:inner
                                                       xRadius:radius
                                                       yRadius:radius];
  rule.lineWidth = 0.6;
  [[SPTheme.accent colorWithAlphaComponent:0.45] setStroke];
  [rule stroke];

  CGFloat arm = 14.0, inset = 6.0;
  NSRect b = self.bounds;
  [SPTheme.gold setStroke];
  for (int corner = 0; corner < 4; corner++) {
    CGFloat x = corner % 2 ? NSMaxX(b) - inset : NSMinX(b) + inset;
    CGFloat y = corner < 2 ? NSMaxY(b) - inset : NSMinY(b) + inset;
    CGFloat dx = corner % 2 ? -1 : 1, dy = corner < 2 ? -1 : 1;
    NSBezierPath *bracket = [NSBezierPath bezierPath];
    bracket.lineWidth = 1.4;
    bracket.lineCapStyle = NSLineCapStyleRound;
    [bracket moveToPoint:NSMakePoint(x + dx * arm, y)];
    [bracket lineToPoint:NSMakePoint(x, y)];
    [bracket lineToPoint:NSMakePoint(x, y + dy * arm)];
    [bracket stroke];
    NSRect dot = NSMakeRect(x + dx * 3.5 - 1.6, y + dy * 3.5 - 1.6, 3.2, 3.2);
    [SPTheme.accent setFill];
    [[NSBezierPath bezierPathWithOvalInRect:dot] fill];
  }
}

// CGColor does not follow the appearance the way NSColor does, so every layer
// colour has to be re-read here. Skipping this is the single easiest thing to
// get wrong: the card looks correct until the user switches theme.
- (void)viewDidChangeEffectiveAppearance {
  [super viewDidChangeEffectiveAppearance];
  [self applyStyle];
}

@end

@implementation SPCaptionLabel {
  NSString *_plainText;
}

+ (instancetype)captionWithString:(NSString *)text {
  SPCaptionLabel *label = [self labelWithString:text];
  label->_plainText = [text copy];
  label.font = SPTheme.captionFont;
  [label applyCaptionStyle];
  return label;
}

- (void)applyCaptionStyle {
  self.attributedStringValue = [SPTheme ornamentedCaption:_plainText ?: self.stringValue
                                                     font:SPTheme.captionFont
                                                    color:SPTheme.headingText];
}

- (void)viewDidChangeEffectiveAppearance {
  [super viewDidChangeEffectiveAppearance];
  [self applyCaptionStyle];
}

@end

@implementation SPGradientBackdropView

- (BOOL)isOpaque { return YES; }

- (void)drawRect:(NSRect)dirtyRect {
  NSGradient *gradient = [[NSGradient alloc]
      initWithColors:@[
        SPTheme.windowGradientTop,    // top-left
        SPTheme.windowGradientMid,    // middle
        SPTheme.windowGradientBottom, // bottom-right
      ]
         atLocations:(CGFloat[]){0.0, 0.5, 1.0}
          colorSpace:NSColorSpace.sRGBColorSpace];
  // 315° = from the top-left corner toward the bottom-right.
  [gradient drawInRect:self.bounds angle:315];

  NSImage *grain = [NSImage imageNamed:@"ParchmentGrain"];
  if (grain) {
    // The tile is full-strength umber; the theme decides how much shows.
    CGFloat alpha =
        [SPTheme.grainTint colorUsingColorSpace:NSColorSpace.sRGBColorSpace].alphaComponent;
    [NSGraphicsContext saveGraphicsState];
    // Anchor the tile to the window, not to the dirty rect, so it never shifts.
    NSGraphicsContext.currentContext.patternPhase =
        [self convertPoint:NSZeroPoint toView:nil];
    CGContextSetAlpha(NSGraphicsContext.currentContext.CGContext, alpha);
    [[NSColor colorWithPatternImage:grain] setFill];
    NSRectFillUsingOperation(self.bounds, NSCompositingOperationSourceOver);
    [NSGraphicsContext restoreGraphicsState];
  }

  // The sidebar's band and the page frame with its title arch; the asset
  // catalog picks the lacquer variants in the dark appearance.
  CGFloat x = SPTheme.sidebarWidth;
  NSImage *band = [NSImage imageNamed:@"SidebarBand"];
  [band drawInRect:NSMakeRect(x - band.size.width, 0, band.size.width, NSHeight(self.bounds))];
  NSImage *page = [NSImage imageNamed:@"PageFrame"];
  [page drawInRect:NSMakeRect(x, 0, NSWidth(self.bounds) - x, NSHeight(self.bounds))];
}

- (void)viewDidChangeEffectiveAppearance {
  [super viewDidChangeEffectiveAppearance];
  self.needsDisplay = YES;
}

@end

@implementation SPOrnamentDividerView

- (NSSize)intrinsicContentSize {
  return NSMakeSize(NSViewNoIntrinsicMetric, 20.0);
}

- (void)drawRect:(NSRect)dirtyRect {
  NSImage *centre = [NSImage imageNamed:@"OrnamentDivider"];
  NSSize size = centre ? centre.size : NSMakeSize(0, 0);
  NSRect bounds = self.bounds;
  CGFloat midY = NSMidY(bounds);
  NSRect centreRect = NSMakeRect(NSMidX(bounds) - size.width / 2.0,
                                 midY - size.height / 2.0, size.width, size.height);
  NSColor *ochre = SPTheme.ornament;
  [[ochre colorWithAlphaComponent:0.7] setFill];
  CGFloat gap = 4.0;
  NSRectFill(NSMakeRect(NSMinX(bounds), midY + 1.0,
                        NSMinX(centreRect) - gap - NSMinX(bounds), 1.0));
  NSRectFill(NSMakeRect(NSMaxX(centreRect) + gap, midY + 1.0,
                        NSMaxX(bounds) - NSMaxX(centreRect) - gap, 1.0));
  [[ochre colorWithAlphaComponent:0.35] setFill];
  NSRectFill(NSMakeRect(NSMinX(bounds), midY - 2.0,
                        NSMinX(centreRect) - gap - NSMinX(bounds), 0.5));
  NSRectFill(NSMakeRect(NSMaxX(centreRect) + gap, midY - 2.0,
                        NSMaxX(bounds) - NSMaxX(centreRect) - gap, 0.5));
  if (centre) {
    // A template image: tint it by drawing the colour through its alpha.
    NSImage *tinted = [NSImage imageWithSize:size
                                     flipped:NO
                              drawingHandler:^BOOL(NSRect rect) {
                                [centre drawInRect:rect];
                                [ochre set];
                                NSRectFillUsingOperation(rect, NSCompositingOperationSourceAtop);
                                return YES;
                              }];
    [tinted drawInRect:centreRect];
  }
}

- (void)viewDidChangeEffectiveAppearance {
  [super viewDidChangeEffectiveAppearance];
  self.needsDisplay = YES;
}

@end

@implementation SPTailpieceView

- (NSSize)intrinsicContentSize {
  NSImage *tail = [NSImage imageNamed:@"Tailpiece"];
  return tail ? tail.size : NSMakeSize(240, 56);
}

- (void)drawRect:(NSRect)dirtyRect {
  NSImage *tail = [NSImage imageNamed:@"Tailpiece"];
  NSSize size = tail.size;
  [tail drawInRect:NSMakeRect(NSMidX(self.bounds) - size.width / 2, NSMidY(self.bounds) - size.height / 2,
                              size.width, size.height)];
}

- (void)viewDidChangeEffectiveAppearance {
  [super viewDidChangeEffectiveAppearance];
  self.needsDisplay = YES;
}

@end

#import <objc/runtime.h>

static void SPApplyButtonLayer(NSButton *button, BOOL primary, BOOL pressed) {
  BOOL enabled = button.enabled;
  [button.effectiveAppearance performAsCurrentDrawingAppearance:^{
    NSColor *fill = primary ? SPTheme.primaryButton : SPTheme.fieldBackground;
    if (pressed)
      fill = [fill blendedColorWithFraction:0.18 ofColor:NSColor.blackColor];
    // Disabled: a faint plate with a faint rule, so it does not read as pressable.
    button.layer.backgroundColor = [fill colorWithAlphaComponent:enabled ? 1.0 : 0.35].CGColor;
    button.layer.borderColor = [SPTheme.gold colorWithAlphaComponent:enabled ? 1.0 : 0.3].CGColor;
  }];
  button.layer.borderWidth = 1.0;
  button.layer.cornerRadius = 5.0;
  NSColor *text = primary ? SPTheme.primaryButtonText : SPTheme.label;
  if (!enabled)
    text = [SPTheme.secondaryLabel colorWithAlphaComponent:0.6];
  button.contentTintColor = text;
  // Icon-only buttons (+, −, arrows) keep their image; their title is for VoiceOver.
  if (button.image && button.imagePosition == NSImageOnly)
    return;
  NSMutableParagraphStyle *centre = [NSMutableParagraphStyle new];
  centre.alignment = NSTextAlignmentCenter;
  centre.lineBreakMode = NSLineBreakByTruncatingTail;
  // The book hand is wider than the system font the frames were sized for:
  // step the size down until the title fits on one line.
  NSString *title = button.title ?: @"";
  CGFloat room = NSWidth(button.frame) - 14.0 - (button.image ? button.image.size.width + 4.0 : 0.0);
  CGFloat size = 14.0;
  NSFont *font = [SPTheme bookHandFontOfSize:size];
  while (room > 0 && size > 11.0 &&
         [title sizeWithAttributes:@{NSFontAttributeName : font}].width > room) {
    size -= 0.5;
    font = [SPTheme bookHandFontOfSize:size];
  }
  NSAttributedString *styled = [[NSAttributedString alloc]
      initWithString:title
          attributes:@{
            NSFontAttributeName : font,
            NSForegroundColorAttributeName : text,
            NSParagraphStyleAttributeName : centre,
          }];
  // Set through the cell: -setAttributedTitle: on the button would come back
  // through our -setTitle: override.
  [(NSButtonCell *)button.cell setAttributedTitle:styled];
}

/// A push button drawn as a vellum plate edged in gold; the default button
/// (Return) is a cinnabar plate. Installed on existing buttons by SPApplyHouseStyle.
@interface SPHouseButton : NSButton
@end

@implementation SPHouseButton

- (BOOL)isPrimary {
  return [self.keyEquivalent isEqualToString:@"\r"];
}

// Without a bezel the button would hug its title; keep the plate's padding.
- (NSSize)intrinsicContentSize {
  NSSize size = super.intrinsicContentSize;
  return NSMakeSize(size.width + 22.0, MAX(size.height + 8.0, 28.0));
}

- (void)mouseDown:(NSEvent *)event {
  SPApplyButtonLayer(self, self.isPrimary, YES);
  [super mouseDown:event];
  SPApplyButtonLayer(self, self.isPrimary, NO);
}

- (void)setEnabled:(BOOL)enabled {
  [super setEnabled:enabled];
  SPApplyButtonLayer(self, self.isPrimary, NO);
}

// Code that relabels a button (Записать → Нажмите…) sets a plain title; restyle it.
- (void)setTitle:(NSString *)title {
  [super setTitle:title];
  SPApplyButtonLayer(self, self.isPrimary, NO);
}

- (void)viewDidChangeEffectiveAppearance {
  [super viewDidChangeEffectiveAppearance];
  SPApplyButtonLayer(self, self.isPrimary, NO);
}

@end

/// A pop-up drawn on the same vellum plate, keeping its own arrows.
@interface SPHousePopUpButton : NSPopUpButton
@end

@implementation SPHousePopUpButton

- (void)applyPlate {
  BOOL enabled = self.enabled;
  [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
    self.layer.backgroundColor = [SPTheme.fieldBackground colorWithAlphaComponent:enabled ? 1.0 : 0.35].CGColor;
    self.layer.borderColor = [SPTheme.gold colorWithAlphaComponent:enabled ? 1.0 : 0.3].CGColor;
  }];
}

- (void)setEnabled:(BOOL)enabled {
  [super setEnabled:enabled];
  [self applyPlate];
}

- (void)viewDidChangeEffectiveAppearance {
  [super viewDidChangeEffectiveAppearance];
  [self applyPlate];
}

@end

void SPApplyHouseStyle(NSView *root) {
  for (NSView *view in root.subviews) {
    if ([view isKindOfClass:NSPopUpButton.class]) {
      NSPopUpButton *popup = (NSPopUpButton *)view;
      if (popup.isBordered && !popup.pullsDown) {
        object_setClass(popup, SPHousePopUpButton.class);
        popup.bordered = NO;
        popup.wantsLayer = YES;
        popup.layer.cornerRadius = 5.0;
        popup.layer.borderWidth = 1.0;
        [popup viewDidChangeEffectiveAppearance];
      }
      continue;
    }
    if ([view isMemberOfClass:NSButton.class]) {
      NSButton *button = (NSButton *)view;
      if (button.isBordered && button.bezelStyle == NSBezelStyleRounded) {
        object_setClass(button, SPHouseButton.class);
        button.bordered = NO;
        button.wantsLayer = YES;
        SPApplyButtonLayer(button, [button.keyEquivalent isEqualToString:@"\r"], NO);
      }
      continue;
    }
    if ([view isKindOfClass:NSTextField.class]) {
      NSTextField *field = (NSTextField *)view;
      if (field.isEditable && field.isBezeled) {
        field.drawsBackground = YES;
        field.backgroundColor = SPTheme.fieldBackground;
      }
      continue;
    }
    SPApplyHouseStyle(view);
  }
}
