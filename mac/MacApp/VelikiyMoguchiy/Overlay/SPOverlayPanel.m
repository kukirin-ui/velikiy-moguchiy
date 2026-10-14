#import "SPOverlayPanel.h"
#import "SPTheme.h"
#import "velikiy_moguchiy_core.h"
#import <QuartzCore/QuartzCore.h>

// ── Geometry ──────────────────────────────────────────────
static const CGFloat kPillWidth  = 76.0;
static const CGFloat kPillHeight = 30.0;
static const CGFloat kDefaultBottomMargin = 10.0;
static const CGFloat kMaxBottomMargin = 180.0;
// A message widens the pill: the icon on the left, one line of text after it.
static const CGFloat kMessageMaxWidth = 420.0;
static const CGFloat kMessageEdgeInset = 12.0;
static const CGFloat kMessageGap = 8.0;
static const CGFloat kMessageRightInset = 16.0;
static const CGFloat kMessageFontSize = 12.5;

// Waveform bars
static const NSInteger kBarCount   = 6;
static const CGFloat   kBarWidth   = 3.0;
static const CGFloat   kBarSpacing = 3.0;
static const CGFloat   kBarMinH    = 3.0;
static const CGFloat   kBarMaxH    = 18.0;
static const NSInteger kMicLevelBuckets = 16;

// Processing dots
static const NSInteger kDotCount      = 3;
static const CGFloat   kDotBaseRadius = 2.5;
static const CGFloat   kDotSpacing    = 8.0;

// Animation
static const NSTimeInterval kAnimInterval      = 1.0 / 30.0;
static const NSTimeInterval kFadeInDuration    = 0.2;
static const NSTimeInterval kFadeOutDuration   = 0.3;
static const NSTimeInterval kPanelEntranceDuration = 0.22;
static const NSTimeInterval kPanelExitDuration = 0.18;
static const CGFloat kPanelEntranceLift = 10.0;
static const CGFloat kPanelExitDrop = 8.0;
static const CGFloat kBaseShadowOpacity = 0.11;
static const CGFloat kBaseShadowRadius = 4.0;
static const CGFloat kEntranceShadowOpacity = 0.17;
static const CGFloat kEntranceShadowRadius = 8.0;

// How long each result icon stays before the pill hides
static const NSTimeInterval kSuccessLingerDuration   = 0.6;
static const NSTimeInterval kClipboardLingerDuration = 1.2;
static const NSTimeInterval kCancelledLingerDuration = 0.6;
static const NSTimeInterval kErrorLingerDuration     = 1.5;
static const NSTimeInterval kModeLetterLingerDuration = 1.2;
// A message stays long enough to be read: a base plus a little per character.
static const NSTimeInterval kMessageMinLinger = 3.0;
static const NSTimeInterval kMessageMaxLinger = 7.0;
static const NSTimeInterval kMessageLingerPerChar = 0.06;

// An ink plate edged in ochre, with parchment-coloured marks: the overlay is
// the same old book page as the Settings window, in its dark appearance.
static NSColor *SPOverlaySurfaceTintColor(void) {
    return [NSColor colorWithSRGBRed:0x0E / 255.0 green:0x0A / 255.0 blue:0x08 / 255.0 alpha:0.96];
}

static NSColor *SPOverlayInkColor(void) {
    return [NSColor colorWithSRGBRed:0xE8 / 255.0 green:0xDC / 255.0 blue:0xC8 / 255.0 alpha:1.0];
}

static NSColor *SPOverlayOchreColor(void) {
    return [NSColor colorWithSRGBRed:0xD9 / 255.0 green:0xB8 / 255.0 blue:0x65 / 255.0 alpha:1.0];
}

static NSColor *SPOverlayCinnabarColor(void) {
    return [NSColor colorWithSRGBRed:0xD9 / 255.0 green:0x82 / 255.0 blue:0x6C / 255.0 alpha:1.0];
}

static NSColor *SPOverlayShadowColor(void) {
    return [NSColor colorWithSRGBRed:0.04 green:0.035 blue:0.015 alpha:1.0];
}

static CGFloat SPOverlayClampBottomMargin(CGFloat bottomMargin) {
    return fmin(fmax(bottomMargin, 0.0), kMaxBottomMargin);
}

static CGFloat SPOverlayConfigCGFloat(const char *keyPath, CGFloat fallback) {
    char *raw = sp_config_get(keyPath);
    if (!raw) return fallback;

    NSString *value = [NSString stringWithUTF8String:raw];
    sp_core_free_string(raw);
    if (value.length == 0) return fallback;

    NSScanner *scanner = [NSScanner scannerWithString:value];
    double parsedValue = 0.0;
    if (![scanner scanDouble:&parsedValue] || !scanner.isAtEnd) {
        return fallback;
    }

    return parsedValue;
}

static BOOL SPOverlayShouldReduceMotion(void) {
    if (@available(macOS 10.15, *)) {
        return NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
    }
    return NO;
}

static NSRect SPOverlayPresentationStartFrame(NSRect finalFrame) {
    CGFloat insetX = fmin(10.0, floor(finalFrame.size.width * 0.018));
    CGFloat insetY = fmin(6.0, floor(finalFrame.size.height * 0.08));
    NSRect startFrame = NSInsetRect(finalFrame, insetX, insetY);
    startFrame.origin.y -= kPanelEntranceLift;
    return startFrame;
}

