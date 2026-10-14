#import "SPProgressPanel.h"

@interface SPProgressPanel () <NSWindowDelegate>
@property (nonatomic, strong) NSTextField *stepLabel;
@property (nonatomic, strong) NSTextField *detailLabel;
@property (nonatomic, strong) NSProgressIndicator *bar;
@property (nonatomic, strong) NSButton *button;
@property (nonatomic) BOOL finished;
@end

@implementation SPProgressPanel

- (instancetype)initWithTitle:(NSString *)title {
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 460, 150)
                                                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                  backing:NSBackingStoreBuffered
                                                    defer:YES];
    panel.title = title;
    panel.releasedWhenClosed = NO;
    panel.hidesOnDeactivate = NO;
    self = [super initWithWindow:panel];
    if (self) {
        panel.delegate = self;
        [self buildContent];
    }
    return self;
}

- (void)buildContent {
    NSView *content = self.window.contentView;
    self.stepLabel = [NSTextField wrappingLabelWithString:@""];
    self.stepLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    self.detailLabel = [NSTextField wrappingLabelWithString:@""];
    self.detailLabel.font = [NSFont systemFontOfSize:11.5];
    self.detailLabel.textColor = NSColor.secondaryLabelColor;
    self.detailLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    self.detailLabel.maximumNumberOfLines = 2;
    self.bar = [[NSProgressIndicator alloc] init];
    self.bar.style = NSProgressIndicatorStyleBar;
    self.bar.minValue = 0;
    self.bar.maxValue = 1;
    self.bar.indeterminate = YES;
    self.button = [NSButton buttonWithTitle:@"Отменить" target:self action:@selector(buttonPressed:)];
    self.button.keyEquivalent = @"\e";
    for (NSView *view in @[ self.stepLabel, self.detailLabel, self.bar, self.button ]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [self.stepLabel.topAnchor constraintEqualToAnchor:content.topAnchor constant:18],
        [self.stepLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20],
        [self.stepLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],
        [self.bar.topAnchor constraintEqualToAnchor:self.stepLabel.bottomAnchor constant:12],
        [self.bar.leadingAnchor constraintEqualToAnchor:self.stepLabel.leadingAnchor],
        [self.bar.trailingAnchor constraintEqualToAnchor:self.stepLabel.trailingAnchor],
        [self.detailLabel.topAnchor constraintEqualToAnchor:self.bar.bottomAnchor constant:8],
        [self.detailLabel.leadingAnchor constraintEqualToAnchor:self.stepLabel.leadingAnchor],
        [self.detailLabel.trailingAnchor constraintEqualToAnchor:self.stepLabel.trailingAnchor],
        [self.button.topAnchor constraintGreaterThanOrEqualToAnchor:self.detailLabel.bottomAnchor constant:14],
        [self.button.trailingAnchor constraintEqualToAnchor:self.stepLabel.trailingAnchor],
        [self.button.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-16],
    ]];
}

- (void)present {
    [self.window center];
    [NSApp activateIgnoringOtherApps:YES];
    [self showWindow:nil];
    [self.window makeKeyAndOrderFront:nil];
    if (self.bar.isIndeterminate) [self.bar startAnimation:nil];
}

- (void)setStep:(NSString *)step detail:(NSString *)detail {
    self.stepLabel.stringValue = step ?: @"";
    self.detailLabel.stringValue = detail ?: @"";
}

- (void)setProgress:(double)fraction {
    if (fraction < 0) {
        if (!self.bar.isIndeterminate) {
            self.bar.indeterminate = YES;
            [self.bar startAnimation:nil];
        }
        return;
    }
    if (self.bar.isIndeterminate) {
        [self.bar stopAnimation:nil];
        self.bar.indeterminate = NO;
    }
    self.bar.doubleValue = MIN(MAX(fraction, 0), 1);
}

- (void)finishWithMessage:(NSString *)message success:(BOOL)success {
    self.finished = YES;
    self.cancelHandler = nil;
    [self.bar stopAnimation:nil];
    self.bar.indeterminate = NO;
    self.bar.doubleValue = success ? 1 : self.bar.doubleValue;
    self.stepLabel.stringValue = message;
    self.detailLabel.stringValue = @"";
    self.button.title = @"Закрыть";
    self.button.keyEquivalent = @"\r";
}

- (void)buttonPressed:(id)sender {
    if (!self.finished) [self cancel];
    [self.window orderOut:nil];
}

- (void)cancel {
    void (^handler)(void) = self.cancelHandler;
    self.cancelHandler = nil;
    self.finished = YES;
    if (handler) handler();
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    if (!self.finished) [self cancel];
    return YES;
}

@end
