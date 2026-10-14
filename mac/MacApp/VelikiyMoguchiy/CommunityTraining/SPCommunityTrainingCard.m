#import "SPCommunityTrainingCard.h"
#import "SPCommunityTrainingJob.h"
#import "SPCommunityTrainingPolicy.h"
#import "SPLipsRuntime.h"
#import "SPSettingsViews.h"
#import "SPTheme.h"

static const NSTimeInterval kPollInterval = 2.0;
/// A started job that has not written its status by then has failed to start (see the log).
static const NSTimeInterval kStartGrace = 30.0;
static const CGFloat kPad = 18.0;
static const CGFloat kBodyHeight = 486.0;
static const CGFloat kActivityHeight = 220.0;

static NSString *const kIntro =
    @"Ваш Mac скачивает несколько публичных роликов, обучает общую модель чтения по губам у себя и отправляет "
    @"только обновление весов. Видео, звук и кадры лица не уходят с компьютера.";
static NSString *const kIdleHint =
    @"Задание занимает от нескольких минут до нескольких часов и идёт в фоне. На сервер ничего не уходит, пока "
    @"вы не посмотрите обновление и не нажмёте «Отправить».";
static NSString *const kRunningHint =
    @"Можно закрыть настройки и пользоваться Mac: задание идёт в фоне. При нехватке памяти оно само встаёт на паузу.";
static NSString *const kLoginHint =
    @"Ждём подтверждения на GitHub. Код действует 15 минут. Логин нужен, чтобы сервер учитывал ваш вклад.";
static NSString *const kStartFailedHint =
    @"Задание не запустилось: подробности в ~/Library/Logs/VelikiyMoguchiy/help-train.log";

/// A flat progress bar in the palette (NSProgressIndicator cannot be tinted).
@interface SPCommunityTrainingBar : NSView
@property (nonatomic) double value;
@end

@implementation SPCommunityTrainingBar

- (void)setValue:(double)value {
    _value = MIN(1.0, MAX(0.0, value));
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    NSRect bounds = self.bounds;
    CGFloat radius = bounds.size.height / 2.0;
    [SPTheme.separator setFill];
    [[NSBezierPath bezierPathWithRoundedRect:bounds xRadius:radius yRadius:radius] fill];
    if (_value <= 0.0) return;
    NSRect fill = bounds;
    fill.size.width = MAX(bounds.size.height, bounds.size.width * _value);
    [SPTheme.accent setFill];
    [[NSBezierPath bezierPathWithRoundedRect:fill xRadius:radius yRadius:radius] fill];
}

@end

/// The inset that holds the progress.
@interface SPCommunityTrainingPanel : NSView
@end

@implementation SPCommunityTrainingPanel

- (void)drawRect:(NSRect)dirtyRect {
    [SPTheme.fieldBackground setFill];
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:8.0 yRadius:8.0] fill];
}

@end

@interface SPCommunityTrainingCard ()
@property (nonatomic, strong) NSButton *consentCheckbox;
@property (nonatomic, strong) NSButton *githubButton;
@property (nonatomic, strong) NSTextField *githubLabel;
@property (nonatomic, strong) NSButton *startButton;
@property (nonatomic, strong) NSTextField *noteLabel;

@property (nonatomic, strong) NSView *loginView;
@property (nonatomic, strong) NSTextField *codeLabel;
@property (nonatomic, strong) NSButton *openGitHubButton;
@property (nonatomic, strong) NSButton *codeCopyButton;

@property (nonatomic, strong) NSView *progressView;
@property (nonatomic, strong) NSTextField *progressLabel;
@property (nonatomic, strong) SPCommunityTrainingBar *bar;
@property (nonatomic, strong) NSTextField *detailLabel;
@property (nonatomic, strong) NSButton *pauseButton;
@property (nonatomic, strong) NSButton *cancelButton;