static NSRect SPOverlayDismissalEndFrame(NSRect currentFrame) {
    CGFloat insetX = fmin(8.0, floor(currentFrame.size.width * 0.012));
    CGFloat insetY = fmin(5.0, floor(currentFrame.size.height * 0.06));
    NSRect endFrame = NSInsetRect(currentFrame, insetX, insetY);
    endFrame.origin.y -= kPanelExitDrop;
    return endFrame;
}

// ── Animation mode ───────────────────────────────────────
typedef NS_ENUM(NSInteger, SPOverlayMode) {
    SPOverlayModeNone,
    SPOverlayModeWaveform,
    SPOverlayModeProcessing,
    SPOverlayModeSuccess,
    SPOverlayModeClipboard,
    SPOverlayModeCancelled,
    SPOverlayModeError,
    SPOverlayModeLetter,
    SPOverlayModeNotice,
};

/// Width the icon of `mode` takes on the left of a message.
static CGFloat SPOverlayIconSlotWidth(SPOverlayMode mode) {
    if (mode == SPOverlayModeWaveform) return 6 * 3.0 + 5 * 3.0;
    return 18.0;
}

static NSAttributedString *SPOverlayMessageString(NSString *text) {
    NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
    paragraph.lineBreakMode = NSLineBreakByTruncatingTail;
    return [[NSAttributedString alloc] initWithString:text
                                           attributes:@{
        NSFontAttributeName : [NSFont systemFontOfSize:kMessageFontSize weight:NSFontWeightMedium],
        NSForegroundColorAttributeName : SPOverlayInkColor(),
        NSParagraphStyleAttributeName : paragraph,
    }];
}

/// The pill's width for `message` next to the icon of `mode`; the compact width without one.
static CGFloat SPOverlayWidthForMessage(NSString *message, SPOverlayMode mode, CGFloat screenWidth) {
    if (message.length == 0) return kPillWidth;
    CGFloat textWidth = ceil(SPOverlayMessageString(message).size.width);
    CGFloat width = kMessageEdgeInset + SPOverlayIconSlotWidth(mode) + kMessageGap + textWidth + kMessageRightInset;
    return fmax(kPillWidth, fmin(width, fmin(kMessageMaxWidth, screenWidth - 32.0)));
}

// ── Click-aware effect view ──────────────────────────────

@interface SPClickEffectView : NSVisualEffectView
@property (nonatomic, copy) void (^clickHandler)(void);
@end

@implementation SPClickEffectView

- (void)mouseDown:(NSEvent *)event {
    if (self.clickHandler) {
        self.clickHandler();
        return;
    }
    [super mouseDown:event];
}

@end

// ── Pill content ─────────────────────────────────────────

@interface SPOverlayContentView : NSView
@property (nonatomic, assign) SPOverlayMode mode;
@property (nonatomic, assign) NSInteger     tick;  // animation counter
@property (nonatomic, copy)   NSString     *letter; // SPOverlayModeLetter
/// One line after the icon; nil keeps the compact pill.
@property (nonatomic, copy)   NSString     *message;
@property (nonatomic, copy)   NSString     *symbolName; // SPOverlayModeNotice
/// Zero the smoothed bar levels so a new recording does not start from the
/// previous one's tail.
- (void)resetLevels;
@end

@implementation SPOverlayContentView {
    float _smoothedLevels[16];
}

- (BOOL)isFlipped { return NO; }

- (void)resetLevels {
    memset(_smoothedLevels, 0, sizeof(_smoothedLevels));
}

- (void)drawRect:(NSRect)dirtyRect {
    NSRect bounds = self.bounds;

    [SPOverlaySurfaceTintColor() setFill];
    [NSBezierPath fillRect:bounds];

    CGFloat radius = self.layer.cornerRadius;
    NSBezierPath *rule = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bounds, 1.5, 1.5)
                                                         xRadius:MAX(radius - 1.5, 0)
                                                         yRadius:MAX(radius - 1.5, 0)];
    rule.lineWidth = 1.2;
    [SPOverlayOchreColor() setStroke];
    [rule stroke];
    NSBezierPath *hair = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bounds, 3.6, 3.6)
                                                         xRadius:MAX(radius - 3.6, 0)
                                                         yRadius:MAX(radius - 3.6, 0)];
    hair.lineWidth = 0.6;
    [[SPOverlayCinnabarColor() colorWithAlphaComponent:0.8] setStroke];
    [hair stroke];
    // gilded studs at the two ends, like the clasps of a book
    [SPOverlayOchreColor() setFill];
    CGFloat studY = NSMidY(bounds);
    for (int end = 0; end < 2; end++) {
        CGFloat cx = end ? NSMaxX(bounds) - 7.5 : NSMinX(bounds) + 7.5;
        NSBezierPath *stud = [NSBezierPath bezierPath];
        [stud moveToPoint:NSMakePoint(cx, studY + 3.2)];
        [stud lineToPoint:NSMakePoint(cx + 2.4, studY)];
        [stud lineToPoint:NSMakePoint(cx, studY - 3.2)];
        [stud lineToPoint:NSMakePoint(cx - 2.4, studY)];
        [stud closePath];
        [stud fill];
    }

    CGFloat centerX = NSMidX(bounds);
    CGFloat centerY = NSMidY(bounds);
    if (self.message.length > 0) {
        CGFloat slot = SPOverlayIconSlotWidth(self.mode);
        centerX = NSMinX(bounds) + kMessageEdgeInset + slot / 2.0;
        CGFloat textX = NSMinX(bounds) + kMessageEdgeInset + slot + kMessageGap;
        NSRect textRect = NSMakeRect(textX, 0, NSMaxX(bounds) - kMessageRightInset - textX, NSHeight(bounds));
        NSAttributedString *line = SPOverlayMessageString(self.message);
        NSSize size = line.size;
        textRect.origin.y = floor(centerY - size.height / 2.0);
        textRect.size.height = ceil(size.height);
        [line drawWithRect:textRect
                   options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine];
    }

    switch (self.mode) {
        case SPOverlayModeWaveform:
            [self drawWaveformAtX:centerX centerY:centerY];
            break;
        case SPOverlayModeProcessing:
            [self drawDotsAtX:centerX centerY:centerY];
            break;
        case SPOverlayModeSuccess:
            [self drawCheckmarkAtX:centerX centerY:centerY];
            break;
        case SPOverlayModeClipboard:
            [self drawClipboardAtX:centerX centerY:centerY];
            break;
        case SPOverlayModeCancelled:
            [self drawCrossAtX:centerX centerY:centerY color:SPOverlayInkColor()];
            break;
        case SPOverlayModeError:
            [self drawCrossAtX:centerX centerY:centerY
                         color:SPOverlayCinnabarColor()];
            break;
        case SPOverlayModeLetter:
            [self drawLetterAtX:centerX centerY:centerY];
            break;
        case SPOverlayModeNotice:
            [self drawSymbol:self.symbolName atX:centerX centerY:centerY color:SPOverlayOchreColor()];
            break;
        default:
            break;
    }
}

#pragma mark - Waveform (recording)

- (void)drawWaveformAtX:(CGFloat)centerX centerY:(CGFloat)centerY {
    CGFloat totalW = kBarCount * kBarWidth + (kBarCount - 1) * kBarSpacing;
    CGFloat startX = centerX - totalW / 2.0;

    // Exponential smoothing and height curve from Handy's RecordingOverlay.tsx.
    float levels[kMicLevelBuckets] = {0};
    sp_core_get_mic_levels(levels, kMicLevelBuckets);
    for (NSInteger i = 0; i < kBarCount; i++) {
        _smoothedLevels[i] = _smoothedLevels[i] * 0.7f + levels[i] * 0.3f;
    }

    for (NSInteger i = 0; i < kBarCount; i++) {
        // Ochre at the edges, parchment toward the middle, like gilt on a page.
        CGFloat edge = fabs((CGFloat)i - (kBarCount - 1) / 2.0) / ((kBarCount - 1) / 2.0);
        [[SPOverlayInkColor() blendedColorWithFraction:edge * 0.8 ofColor:SPOverlayOchreColor()] setFill];
        CGFloat t = (CGFloat)powf(_smoothedLevels[i], 0.7f);
        CGFloat h = fmin(kBarMaxH, kBarMinH + t * (kBarMaxH - kBarMinH));
        CGFloat x = startX + i * (kBarWidth + kBarSpacing);
        CGFloat y = centerY - h / 2.0;
        NSBezierPath *bar = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x, y, kBarWidth, h)
                                                             xRadius:kBarWidth / 2.0
                                                             yRadius:kBarWidth / 2.0];
        [bar fill];
    }
}

#pragma mark - Processing dots

- (void)drawDotsAtX:(CGFloat)centerX centerY:(CGFloat)centerY {
    CGFloat totalW = (kDotCount - 1) * kDotSpacing;
    CGFloat startX = centerX - totalW / 2.0;

    for (NSInteger i = 0; i < kDotCount; i++) {
        double phase = (double)(self.tick) * 0.15 - (double)i * 0.9;
        CGFloat bounce = (CGFloat)fmax(0.0, sin(phase));
        CGFloat r = kDotBaseRadius + bounce * 1.5;
        CGFloat alpha = 0.35 + 0.65 * bounce;
        CGFloat offsetY = bounce * 3.0;

        [[SPOverlayOchreColor() colorWithAlphaComponent:alpha] setFill];
        CGFloat x = startX + i * kDotSpacing;
        NSRect dotRect = NSMakeRect(x - r, centerY - r + offsetY, r * 2, r * 2);
        [[NSBezierPath bezierPathWithOvalInRect:dotRect] fill];
    }
}

#pragma mark - Checkmark (delivered)

- (void)drawCheckmarkAtX:(CGFloat)centerX centerY:(CGFloat)centerY {
    CGFloat progress = fmin(1.0, (CGFloat)self.tick / 6.0);

    NSPoint p0 = NSMakePoint(centerX - 6, centerY + 1);
    NSPoint p1 = NSMakePoint(centerX - 1.5, centerY - 4);
    NSPoint p2 = NSMakePoint(centerX + 7, centerY + 5);

    NSBezierPath *path = [NSBezierPath bezierPath];
    path.lineWidth = 2.0;
    path.lineCapStyle = NSLineCapStyleRound;
    path.lineJoinStyle = NSLineJoinStyleRound;

    if (progress <= 0.4) {
        CGFloat t = progress / 0.4;
        NSPoint end = NSMakePoint(p0.x + (p1.x - p0.x) * t, p0.y + (p1.y - p0.y) * t);
        [path moveToPoint:p0];
        [path lineToPoint:end];
    } else {
        CGFloat t = (progress - 0.4) / 0.6;
        NSPoint end = NSMakePoint(p1.x + (p2.x - p1.x) * t, p1.y + (p2.y - p1.y) * t);
        [path moveToPoint:p0];
        [path lineToPoint:p1];
        [path lineToPoint:end];
    }

    [SPOverlayInkColor() setStroke];
    [path stroke];
}