@property (nonatomic, strong) NSView *previewView;
@property (nonatomic, strong) NSTextView *previewText;
@property (nonatomic, strong) NSButton *sendButton;
@property (nonatomic, strong) NSButton *discardButton;

@property (nonatomic, strong) NSTextField *messageLabel;

@property (nonatomic, strong, nullable) NSTimer *timer;
@property (nonatomic, copy, nullable) NSDictionary *status;
@property (nonatomic, copy, nullable) NSString *statusError;
@property (nonatomic, copy, nullable) NSString *actionError;
@property (nonatomic, copy, nullable) NSString *setupProblem;
@property (nonatomic, copy, nullable) NSDictionary *fetchedPreview;
@property (nonatomic) BOOL previewRequested;
@property (nonatomic, strong, nullable) NSNumber *pauseOverride;
@property (nonatomic, strong, nullable) NSDate *startedAt;  // between the click and the job's first status
@property (nonatomic) BOOL busy;                             // a short command is in flight
@property (nonatomic) BOOL sending;
@property (nonatomic) BOOL polling;
@property (nonatomic) BOOL loggingIn;
@property (nonatomic, copy, nullable) NSString *loginCode;
@property (nonatomic, strong, nullable) NSURL *loginURL;
@property (nonatomic, copy, nullable) NSString *loginError;
@end

@implementation SPCommunityTrainingCard

- (instancetype)initWithWidth:(CGFloat)width {
    CGFloat captionH = 20.0 + SPTheme.sectionHeadingGap;
    self = [super initWithFrame:NSMakeRect(0, 0, width, kBodyHeight + captionH)];
    if (self) {
        SPCaptionLabel *caption = [SPCaptionLabel captionWithString:@"Помочь обучить"];
        caption.frame = NSMakeRect(2.0, kBodyHeight + SPTheme.sectionHeadingGap, width - 4.0, 20.0);
        [self addSubview:caption];
        SPCardView *card = [[SPCardView alloc] initWithFrame:NSMakeRect(0, 0, width, kBodyHeight)];
        [self addSubview:card];
        [self buildInCard:card width:width];
        [self render];
    }
    return self;
}

- (void)dealloc {
    [_timer invalidate];
}

#pragma mark Construction

- (NSTextField *)labelWithFont:(NSFont *)font color:(NSColor *)color wraps:(BOOL)wraps {
    NSTextField *label = wraps ? [NSTextField wrappingLabelWithString:@""] : [NSTextField labelWithString:@""];
    label.font = font;
    label.textColor = color;
    label.selectable = NO;
    if (!wraps) label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}

/// A rounded push button wide enough for the longest of `titles`.
- (NSButton *)buttonWithTitles:(NSArray<NSString *> *)titles action:(SEL)action {
    NSButton *button = [NSButton buttonWithTitle:titles.firstObject target:self action:action];
    button.bezelStyle = NSBezelStyleRounded;
    CGFloat widest = 0.0;
    for (NSString *title in titles) {
        button.title = title;
        [button sizeToFit];
        widest = MAX(widest, button.frame.size.width);
    }
    button.title = titles.firstObject;
    button.frame = NSMakeRect(0, 0, widest + 16.0, 28.0);
    return button;
}

/// Lays `buttons` left to right in `row`, 10 pt apart.
- (void)layoutButtons:(NSArray<NSButton *> *)buttons inRow:(NSView *)row y:(CGFloat)y {
    CGFloat x = 0.0;
    for (NSButton *button in buttons) {
        button.frame = NSMakeRect(x, y, button.frame.size.width, 28.0);
        [row addSubview:button];
        x = NSMaxX(button.frame) + 10.0;
    }
}