#pragma mark - Clipboard (copied, not pasted)

- (void)drawClipboardAtX:(CGFloat)centerX centerY:(CGFloat)centerY {
    if (![self drawSymbol:@"doc.on.clipboard" atX:centerX centerY:centerY color:SPOverlayInkColor()]) {
        NSRect board = NSMakeRect(centerX - 6, centerY - 8, 12, 16);
        NSBezierPath *outline = [NSBezierPath bezierPathWithRoundedRect:board xRadius:2.5 yRadius:2.5];
        outline.lineWidth = 1.8;
        [SPOverlayInkColor() setStroke];
        [outline stroke];
    }
}

/// Draws an SF Symbol centred on the point; NO when the system has no such symbol.
- (BOOL)drawSymbol:(NSString *)name atX:(CGFloat)centerX centerY:(CGFloat)centerY color:(NSColor *)color {
    NSImage *symbol = nil;
    if (@available(macOS 11.0, *)) {
        if (name.length > 0) symbol = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
        symbol = [symbol imageWithSymbolConfiguration:
                     [NSImageSymbolConfiguration configurationWithPointSize:15.0
                                                                     weight:NSFontWeightMedium]];
    }
    if (!symbol) return NO;

    // Symbols are template images; fill them with the ink instead of the default black.
    NSImage *tinted = [NSImage imageWithSize:symbol.size
                                     flipped:NO
                              drawingHandler:^BOOL(NSRect dstRect) {
        [symbol drawInRect:dstRect];
        [color set];
        NSRectFillUsingOperation(dstRect, NSCompositingOperationSourceAtop);
        return YES;
    }];
    [tinted drawAtPoint:NSMakePoint(centerX - tinted.size.width / 2.0, centerY - tinted.size.height / 2.0)
               fromRect:NSZeroRect
              operation:NSCompositingOperationSourceOver
               fraction:1.0];
    return YES;
}

#pragma mark - Letter (text mode)

- (void)drawLetterAtX:(CGFloat)centerX centerY:(CGFloat)centerY {
    if (self.letter.length == 0) return;
    NSDictionary *attributes = @{
        NSFontAttributeName : [SPTheme bookHandFontOfSize:20.0],
        NSForegroundColorAttributeName : SPOverlayInkColor(),
    };
    NSSize size = [self.letter sizeWithAttributes:attributes];
    [self.letter drawAtPoint:NSMakePoint(centerX - size.width / 2.0, centerY - size.height / 2.0)
              withAttributes:attributes];
}

#pragma mark - Cross (cancelled / error)

- (void)drawCrossAtX:(CGFloat)centerX centerY:(CGFloat)centerY color:(NSColor *)color {
    CGFloat arm = 5.0;

    NSBezierPath *path = [NSBezierPath bezierPath];
    path.lineWidth = 2.0;
    path.lineCapStyle = NSLineCapStyleRound;

    [path moveToPoint:NSMakePoint(centerX - arm, centerY - arm)];
    [path lineToPoint:NSMakePoint(centerX + arm, centerY + arm)];
    [path moveToPoint:NSMakePoint(centerX + arm, centerY - arm)];
    [path lineToPoint:NSMakePoint(centerX - arm, centerY + arm)];

    [[color colorWithAlphaComponent:0.95] setStroke];
    [path stroke];
}

@end

// ── Main overlay controller ──────────────────────────────

@interface SPOverlayPanel ()

@property (nonatomic, strong) NSPanel *panel;
@property (nonatomic, strong) SPClickEffectView *effectView;
@property (nonatomic, strong) SPOverlayContentView *contentView;
@property (nonatomic, strong) NSTimer *animationTimer;
@property (nonatomic, strong) NSTimer *lingerTimer;
@property (nonatomic, copy)   NSString *currentState;
@property (nonatomic, assign) CGFloat bottomMargin;
@property (nonatomic, assign) CGFloat configuredBottomMargin;
@property (nonatomic, assign, getter=isPreviewActive) BOOL previewActive;
@property (nonatomic, assign) BOOL rawAsrFallbackClickEnabled;
@property (nonatomic, assign) CGFloat pillWidth;

@end

@implementation SPOverlayPanel

- (instancetype)init {
    self = [super init];
    if (self) {
        _currentState = @"idle";
        _bottomMargin = kDefaultBottomMargin;
        _configuredBottomMargin = kDefaultBottomMargin;
        _pillWidth = kPillWidth;
        [self setupPanel];
        [self reloadAppearanceFromConfig];
        [[NSWorkspace sharedWorkspace].notificationCenter
            addObserver:self
               selector:@selector(activeSpaceDidChange:)
                   name:NSWorkspaceActiveSpaceDidChangeNotification
                 object:nil];
    }
    return self;
}

#pragma mark - Spaces

/// Order a panel in on the Space the user is looking at.
///
/// The panel is CanJoinAllSpaces, but when a Space switch happens while it
/// is on screen (e.g. lingering after a paste, then the user swipes to a
/// full-screen app), WindowServer can leave it pinned to the previous Space.
/// orderFrontRegardless alone keeps it there — ordered in, opaque, and
/// invisible — until the user switches windows. Ordering it out first makes
/// the next order-in attach it to the active Space again.
static void SPOrderFrontOnActiveSpace(NSWindow *window) {
    if (!window) return;
    // A hidden app hides every window, this panel included, and a menu bar app
    // has no Dock icon to unhide it from: launched with `open -j`, or hidden
    // with ⌘H from the Settings window, it would dictate with no pill at all.
    if (NSApp.isHidden) {
        [NSApp unhideWithoutActivation];
    }
    if (window.isVisible && !window.isOnActiveSpace) {
        NSLog(@"[VelikiyMoguchiy] Overlay window was stranded on another Space; re-attaching to the active Space");
        [window orderOut:nil];
    }
    [window orderFrontRegardless];
}

- (void)activeSpaceDidChange:(NSNotification *)notification {
    if (self.panel.isVisible && self.panel.alphaValue > 0.01) {
        SPOrderFrontOnActiveSpace(self.panel);
    }
}

- (CGFloat)overlayCornerRadius {
    return kPillHeight / 2.0;
}

- (void)resetMotionPresentationState {
    [self.contentView.layer removeAnimationForKey:@"overlayContentEntrance"];
    [self.contentView.layer removeAnimationForKey:@"overlayContentExit"];
    [self.effectView.layer removeAnimationForKey:@"overlayShadowEntrance"];
    [self.effectView.layer removeAnimationForKey:@"overlayShadowExit"];
    self.contentView.layer.transform = CATransform3DIdentity;
    self.contentView.layer.opacity = 1.0;
    self.effectView.layer.shadowOpacity = kBaseShadowOpacity;
    self.effectView.layer.shadowRadius = kBaseShadowRadius;
}

- (void)animateContentLayerFromTransform:(CATransform3D)fromTransform
                             toTransform:(CATransform3D)toTransform
                             fromOpacity:(CGFloat)fromOpacity
                               toOpacity:(CGFloat)toOpacity
                                duration:(CFTimeInterval)duration
                               animation:(NSString *)animationKey {
    if (!self.contentView.layer) return;

    [self.contentView.layer removeAnimationForKey:animationKey];
    self.contentView.layer.transform = toTransform;
    self.contentView.layer.opacity = toOpacity;

    CABasicAnimation *transformAnimation = [CABasicAnimation animationWithKeyPath:@"transform"];
    transformAnimation.fromValue = [NSValue valueWithCATransform3D:fromTransform];
    transformAnimation.toValue = [NSValue valueWithCATransform3D:toTransform];

    CABasicAnimation *opacityAnimation = [CABasicAnimation animationWithKeyPath:@"opacity"];
    opacityAnimation.fromValue = @(fromOpacity);
    opacityAnimation.toValue = @(toOpacity);

    CAAnimationGroup *group = [CAAnimationGroup animation];
    group.animations = @[transformAnimation, opacityAnimation];
    group.duration = duration;
    group.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [self.contentView.layer addAnimation:group forKey:animationKey];
}

- (void)animateShadowFromOpacity:(CGFloat)fromOpacity
                       toOpacity:(CGFloat)toOpacity
                      fromRadius:(CGFloat)fromRadius
                        toRadius:(CGFloat)toRadius
                        duration:(CFTimeInterval)duration
                       animation:(NSString *)animationKey {
    if (!self.effectView.layer) return;

    [self.effectView.layer removeAnimationForKey:animationKey];
    self.effectView.layer.shadowOpacity = toOpacity;
    self.effectView.layer.shadowRadius = toRadius;

    CABasicAnimation *opacityAnimation = [CABasicAnimation animationWithKeyPath:@"shadowOpacity"];
    opacityAnimation.fromValue = @(fromOpacity);
    opacityAnimation.toValue = @(toOpacity);

    CABasicAnimation *radiusAnimation = [CABasicAnimation animationWithKeyPath:@"shadowRadius"];
    radiusAnimation.fromValue = @(fromRadius);
    radiusAnimation.toValue = @(toRadius);

    CAAnimationGroup *group = [CAAnimationGroup animation];
    group.animations = @[opacityAnimation, radiusAnimation];
    group.duration = duration;
    group.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [self.effectView.layer addAnimation:group forKey:animationKey];
}

- (void)updateMainPanelMask {
    if (!self.effectView) return;

    CGFloat cornerRadius = [self overlayCornerRadius];
    NSImage *mask = [NSImage imageWithSize:NSMakeSize(cornerRadius * 2 + 1, kPillHeight)
                                   flipped:NO
                            drawingHandler:^BOOL(NSRect dstRect) {
        [[NSColor blackColor] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:dstRect
                                         xRadius:cornerRadius
                                         yRadius:cornerRadius] fill];
        return YES;
    }];
    mask.capInsets = NSEdgeInsetsMake(cornerRadius, cornerRadius, cornerRadius, cornerRadius);
    mask.resizingMode = NSImageResizingModeStretch;
    self.effectView.maskImage = mask;
}