- (void)buildInCard:(NSView *)card width:(CGFloat)width {
    CGFloat inner = width - 2.0 * kPad;
    __block CGFloat top = kBodyHeight - kPad;
    // Places `view` below the previous one, across the card's inner width.
    void (^place)(NSView *, CGFloat, CGFloat) = ^(NSView *view, CGFloat height, CGFloat gapAfter) {
        view.frame = NSMakeRect(kPad, top - height, inner, height);
        [card addSubview:view];
        top -= height + gapAfter;
    };

    NSTextField *intro = [self labelWithFont:SPTheme.descriptionFont color:SPTheme.secondaryLabel wraps:YES];
    intro.stringValue = kIntro;
    intro.preferredMaxLayoutWidth = inner;
    place(intro, 46.0, 10.0);

    // A separate consent, off by default; turning it on asks first.
    self.consentCheckbox = [NSButton checkboxWithTitle:@"" target:self action:@selector(consentToggled:)];
    self.consentCheckbox.attributedTitle = [[NSAttributedString alloc]
        initWithString:@"Я хочу помогать обучать общую модель"
            attributes:@{NSFontAttributeName : SPTheme.bodyFont, NSForegroundColorAttributeName : SPTheme.label}];
    self.consentCheckbox.state = NSControlStateValueOff;
    place(self.consentCheckbox, 20.0, 10.0);

    NSView *githubRow = [[NSView alloc] initWithFrame:NSZeroRect];
    place(githubRow, 28.0, 12.0);
    self.githubButton = [self buttonWithTitles:@[ @"Войти через GitHub", @"Отменить вход", @"Выйти" ]
                                        action:@selector(githubPressed:)];
    [self layoutButtons:@[ self.githubButton ] inRow:githubRow y:0.0];
    self.githubLabel = [self labelWithFont:SPTheme.descriptionFont color:SPTheme.secondaryLabel wraps:NO];
    CGFloat labelX = NSMaxX(self.githubButton.frame) + 12.0;
    self.githubLabel.frame = NSMakeRect(labelX, 5.0, inner - labelX, 18.0);
    [githubRow addSubview:self.githubLabel];

    NSView *startRow = [[NSView alloc] initWithFrame:NSZeroRect];
    place(startRow, 28.0, 8.0);
    self.startButton = [self buttonWithTitles:@[ @"Помочь обучить", @"Установить" ] action:@selector(startPressed:)];
    self.startButton.frame = NSMakeRect(0, 0, MAX(170.0, self.startButton.frame.size.width), 28.0);
    [startRow addSubview:self.startButton];

    self.noteLabel = [self labelWithFont:SPTheme.descriptionFont color:SPTheme.secondaryLabel wraps:YES];
    self.noteLabel.preferredMaxLayoutWidth = inner;
    self.noteLabel.selectable = YES;  // the setup note carries commands to copy
    place(self.noteLabel, 46.0, 8.0);

    place([self separator], 1.0, 12.0);

    NSView *activity = [[NSView alloc] initWithFrame:NSZeroRect];
    place(activity, kActivityHeight, 0.0);
    [self buildLoginViewIn:activity width:inner];
    [self buildProgressViewIn:activity width:inner];
    [self buildPreviewViewIn:activity width:inner];
    self.messageLabel = [self labelWithFont:SPTheme.bodyFont color:SPTheme.label wraps:YES];
    self.messageLabel.preferredMaxLayoutWidth = inner;
    self.messageLabel.selectable = YES;
    self.messageLabel.frame = NSMakeRect(0, kActivityHeight - 64.0, inner, 64.0);
    [activity addSubview:self.messageLabel];
}