- (void)setupPanel {
    NSRect rect = NSMakeRect(0, 0, kPillWidth, kPillHeight);

    NSPanel *panel = [[NSPanel alloc] initWithContentRect:rect
                                                 styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                                   backing:NSBackingStoreBuffered
                                                     defer:YES];
    panel.level = NSStatusWindowLevel;
    panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                               NSWindowCollectionBehaviorStationary |
                               NSWindowCollectionBehaviorFullScreenAuxiliary;
    panel.backgroundColor = [NSColor clearColor];
    panel.opaque = NO;
    panel.hasShadow = NO;
    panel.ignoresMouseEvents = YES;
    panel.hidesOnDeactivate = NO;
    panel.alphaValue = 0.0;

    // Visual effect background (HUD material for contrast on any desktop)
    SPClickEffectView *effectView = [[SPClickEffectView alloc] initWithFrame:rect];
    effectView.material     = NSVisualEffectMaterialHUDWindow;
    effectView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    effectView.state        = NSVisualEffectStateActive;
    effectView.appearance   = [NSAppearance appearanceNamed:NSAppearanceNameVibrantDark];
    effectView.wantsLayer   = YES;
    effectView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    __weak typeof(self) weakSelf = self;
    effectView.clickHandler = ^{
        [weakSelf handleMainPanelClick];
    };

    // Light glow shadow (visible on dark backgrounds)
    effectView.layer.shadowColor   = SPOverlayShadowColor().CGColor;
    effectView.layer.shadowOpacity = kBaseShadowOpacity;
    effectView.layer.shadowRadius  = kBaseShadowRadius;
    effectView.layer.shadowOffset  = CGSizeMake(0, -1.0);

    panel.contentView = effectView;
    self.effectView = effectView;

    // Content drawn on top of the effect view
    self.contentView = [[SPOverlayContentView alloc] initWithFrame:rect];
    self.contentView.wantsLayer = YES;
    self.contentView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.contentView.layer.cornerRadius = [self overlayCornerRadius];
    self.contentView.layer.masksToBounds = YES;
    [effectView addSubview:self.contentView];
    [self updateMainPanelMask];

    self.panel = panel;
}

- (void)setMainPanelInteractive:(BOOL)interactive {
    self.panel.ignoresMouseEvents = !interactive;
}

- (void)handleMainPanelClick {
    if (!self.rawAsrFallbackClickEnabled) return;
    if ([self.delegate respondsToSelector:@selector(overlayPanelDidRequestRawAsrFallback:)]) {
        [self.delegate overlayPanelDidRequestRawAsrFallback:self];
    }
}

- (void)clearLingerTimer {
    [self.lingerTimer invalidate];
    self.lingerTimer = nil;
}

- (void)dismissToIdle {
    [self clearLingerTimer];
    [self setRawAsrFallbackClickEnabled:NO];
    self.currentState = @"idle";
    self.contentView.message = nil;
    [self hide];

    if ([self.delegate respondsToSelector:@selector(overlayPanelDidDismiss:)]) {
        [self.delegate overlayPanelDidDismiss:self];
    }
}

- (void)scheduleDismissAfter:(NSTimeInterval)duration {
    [self.lingerTimer invalidate];

    __weak typeof(self) weakSelf = self;
    self.lingerTimer = [NSTimer scheduledTimerWithTimeInterval:duration
                                                       repeats:NO
                                                         block:^(NSTimer *timer) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.lingerTimer = nil;
        [strongSelf dismissToIdle];
    }];
}

/// How long the icon of the current mode stays on screen before the pill hides.
- (NSTimeInterval)lingerDurationForCurrentMode {
    if (self.contentView.message.length > 0) {
        return fmin(kMessageMaxLinger,
                    fmax(kMessageMinLinger, self.contentView.message.length * kMessageLingerPerChar + 1.5));
    }
    switch (self.contentView.mode) {
        case SPOverlayModeClipboard: return kClipboardLingerDuration;
        case SPOverlayModeCancelled: return kCancelledLingerDuration;
        case SPOverlayModeError:     return kErrorLingerDuration;
        case SPOverlayModeLetter:    return kModeLetterLingerDuration;
        default:                     return kSuccessLingerDuration;
    }
}

#pragma mark - Public

- (BOOL)isShowingMessage {
    return self.contentView.message.length > 0 && [self.currentState isEqualToString:@"message"];
}

/// Puts `message` (or nothing) after the icon and resizes the pill to fit.
- (void)applyMessage:(NSString *)message {
    self.contentView.message = message.length > 0 ? message : nil;
    NSRect visible = (self.screenOverride ?: [NSScreen mainScreen]).visibleFrame;
    self.pillWidth = SPOverlayWidthForMessage(self.contentView.message, self.contentView.mode, NSWidth(visible));
}

- (void)showMessage:(NSString *)text icon:(SPOverlayMessageIcon)icon {
    if (text.length == 0) return;
    if (self.isPreviewActive) [self restoreConfiguredAppearanceIfNeeded];
    [self clearLingerTimer];
    [self setRawAsrFallbackClickEnabled:NO];
    [self stopAnimation];
    self.currentState = @"message";
    switch (icon) {
        case SPOverlayMessageIconError:
            self.contentView.mode = SPOverlayModeError;
            break;
        case SPOverlayMessageIconClipboard:
            self.contentView.mode = SPOverlayModeClipboard;
            break;
        case SPOverlayMessageIconSuccess:
            self.contentView.mode = SPOverlayModeSuccess;
            break;
        case SPOverlayMessageIconNoSpeech:
            self.contentView.mode = SPOverlayModeNotice;
            self.contentView.symbolName = @"ear";
            break;
        case SPOverlayMessageIconNotice:
            self.contentView.mode = SPOverlayModeNotice;
            self.contentView.symbolName = @"exclamationmark.circle";
            break;
    }
    [self applyMessage:text];
    self.contentView.tick = 0;
    [self positionPanel];
    [self.contentView setNeedsDisplay:YES];
    [self show];
    if (icon == SPOverlayMessageIconSuccess) [self startAnimation];
    [self scheduleDismissAfter:[self lingerDurationForCurrentMode]];
}