- (void)buildLoginViewIn:(NSView *)activity width:(CGFloat)inner {
    self.loginView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, inner, kActivityHeight)];
    [activity addSubview:self.loginView];
    CGFloat y = kActivityHeight;
    NSTextField *title = [self labelWithFont:SPTheme.bodyFont color:SPTheme.label wraps:NO];
    title.stringValue = @"Откройте GitHub и введите этот код:";
    y -= 18.0;
    title.frame = NSMakeRect(0, y, inner, 18.0);
    [self.loginView addSubview:title];

    self.codeLabel = [self labelWithFont:[NSFont monospacedSystemFontOfSize:30.0 weight:NSFontWeightSemibold]
                                   color:SPTheme.primaryText
                                   wraps:NO];
    self.codeLabel.selectable = YES;
    y -= 8.0 + 42.0;
    self.codeLabel.frame = NSMakeRect(0, y, inner, 42.0);
    [self.loginView addSubview:self.codeLabel];

    self.openGitHubButton = [self buttonWithTitles:@[ @"Открыть GitHub" ] action:@selector(openGitHubPressed:)];
    self.codeCopyButton = [self buttonWithTitles:@[ @"Скопировать код", @"Скопировано" ] action:@selector(copyCodePressed:)];
    y -= 10.0 + 28.0;
    [self layoutButtons:@[ self.openGitHubButton, self.codeCopyButton ] inRow:self.loginView y:y];

    NSTextField *hint = [self labelWithFont:SPTheme.descriptionFont color:SPTheme.secondaryLabel wraps:YES];
    hint.stringValue = kLoginHint;
    hint.preferredMaxLayoutWidth = inner;
    y -= 10.0 + 32.0;
    hint.frame = NSMakeRect(0, y, inner, 32.0);
    [self.loginView addSubview:hint];
}

- (void)buildProgressViewIn:(NSView *)activity width:(CGFloat)inner {
    self.progressView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, inner, kActivityHeight)];
    [activity addSubview:self.progressView];

    const CGFloat panelH = 78.0;
    SPCommunityTrainingPanel *panel =
        [[SPCommunityTrainingPanel alloc] initWithFrame:NSMakeRect(0, kActivityHeight - panelH, inner, panelH)];
    [self.progressView addSubview:panel];
    CGFloat panelInner = inner - 24.0;
    self.progressLabel = [self labelWithFont:SPTheme.bodyFont color:SPTheme.label wraps:NO];
    self.progressLabel.frame = NSMakeRect(12.0, panelH - 10.0 - 18.0, panelInner, 18.0);
    [panel addSubview:self.progressLabel];
    self.bar = [[SPCommunityTrainingBar alloc] initWithFrame:NSMakeRect(12.0, panelH - 10.0 - 18.0 - 8.0 - 6.0, panelInner, 6.0)];
    [panel addSubview:self.bar];
    self.detailLabel = [self labelWithFont:SPTheme.descriptionFont color:SPTheme.secondaryLabel wraps:NO];
    self.detailLabel.frame = NSMakeRect(12.0, 10.0, panelInner, 18.0);
    [panel addSubview:self.detailLabel];

    self.pauseButton = [self buttonWithTitles:@[ @"Пауза", @"Продолжить" ] action:@selector(pausePressed:)];
    self.cancelButton = [self buttonWithTitles:@[ @"Отменить" ] action:@selector(cancelPressed:)];
    CGFloat buttonsY = kActivityHeight - panelH - 12.0 - 28.0;
    [self layoutButtons:@[ self.pauseButton, self.cancelButton ] inRow:self.progressView y:buttonsY];

    NSTextField *hint = [self labelWithFont:SPTheme.descriptionFont color:SPTheme.secondaryLabel wraps:YES];
    hint.stringValue = kRunningHint;
    hint.preferredMaxLayoutWidth = inner;
    hint.frame = NSMakeRect(0, buttonsY - 12.0 - 32.0, inner, 32.0);
    [self.progressView addSubview:hint];
}