- (void)setRecordingHint:(NSString *)hint {
    if (![self.currentState hasPrefix:@"recording"] || self.contentView.mode != SPOverlayModeWaveform) return;
    NSString *current = self.contentView.message ?: @"";
    if ([current isEqualToString:hint ?: @""]) return;
    [self applyMessage:hint];
    [self positionPanel];
    [self.contentView setNeedsDisplay:YES];
}

- (void)updateState:(NSString *)state {
    // The session ending quietly must not cut short a message being read.
    if (self.isShowingMessage &&
        ([state isEqualToString:@"idle"] || [state isEqualToString:@"completed"])) {
        return;
    }
    BOOL isPreviewState = [state hasSuffix:@"_preview"];
    if (self.isPreviewActive && !isPreviewState) {
        [self restoreConfiguredAppearanceIfNeeded];
    }

    [self clearLingerTimer];
    [self setRawAsrFallbackClickEnabled:NO];

    self.currentState = state;
    [self stopAnimation];

    if ([state isEqualToString:@"idle"] || [state isEqualToString:@"completed"]) {
        self.contentView.message = nil;
        [self hide];
        return;
    }

    SPOverlayMode mode;
    if ([state hasPrefix:@"recording"]) {
        mode = SPOverlayModeWaveform;
    } else if ([state hasPrefix:@"preparing_paste"] || [state isEqualToString:@"pasting"]) {
        mode = SPOverlayModeSuccess;
    } else if ([state isEqualToString:@"cancelled"]) {
        mode = SPOverlayModeCancelled;
    } else if ([state isEqualToString:@"error"] || [state isEqualToString:@"failed"]) {
        mode = SPOverlayModeError;
    } else {
        mode = SPOverlayModeProcessing;
    }

    if (mode == SPOverlayModeWaveform) {
        [(SPOverlayContentView *)self.contentView resetLevels];
    }
    self.contentView.mode = mode;
    [self applyMessage:nil];
    self.contentView.tick = 0;
    [self positionPanel];
    [self.contentView setNeedsDisplay:YES];
    [self show];
    [self startAnimation];

    if (mode == SPOverlayModeCancelled || mode == SPOverlayModeError) {
        [self scheduleDismissAfter:[self lingerDurationForCurrentMode]];
    }
}

/// The pill shows no text; transcripts and errors are delivered elsewhere
/// (the focused field, the clipboard, notifications).
- (void)updateInterimText:(NSString *)text {
}

- (void)updateDisplayText:(NSString *)text {
}

- (void)setRawAsrFallbackClickEnabled:(BOOL)enabled {
    _rawAsrFallbackClickEnabled = enabled;
    [self setMainPanelInteractive:enabled];
}

- (void)showModeIndicator:(NSString *)letter {
    if (letter.length == 0) return;
    [self clearLingerTimer];
    [self setRawAsrFallbackClickEnabled:NO];
    [self stopAnimation];
    self.currentState = @"mode_indicator";
    self.contentView.letter = letter;
    self.contentView.mode = SPOverlayModeLetter;
    [self applyMessage:nil];
    self.contentView.tick = 0;
    [self positionPanel];
    [self.contentView setNeedsDisplay:YES];
    [self show];
    [self scheduleDismissAfter:kModeLetterLingerDuration];
}

/// Every badge means the text reached the clipboard but not the field.
- (void)showResultBadge:(NSString *)badgeText {
    if (badgeText.length == 0) return;
    [self stopAnimation];
    self.contentView.mode = SPOverlayModeClipboard;
    [self applyMessage:nil];
    [self positionPanel];
    self.contentView.tick = 0;
    [self.contentView setNeedsDisplay:YES];
}

- (void)reloadAppearanceFromConfig {
    self.configuredBottomMargin = SPOverlayClampBottomMargin(
        SPOverlayConfigCGFloat("overlay.bottom_margin", kDefaultBottomMargin));

    if (!self.isPreviewActive) {
        self.bottomMargin = self.configuredBottomMargin;
        [self positionPanel];
    }
}

- (void)restoreConfiguredAppearanceIfNeeded {
    if (!self.isPreviewActive) return;
    self.previewActive = NO;
    self.bottomMargin = self.configuredBottomMargin;
}

/// Settings preview of the pill position; the text and typography arguments
/// belong to the old text overlay and are ignored.
- (void)showPreviewWithText:(NSString *)text
                   fontSize:(CGFloat)fontSize
                 fontFamily:(NSString *)fontFamily
               bottomMargin:(CGFloat)bottomMargin
          limitVisibleLines:(BOOL)limitVisibleLines
            maxVisibleLines:(NSInteger)maxVisibleLines {
    if (!self.isPreviewActive &&
        self.currentState.length > 0 &&
        ![self.currentState isEqualToString:@"idle"] &&
        ![self.currentState isEqualToString:@"completed"]) {
        return;
    }

    self.previewActive = YES;
    self.bottomMargin = SPOverlayClampBottomMargin(bottomMargin);
    [self updateState:@"recording_preview"];
}

- (void)hidePreview {
    if (!self.isPreviewActive) return;

    [self clearLingerTimer];
    [self setMainPanelInteractive:NO];
    [self restoreConfiguredAppearanceIfNeeded];
    self.currentState = @"idle";
    [self hide];
}

- (void)lingerAndDismiss {
    [self lingerAndDismissWithDuration:0];
}

/// The duration is fixed by the icon on screen; callers' durations were sized
/// for transcript text and are ignored.
- (void)lingerAndDismissWithDuration:(NSTimeInterval)duration {
    [self clearLingerTimer];
    // Keep the pill click-through during linger — it should not block
    // clicks on the app underneath.
    [self setMainPanelInteractive:NO];
    [self scheduleDismissAfter:[self lingerDurationForCurrentMode]];
}