- (void)buildPreviewViewIn:(NSView *)activity width:(CGFloat)inner {
    self.previewView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, inner, kActivityHeight)];
    [activity addSubview:self.previewView];

    NSTextField *title = [self labelWithFont:[NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold]
                                       color:SPTheme.label
                                       wraps:NO];
    title.stringValue = @"Что будет отправлено";
    title.frame = NSMakeRect(0, kActivityHeight - 18.0, inner, 18.0);
    [self.previewView addSubview:title];

    const CGFloat buttonsH = 28.0;
    CGFloat scrollH = kActivityHeight - 18.0 - 6.0 - 12.0 - buttonsH;
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, buttonsH + 12.0, inner, scrollH)];
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.borderType = NSLineBorder;
    scroll.drawsBackground = YES;
    scroll.backgroundColor = SPTheme.fieldBackground;
    NSSize contentSize = [NSScrollView contentSizeForFrameSize:scroll.frame.size
                                       horizontalScrollerClass:nil
                                         verticalScrollerClass:[NSScroller class]
                                                    borderType:NSLineBorder
                                                   controlSize:NSControlSizeRegular
                                                 scrollerStyle:NSScrollerStyleOverlay];
    NSTextView *text = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, contentSize.width, contentSize.height)];
    text.editable = NO;
    text.selectable = YES;
    text.richText = NO;
    text.drawsBackground = YES;
    text.backgroundColor = SPTheme.fieldBackground;
    text.textColor = SPTheme.label;
    text.font = [NSFont monospacedSystemFontOfSize:10.5 weight:NSFontWeightRegular];
    text.textContainerInset = NSMakeSize(6.0, 6.0);
    text.verticallyResizable = YES;
    text.horizontallyResizable = NO;
    text.autoresizingMask = NSViewWidthSizable;
    text.minSize = NSMakeSize(0.0, contentSize.height);
    text.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    text.textContainer.widthTracksTextView = YES;
    text.textContainer.containerSize = NSMakeSize(contentSize.width, CGFLOAT_MAX);
    scroll.documentView = text;
    self.previewText = text;
    [self.previewView addSubview:scroll];

    self.sendButton = [self buttonWithTitles:@[ @"Отправить" ] action:@selector(sendPressed:)];
    self.discardButton = [self buttonWithTitles:@[ @"Не отправлять" ] action:@selector(discardPressed:)];
    [self layoutButtons:@[ self.sendButton, self.discardButton ] inRow:self.previewView y:0.0];
}

- (NSView *)separator {
    NSBox *line = [[NSBox alloc] initWithFrame:NSZeroRect];
    line.boxType = NSBoxCustom;
    line.borderWidth = 0.0;
    line.fillColor = SPTheme.separator;
    return line;
}

#pragma mark Lifecycle

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self.timer invalidate];
    self.timer = nil;
    if (!self.window) return;
    __weak typeof(self) weakSelf = self;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:kPollInterval
                                                 repeats:YES
                                                   block:^(NSTimer *timer) {
        [weakSelf tick];
    }];
    [self refresh];
}

- (BOOL)jobActive {
    return self.startedAt != nil || self.sending || [SPCommunityTrainingPolicy isActiveStatus:self.status];
}

- (void)tick {
    if ([self jobActive]) [self refresh];
}

- (void)refresh {
    self.setupProblem = [[SPCommunityTrainingJob sharedJob] setupProblem];
    if (self.setupProblem) {
        self.status = nil;
        self.statusError = nil;
        [self render];
        return;
    }
    if (self.polling) return;
    self.polling = YES;
    __weak typeof(self) weakSelf = self;
    [[SPCommunityTrainingJob sharedJob] statusWithCompletion:^(NSDictionary *status, NSString *error) {
        weakSelf.polling = NO;
        [weakSelf applyStatus:status error:error];
    }];
}

- (void)applyStatus:(NSDictionary *)status error:(NSString *)error {
    self.statusError = error;
    if (status) self.status = status;
    if (self.startedAt) {
        NSNumber *started = [SPCommunityTrainingPolicy jobOfStatus:status][@"started_at"];
        BOOL ours = [started isKindOfClass:[NSNumber class]] &&
                    started.doubleValue >= self.startedAt.timeIntervalSince1970 - 5.0;
        if (ours) {
            self.startedAt = nil;
        } else if (-[self.startedAt timeIntervalSinceNow] > kStartGrace) {
            self.startedAt = nil;
            self.actionError = kStartFailedHint;
        }
    }
    BOOL running = [SPCommunityTrainingPolicy isActiveStatus:self.status];
    BOOL statusPaused = [SPCommunityTrainingPolicy isPausedStatus:self.status override:nil];
    if (!running || (self.pauseOverride && self.pauseOverride.boolValue == statusPaused)) self.pauseOverride = nil;
    if (![SPCommunityTrainingPolicy showsPreviewForStatus:self.status]) {
        self.fetchedPreview = nil;
        self.previewRequested = NO;
    } else if (![SPCommunityTrainingPolicy previewOfStatus:self.status] && !self.previewRequested) {
        [self fetchPreview];
    }
    [self render];
}