#pragma mark - Template buttons (removed)

- (void)showTemplateButtons:(NSArray<NSDictionary *> *)templates {
    [self lingerAndDismiss];
}

- (void)showTemplateButtons:(NSArray<NSDictionary *> *)templates lingerDuration:(NSTimeInterval)lingerDuration {
    [self lingerAndDismiss];
}

- (void)hideTemplateButtons {
}

- (BOOL)handleNumberKey:(NSInteger)number {
    return NO;
}

#pragma mark - Layout

- (void)positionPanel {
    NSRect visible = (self.screenOverride ?: [NSScreen mainScreen]).visibleFrame;
    NSRect frame = NSMakeRect(round(NSMidX(visible) - self.pillWidth / 2.0),
                              NSMinY(visible) + self.bottomMargin,
                              self.pillWidth,
                              kPillHeight);
    [self.panel setFrame:frame display:YES];
}

#pragma mark - Show / Hide

- (void)show {
    BOOL wasVisible = self.panel.isVisible && self.panel.alphaValue > 0.01;
    [self resetMotionPresentationState];
    SPOrderFrontOnActiveSpace(self.panel);

    if (wasVisible || SPOverlayShouldReduceMotion()) {
        if (!wasVisible) {
            self.panel.alphaValue = 0.0;
        }
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = SPOverlayShouldReduceMotion() ? kFadeInDuration : 0.12;
            ctx.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
            self.panel.animator.alphaValue = 1.0;
        }];
        return;
    }

    NSRect finalFrame = self.panel.frame;
    NSRect startFrame = SPOverlayPresentationStartFrame(finalFrame);
    [self.panel setFrame:startFrame display:YES];
    self.panel.alphaValue = 0.0;

    CATransform3D startTransform = CATransform3DMakeScale(0.982, 0.982, 1.0);
    startTransform = CATransform3DTranslate(startTransform, 0.0, -6.0, 0.0);
    [self animateContentLayerFromTransform:startTransform
                               toTransform:CATransform3DIdentity
                               fromOpacity:0.94
                                 toOpacity:1.0
                                  duration:kPanelEntranceDuration
                                 animation:@"overlayContentEntrance"];
    [self animateShadowFromOpacity:0.05
                         toOpacity:kEntranceShadowOpacity
                        fromRadius:2.0
                          toRadius:kEntranceShadowRadius
                          duration:kPanelEntranceDuration
                         animation:@"overlayShadowEntrance"];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((kPanelEntranceDuration * 0.55) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!self.panel.isVisible || self.panel.alphaValue <= 0.0) return;
        [self animateShadowFromOpacity:kEntranceShadowOpacity
                             toOpacity:kBaseShadowOpacity
                            fromRadius:kEntranceShadowRadius
                              toRadius:kBaseShadowRadius
                              duration:0.18
                             animation:@"overlayShadowEntranceSettle"];
    });

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = kPanelEntranceDuration;
        ctx.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        [[self.panel animator] setFrame:finalFrame display:YES];
        self.panel.animator.alphaValue = 1.0;
    }];
}

- (void)hide {
    [self stopAnimation];
    [self setRawAsrFallbackClickEnabled:NO];
    [self setMainPanelInteractive:NO];

    if (!self.panel.isVisible || self.panel.alphaValue <= 0.01) {
        [self.panel orderOut:nil];
        return;
    }

    NSRect currentFrame = self.panel.frame;
    BOOL reduceMotion = SPOverlayShouldReduceMotion();
    NSRect endFrame = reduceMotion ? currentFrame : SPOverlayDismissalEndFrame(currentFrame);

    if (!reduceMotion) {
        CATransform3D endTransform = CATransform3DMakeScale(0.992, 0.992, 1.0);
        endTransform = CATransform3DTranslate(endTransform, 0.0, -4.0, 0.0);
        [self animateContentLayerFromTransform:CATransform3DIdentity
                                   toTransform:endTransform
                                   fromOpacity:1.0
                                     toOpacity:0.96
                                      duration:kPanelExitDuration
                                     animation:@"overlayContentExit"];
        [self animateShadowFromOpacity:kBaseShadowOpacity
                             toOpacity:0.04
                            fromRadius:kBaseShadowRadius
                              toRadius:2.0
                              duration:kPanelExitDuration
                             animation:@"overlayShadowExit"];
    }

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = reduceMotion ? kFadeOutDuration : kPanelExitDuration;
        ctx.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        [[self.panel animator] setFrame:endFrame display:YES];
        self.panel.animator.alphaValue = 0.0;
    } completionHandler:^{
        [self resetMotionPresentationState];
        if ([self.currentState isEqualToString:@"idle"] || [self.currentState isEqualToString:@"completed"]) {
            [self.panel orderOut:nil];
        }
    }];
}

#pragma mark - Animation Timer

- (void)startAnimation {
    self.contentView.tick = 0;
    self.animationTimer = [NSTimer scheduledTimerWithTimeInterval:kAnimInterval
                                                         repeats:YES
                                                           block:^(NSTimer *timer) {
        self.contentView.tick++;
        [self.contentView setNeedsDisplay:YES];
    }];
}

- (void)stopAnimation {
    [self.animationTimer invalidate];
    self.animationTimer = nil;
}

- (void)dealloc {
    [[NSWorkspace sharedWorkspace].notificationCenter removeObserver:self];
    [self stopAnimation];
}

@end