- (void)fetchPreview {
    self.previewRequested = YES;
    __weak typeof(self) weakSelf = self;
    [[SPCommunityTrainingJob sharedJob] runCommand:@"preview" value:nil completion:^(id json, NSString *error) {
        weakSelf.fetchedPreview = [json isKindOfClass:[NSDictionary class]] ? json : nil;
        [weakSelf render];
    }];
}

#pragma mark Rendering

- (void)render {
    NSDictionary *status = self.status;
    BOOL ready = status != nil && self.setupProblem == nil;
    BOOL active = [self jobActive];
    BOOL loggedIn = [SPCommunityTrainingPolicy flag:@"logged_in" inStatus:status];

    if (!self.busy) {  // while `consent on|off` runs, keep what the user clicked
        self.consentCheckbox.state =
            [SPCommunityTrainingPolicy flag:@"consent" inStatus:status] ? NSControlStateValueOn : NSControlStateValueOff;
    }
    self.consentCheckbox.enabled = ready && !self.busy && !self.sending;

    if (self.loggingIn) {
        self.githubButton.title = @"Отменить вход";
        self.githubButton.enabled = YES;
        self.githubLabel.stringValue = self.loginCode ? @"" : @"Получаем код для входа…";
    } else if (loggedIn) {
        self.githubButton.title = @"Выйти";
        self.githubButton.enabled = ready && !self.busy && !active;
        id login = status[@"login"];
        self.githubLabel.stringValue = [login isKindOfClass:NSString.class] && [login length]
                                           ? [NSString stringWithFormat:@"Вы вошли через GitHub как %@", login]
                                           : @"Вы вошли через GitHub";
    } else {
        self.githubButton.title = @"Войти через GitHub";
        self.githubButton.enabled = ready && !self.busy && [SPCommunityTrainingPolicy canLoginWithStatus:status];
        self.githubLabel.stringValue =
            self.loginError ? [@"Вход не удался: " stringByAppendingString:self.loginError]
                            : @"Логин появится в публичной таблице участников";
    }
    self.githubLabel.textColor = self.loginError && !self.loggingIn && !loggedIn ? SPTheme.failure : SPTheme.secondaryLabel;

    BOOL install = [[SPCommunityTrainingJob sharedJob] needsInstall];
    self.startButton.title = install ? @"Установить" : @"Помочь обучить";
    self.startButton.enabled = install ? !self.busy && ![SPLipsRuntime sharedRuntime].isInstalling
                                       : ready && !self.busy && !active && [SPCommunityTrainingPolicy canStartWithStatus:status];

    NSString *failure = self.setupProblem ?: self.statusError ?: self.actionError;
    self.noteLabel.stringValue = failure ?: ([SPCommunityTrainingPolicy blockerForStatus:status] ?: @"");
    self.noteLabel.textColor = failure ? SPTheme.failure : SPTheme.secondaryLabel;

    BOOL showLogin = self.loggingIn && self.loginCode != nil;
    BOOL showProgress = !showLogin && active;
    BOOL showPreview = !showLogin && !showProgress && [SPCommunityTrainingPolicy showsPreviewForStatus:status];
    self.loginView.hidden = !showLogin;
    self.progressView.hidden = !showProgress;
    self.previewView.hidden = !showPreview;
    self.messageLabel.hidden = showLogin || showProgress || showPreview;

    if (showLogin) {
        self.codeLabel.stringValue = self.loginCode;
        self.openGitHubButton.enabled = self.loginURL != nil;
    }
    if (showProgress) [self renderProgress];
    if (showPreview) {
        NSDictionary *preview = [SPCommunityTrainingPolicy previewOfStatus:status] ?: self.fetchedPreview;
        NSString *text = (preview || self.previewRequested) ? [SPCommunityTrainingPolicy previewTextForPreview:preview]
                                                            : @"Загружаем описание обновления…";
        if (![self.previewText.string isEqualToString:text]) self.previewText.string = text;
        self.sendButton.enabled = !self.busy && [SPCommunityTrainingPolicy flag:@"logged_in" inStatus:status];
        self.discardButton.enabled = !self.busy;
    }
    if (!self.messageLabel.hidden) {
        NSString *message = ready ? [SPCommunityTrainingPolicy resultMessageForStatus:status] : nil;
        self.messageLabel.stringValue = message ?: (ready ? kIdleHint : @"");
    }
}

- (void)renderProgress {
    if (self.startedAt) {
        self.progressLabel.stringValue = @"Запуск…";
        self.bar.value = 0.0;
        self.detailLabel.stringValue = @"";
    } else if (self.sending) {
        self.progressLabel.stringValue = @"Отправка обновления…";
        self.bar.value = 1.0;
        self.detailLabel.stringValue = @"";
    } else {
        BOOL paused = [SPCommunityTrainingPolicy isPausedStatus:self.status override:self.pauseOverride];
        self.progressLabel.stringValue = [SPCommunityTrainingPolicy progressLineForStatus:self.status paused:paused];
        self.bar.value = [SPCommunityTrainingPolicy progressForStatus:self.status];
        self.detailLabel.stringValue = [SPCommunityTrainingPolicy detailLineForStatus:self.status];
    }
    BOOL running = !self.startedAt && !self.sending &&
                   [SPCommunityTrainingPolicy stateOfStatus:self.status] == SPCommunityJobStateRunning;
    BOOL paused = [SPCommunityTrainingPolicy isPausedStatus:self.status override:self.pauseOverride];
    self.pauseButton.title = paused ? @"Продолжить" : @"Пауза";
    self.pauseButton.hidden = !running;
    self.cancelButton.hidden = !running;
    self.pauseButton.enabled = !self.busy;
    self.cancelButton.enabled = !self.busy;
}

#pragma mark Actions

/// Runs a short command with the controls disabled, then reads the status again.
- (void)runBusy:(NSString *)command value:(NSString *)value then:(void (^_Nullable)(id json))then {
    self.busy = YES;
    self.actionError = nil;
    [self render];
    __weak typeof(self) weakSelf = self;
    [[SPCommunityTrainingJob sharedJob] runCommand:command value:value completion:^(id json, NSString *error) {
        weakSelf.busy = NO;
        if (error) weakSelf.actionError = error;
        if (json && then) then(json);
        [weakSelf refresh];
        [weakSelf render];
    }];
}

- (void)consentToggled:(id)sender {
    if (self.consentCheckbox.state == NSControlStateValueOn) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = [SPCommunityTrainingPolicy consentAlertTitle];
        alert.informativeText = [SPCommunityTrainingPolicy consentAlertText];
        [alert addButtonWithTitle:@"Согласен"];
        [alert addButtonWithTitle:@"Отмена"];
        if ([alert runModal] != NSAlertFirstButtonReturn) {
            self.consentCheckbox.state = NSControlStateValueOff;
            return;
        }
        [self runBusy:@"consent" value:@"on" then:nil];
    } else {
        // Turning the consent off also cancels a running job.
        [self runBusy:@"consent" value:@"off" then:nil];
    }
}

- (void)githubPressed:(id)sender {
    if (self.loggingIn) {
        [[SPCommunityTrainingJob sharedJob] cancelLogin];
        [self finishLogin];
        return;
    }
    if ([SPCommunityTrainingPolicy flag:@"logged_in" inStatus:self.status]) {
        [self runBusy:@"logout" value:nil then:nil];
        return;
    }
    self.loggingIn = YES;
    self.loginCode = nil;
    self.loginURL = nil;
    self.loginError = nil;
    [self render];
    __weak typeof(self) weakSelf = self;
    [[SPCommunityTrainingJob sharedJob]
        loginWithCodeHandler:^(NSString *userCode, NSURL *verificationURL) {
            weakSelf.loginCode = userCode;
            weakSelf.loginURL = verificationURL;
            weakSelf.codeCopyButton.title = @"Скопировать код";
            [weakSelf render];
        }
        completion:^(BOOL loggedIn, NSString *error) {
            weakSelf.loginError = loggedIn ? nil : error;
            [weakSelf finishLogin];
        }];
}

- (void)finishLogin {
    self.loggingIn = NO;
    self.loginCode = nil;
    self.loginURL = nil;
    [self refresh];
    [self render];
}

- (void)openGitHubPressed:(id)sender {
    if (self.loginURL) [[NSWorkspace sharedWorkspace] openURL:self.loginURL];
}

- (void)copyCodePressed:(id)sender {
    if (!self.loginCode) return;
    [[NSPasteboard generalPasteboard] clearContents];
    [[NSPasteboard generalPasteboard] setString:self.loginCode forType:NSPasteboardTypeString];
    self.codeCopyButton.title = @"Скопировано";
}

- (void)startPressed:(id)sender {
    if ([[SPCommunityTrainingJob sharedJob] needsInstall]) {
        __weak typeof(self) weakSelf = self;
        [[SPLipsRuntime sharedRuntime] offerSetupWithCompletion:^(BOOL ready) {
            [weakSelf refresh];
        }];
        return;
    }
    self.startedAt = [NSDate date];
    self.actionError = nil;
    [self render];
    __weak typeof(self) weakSelf = self;
    [[SPCommunityTrainingJob sharedJob] startWithCompletion:^(NSString *error) {
        if (error) {
            weakSelf.startedAt = nil;
            weakSelf.actionError = error;
        }
        [weakSelf refresh];
        [weakSelf render];
    }];
}

- (void)pausePressed:(id)sender {
    BOOL pause = ![SPCommunityTrainingPolicy isPausedStatus:self.status override:self.pauseOverride];
    __weak typeof(self) weakSelf = self;
    [self runBusy:pause ? @"pause" : @"resume" value:nil then:^(id json) {
        if ([json isKindOfClass:[NSDictionary class]] && [json[@"signalled"] boolValue]) weakSelf.pauseOverride = @(pause);
    }];
}

- (void)cancelPressed:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Отменить обучение?";
    alert.informativeText = @"Скачанное и посчитанное будет удалено, на сервер ничего не уйдёт. Начать заново можно "
                            @"в любой момент.";
    [alert addButtonWithTitle:@"Отменить обучение"];
    [alert addButtonWithTitle:@"Продолжить"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    [self runBusy:@"cancel" value:nil then:nil];
}

- (void)sendPressed:(id)sender {
    self.sending = YES;
    self.busy = YES;
    self.actionError = nil;
    [self render];
    __weak typeof(self) weakSelf = self;
    [[SPCommunityTrainingJob sharedJob] runCommand:@"send" value:nil completion:^(id json, NSString *error) {
        weakSelf.sending = NO;
        weakSelf.busy = NO;
        if (error) weakSelf.actionError = error;
        [weakSelf refresh];
        [weakSelf render];
    }];
}

- (void)discardPressed:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Не отправлять обновление?";
    alert.informativeText = @"Обновление будет удалено с этого Mac, на сервер ничего не уйдёт.";
    [alert addButtonWithTitle:@"Не отправлять"];
    [alert addButtonWithTitle:@"Отмена"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    [self runBusy:@"discard" value:nil then:nil];
}

@end
