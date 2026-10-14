#import "SPLipTrainingCard.h"
#import "SPLipTrainingJob.h"
#import "SPLipTrainingPolicy.h"
#import "SPSettingsViews.h"
#import "SPTheme.h"

static NSString *const kModeDefaultsKey = @"SPLipTrainingMode";
static const NSTimeInterval kPollInterval = 2.0;
/// While a job runs, the clips are counted again this often: the scan's job state is checked against the job's
/// lock, so a job that died (and whose pid was reused) does not look running for ever.
static const NSTimeInterval kRunningRescanInterval = 30.0;
/// A started job that has not written its status by then has failed to start (see lips_training/job.log).
static const NSTimeInterval kStartGrace = 30.0;
static const CGFloat kPad = 18.0;
static const CGFloat kBodyHeight = 532.0;

static NSString *const kIntro =
    @"Дообучает чтение по губам на ваших диктовках с камерой — прямо на этом Mac, ничего никуда не отправляя. "
    @"Метки — распознанный текст диктовок. 10% фраз откладываются для проверки: новая модель ставится, только если "
    @"ошибается на них реже прежней. При нехватке памяти обучение само встаёт на паузу.";
static NSString *const kShareNote =
    @"Пока недоступно: общий сервер обучения ещё не запущен. Когда заработает, после удачного обучения на сервер "
    @"уйдёт только изменение весов адаптера LoRA — никогда видео, кадры, звук или тексты.";
static NSString *const kNoResultYet =
    @"Здесь появится итог: ошибка прежней и новой модели на отложенных клипах.";

// The palette of the settings: parchment, umber text, cinnabar accent. Local tokens until SPTheme carries them.
static NSColor *umber(void) {
    return [SPTheme dynamicLight:0x32261E lightAlpha:1.0 dark:0xE8DCC8 darkAlpha:1.0];
}
static NSColor *umberSoft(void) {
    return [SPTheme dynamicLight:0x32261E lightAlpha:0.68 dark:0xE8DCC8 darkAlpha:0.68];
}
static NSColor *cinnabar(void) {
    return [SPTheme dynamicLight:0x9B3A2C lightAlpha:1.0 dark:0xC9604F darkAlpha:1.0];
}
static NSColor *parchment(void) {
    return [SPTheme dynamicLight:0xE8DCC8 lightAlpha:0.85 dark:0x3A3029 darkAlpha:0.85];
}
static NSColor *barTrack(void) {
    return [SPTheme dynamicLight:0x32261E lightAlpha:0.14 dark:0xE8DCC8 darkAlpha:0.18];
}

/// A flat progress bar in the palette (NSProgressIndicator cannot be tinted).
@interface SPLipTrainingBar : NSView
@property (nonatomic) double value;
@end

@implementation SPLipTrainingBar

- (void)setValue:(double)value {
    _value = MIN(1.0, MAX(0.0, value));
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    NSRect bounds = self.bounds;
    CGFloat radius = bounds.size.height / 2.0;
    [barTrack() setFill];
    [[NSBezierPath bezierPathWithRoundedRect:bounds xRadius:radius yRadius:radius] fill];
    if (_value <= 0.0) return;
    NSRect fill = bounds;
    fill.size.width = MAX(bounds.size.height, bounds.size.width * _value);
    [cinnabar() setFill];
    [[NSBezierPath bezierPathWithRoundedRect:fill xRadius:radius yRadius:radius] fill];
}

@end

/// The parchment inset that holds the progress and the result.
@interface SPLipTrainingPanel : NSView
@end

@implementation SPLipTrainingPanel

- (void)drawRect:(NSRect)dirtyRect {
    [parchment() setFill];
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:10.0 yRadius:10.0] fill];
}

@end

@interface SPLipTrainingCard ()
@property (nonatomic, strong) NSTextField *clipsLabel;
@property (nonatomic, strong) NSTextField *modelLabel;
@property (nonatomic, strong) NSTextField *blockerLabel;
@property (nonatomic, strong) NSSegmentedControl *modeControl;
@property (nonatomic, strong) NSTextField *modeLabel;
@property (nonatomic, strong) NSButton *startButton;
@property (nonatomic, strong) NSButton *cancelButton;
@property (nonatomic, strong) NSTextField *progressLabel;
@property (nonatomic, strong) SPLipTrainingBar *bar;
@property (nonatomic, strong) NSTextField *resultLabel;
@property (nonatomic, strong) NSButton *rollbackButton;
@property (nonatomic, strong) NSTextField *rollbackLabel;
@property (nonatomic, strong) NSSwitch *shareSwitch;
@property (nonatomic, strong) NSTextField *shareNote;
@property (nonatomic, strong, nullable) NSTimer *timer;
@property (nonatomic, copy, nullable) NSDictionary *scan;
@property (nonatomic, copy, nullable) NSDictionary *status;
@property (nonatomic, copy, nullable) NSString *scanError;
@property (nonatomic, copy, nullable) NSString *startError;  // the job could not be launched at all
@property (nonatomic, strong, nullable) NSDate *startedAt;  // set between the click and the job's first status
@property (nonatomic, strong, nullable) NSDate *scannedAt;
@property (nonatomic) BOOL busy;                             // a short command is in flight
@property (nonatomic) BOOL wasRunning;
@end

@implementation SPLipTrainingCard

- (instancetype)initWithWidth:(CGFloat)width {
    CGFloat captionH = 20.0 + SPTheme.sectionHeadingGap;
    self = [super initWithFrame:NSMakeRect(0, 0, width, kBodyHeight + captionH)];
    if (self) {
        SPCaptionLabel *caption = [SPCaptionLabel captionWithString:@"Личная модель чтения по губам"];
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

- (void)buildInCard:(NSView *)card width:(CGFloat)width {
    CGFloat inner = width - 2.0 * kPad;
    __block CGFloat top = kBodyHeight - kPad;
    // Places `view` below the previous one, across the card's inner width.
    void (^place)(NSView *, CGFloat, CGFloat) = ^(NSView *view, CGFloat height, CGFloat gapAfter) {
        view.frame = NSMakeRect(kPad, top - height, inner, height);
        [card addSubview:view];
        top -= height + gapAfter;
    };

    NSTextField *intro = [self labelWithFont:SPTheme.descriptionFont color:umberSoft() wraps:YES];
    intro.stringValue = kIntro;
    intro.preferredMaxLayoutWidth = inner;
    place(intro, 46.0, 10.0);

    self.clipsLabel = [self labelWithFont:SPTheme.bodyFont color:umber() wraps:NO];
    place(self.clipsLabel, 18.0, 2.0);
    self.modelLabel = [self labelWithFont:SPTheme.bodyFont color:umber() wraps:NO];
    place(self.modelLabel, 18.0, 2.0);
    self.blockerLabel = [self labelWithFont:SPTheme.descriptionFont color:cinnabar() wraps:YES];
    self.blockerLabel.preferredMaxLayoutWidth = inner;
    place(self.blockerLabel, 32.0, 10.0);

    // Mode: лёгкий / полный, remembered between launches.
    self.modeControl = [NSSegmentedControl segmentedControlWithLabels:@[ @"Лёгкий", @"Полный" ]
                                                         trackingMode:NSSegmentSwitchTrackingSelectOne
                                                               target:self
                                                               action:@selector(modeChanged:)];
    self.modeControl.selectedSegmentBezelColor = cinnabar();
    for (NSInteger i = 0; i < 2; i++) [self.modeControl setWidth:176.0 forSegment:i];
    NSInteger savedMode = [[NSUserDefaults standardUserDefaults] integerForKey:kModeDefaultsKey];
    self.modeControl.selectedSegment = savedMode == SPLipTrainingModeFull ? 1 : 0;
    place(self.modeControl, 24.0, 6.0);
    self.modeControl.frame = NSMakeRect(kPad, NSMinY(self.modeControl.frame), 2.0 * 176.0 + 8.0, 24.0);
    self.modeLabel = [self labelWithFont:SPTheme.descriptionFont color:umberSoft() wraps:YES];
    self.modeLabel.preferredMaxLayoutWidth = inner;
    place(self.modeLabel, 32.0, 12.0);

    // Start and cancel.
    NSView *buttons = [[NSView alloc] initWithFrame:NSZeroRect];
    place(buttons, 28.0, 12.0);
    self.startButton = [NSButton buttonWithTitle:@"Обучить на мне" target:self action:@selector(startPressed:)];
    self.startButton.bezelStyle = NSBezelStyleRounded;
    self.startButton.bezelColor = cinnabar();
    [self.startButton sizeToFit];
    self.startButton.frame = NSMakeRect(0, 0, MAX(150.0, self.startButton.frame.size.width + 16.0), 28.0);
    [buttons addSubview:self.startButton];
    self.cancelButton = [NSButton buttonWithTitle:@"Отменить" target:self action:@selector(cancelPressed:)];
    self.cancelButton.bezelStyle = NSBezelStyleRounded;
    [self.cancelButton sizeToFit];
    self.cancelButton.frame = NSMakeRect(NSMaxX(self.startButton.frame) + 10.0, 0,
                                         self.cancelButton.frame.size.width + 12.0, 28.0);
    [buttons addSubview:self.cancelButton];

    // Progress and result on a parchment inset.
    SPLipTrainingPanel *panel = [[SPLipTrainingPanel alloc] initWithFrame:NSZeroRect];
    place(panel, 90.0, 14.0);
    CGFloat panelInner = inner - 24.0;
    self.progressLabel = [self labelWithFont:SPTheme.bodyFont color:umber() wraps:NO];
    self.progressLabel.frame = NSMakeRect(12.0, 90.0 - 10.0 - 18.0, panelInner, 18.0);
    [panel addSubview:self.progressLabel];
    self.bar = [[SPLipTrainingBar alloc] initWithFrame:NSMakeRect(12.0, 90.0 - 10.0 - 18.0 - 6.0 - 6.0, panelInner, 6.0)];
    [panel addSubview:self.bar];
    self.resultLabel = [self labelWithFont:SPTheme.descriptionFont color:umber() wraps:YES];
    self.resultLabel.preferredMaxLayoutWidth = panelInner;
    self.resultLabel.frame = NSMakeRect(12.0, 10.0, panelInner, 32.0);
    [panel addSubview:self.resultLabel];

    place([self separator], 1.0, 12.0);

    // «Вернуть прежнюю модель».
    NSView *rollbackRow = [[NSView alloc] initWithFrame:NSZeroRect];
    place(rollbackRow, 28.0, 12.0);
    self.rollbackButton = [NSButton buttonWithTitle:@"Вернуть прежнюю модель"
                                             target:self
                                             action:@selector(rollbackPressed:)];
    self.rollbackButton.bezelStyle = NSBezelStyleRounded;
    [self.rollbackButton sizeToFit];
    self.rollbackButton.frame = NSMakeRect(0, 0, self.rollbackButton.frame.size.width + 12.0, 28.0);
    [rollbackRow addSubview:self.rollbackButton];
    self.rollbackLabel = [self labelWithFont:SPTheme.descriptionFont color:umberSoft() wraps:NO];
    CGFloat labelX = NSMaxX(self.rollbackButton.frame) + 12.0;
    self.rollbackLabel.frame = NSMakeRect(labelX, 5.0, inner - labelX, 18.0);
    [rollbackRow addSubview:self.rollbackLabel];

    place([self separator], 1.0, 12.0);

    // «Поделиться улучшением»: a separate consent, off by default; disabled until the server exists.
    NSView *shareRow = [[NSView alloc] initWithFrame:NSZeroRect];
    place(shareRow, 24.0, 4.0);
    self.shareSwitch = [[NSSwitch alloc] initWithFrame:NSZeroRect];
    [self.shareSwitch sizeToFit];
    self.shareSwitch.state = NSControlStateValueOff;
    self.shareSwitch.enabled = NO;
    NSSize switchSize = self.shareSwitch.frame.size;
    self.shareSwitch.frame = NSMakeRect(inner - switchSize.width, (24.0 - switchSize.height) / 2.0,
                                        switchSize.width, switchSize.height);
    [shareRow addSubview:self.shareSwitch];
    NSTextField *shareTitle = [self labelWithFont:SPTheme.bodyFont color:umber() wraps:NO];
    shareTitle.stringValue = @"Поделиться улучшением";
    shareTitle.frame = NSMakeRect(0, 3.0, inner - switchSize.width - 12.0, 18.0);
    [shareRow addSubview:shareTitle];
    self.shareNote = [self labelWithFont:SPTheme.descriptionFont color:umberSoft() wraps:YES];
    self.shareNote.preferredMaxLayoutWidth = inner;
    place(self.shareNote, 46.0, 0.0);
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
        [weakSelf poll];
    }];
    [self refresh];
}

- (void)refresh {
    self.scannedAt = [NSDate date];
    [self poll];
    __weak typeof(self) weakSelf = self;
    [[SPLipTrainingJob sharedJob] scanWithCompletion:^(NSDictionary *scan, NSString *error) {
        weakSelf.scan = scan;
        weakSelf.scanError = error;
        [weakSelf render];
    }];
}

/// Reads the job's status file; when a job has just ended, counts the clips again. The lips service notices an
/// installed or restored model by itself and restarts between requests.
- (void)poll {
    NSDictionary *status = [[SPLipTrainingJob sharedJob] readStatus];
    NSDictionary *scanned = [self.scan[@"job"] isKindOfClass:[NSDictionary class]] ? self.scan[@"job"] : nil;
    if ([SPLipTrainingPolicy isRunningStatus:status] && scanned && ![SPLipTrainingPolicy isRunningStatus:scanned] &&
        [scanned[@"job_id"] isEqual:status[@"job_id"]]) {
        status = scanned;  // the scan checked the job's lock: it is gone
    }
    BOOL running = [SPLipTrainingPolicy isRunningStatus:status];
    if (running && self.scannedAt && -[self.scannedAt timeIntervalSinceNow] > kRunningRescanInterval) {
        [self refresh];
        return;
    }
    if (self.startedAt) {
        NSNumber *started = [status[@"started_at"] isKindOfClass:[NSNumber class]] ? status[@"started_at"] : nil;
        BOOL ours = started && started.doubleValue >= self.startedAt.timeIntervalSince1970 - 5.0;
        if (ours || running || -[self.startedAt timeIntervalSinceNow] > kStartGrace) self.startedAt = nil;
    }
    BOOL ended = self.wasRunning && !running;
    self.wasRunning = running;
    self.status = status;
    if (ended) {
        [self refresh];  // the clips, the model and the rollback changed; refresh polls (not ended now) and renders
        return;
    }
    [self render];
}

#pragma mark Rendering

- (BOOL)isRunning {
    return self.startedAt != nil || [SPLipTrainingPolicy isRunningStatus:self.status];
}

- (void)render {
    NSDictionary *scan = self.scanError ? @{@"error" : self.scanError} : self.scan;
    BOOL running = [self isRunning];

    self.clipsLabel.stringValue = self.scanError ? @"" : [SPLipTrainingPolicy clipsLineForScan:scan];
    self.modelLabel.stringValue = self.scan ? [SPLipTrainingPolicy modelLineForScan:self.scan] : @"";
    NSString *blocker = running ? nil : [SPLipTrainingPolicy blockerForScan:scan];
    self.blockerLabel.stringValue = blocker ?: @"";

    for (NSInteger i = 0; i < 2; i++) {
        [self.modeControl setLabel:[SPLipTrainingPolicy modeTitle:(SPLipTrainingMode)i scan:self.scan] forSegment:i];
    }
    self.modeControl.enabled = !running;
    self.modeLabel.stringValue = [SPLipTrainingPolicy modeDescription:[self selectedMode]];

    self.startButton.enabled = !running && !self.busy && [SPLipTrainingPolicy canStartWithScan:scan status:self.status];
    self.cancelButton.hidden = !running;
    self.cancelButton.enabled = !self.busy && self.startedAt == nil;

    if (running) {
        self.progressLabel.stringValue = self.startedAt ? @"Запуск…"
                                                        : [SPLipTrainingPolicy progressLineForStatus:self.status
                                                                                                 now:[NSDate date]];
        self.bar.value = [SPLipTrainingPolicy progressForStatus:self.status];
        self.bar.hidden = NO;
        self.resultLabel.stringValue = @"Можно закрыть настройки и пользоваться Mac: обучение идёт в фоне и "
                                       @"продолжится, даже если закрыть приложение.";
    } else {
        self.progressLabel.stringValue = @"";
        self.bar.hidden = YES;
        self.resultLabel.stringValue = self.startError
                                           ?: ([SPLipTrainingPolicy resultLineForStatus:self.status] ?: kNoResultYet);
    }

    NSString *hint = [SPLipTrainingPolicy rollbackHintForScan:self.scan];
    self.rollbackButton.enabled = hint != nil && !running && !self.busy;
    self.rollbackLabel.stringValue = hint ?: @"Прежней модели пока нет";

    NSDictionary *share = [self.scan[@"share"] isKindOfClass:[NSDictionary class]] ? self.scan[@"share"] : nil;
    NSString *note = [share[@"note"] isKindOfClass:[NSString class]] ? share[@"note"] : kShareNote;
    self.shareNote.stringValue = note;
}

- (SPLipTrainingMode)selectedMode {
    return self.modeControl.selectedSegment == 1 ? SPLipTrainingModeFull : SPLipTrainingModeLight;
}

#pragma mark Actions

- (void)modeChanged:(id)sender {
    [[NSUserDefaults standardUserDefaults] setInteger:[self selectedMode] forKey:kModeDefaultsKey];
    [self render];
}

- (void)startPressed:(id)sender {
    SPLipTrainingMode mode = [self selectedMode];
    if (mode == SPLipTrainingModeFull) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Начать полное обучение?";
        alert.informativeText = [NSString stringWithFormat:
            @"Займёт %@ (оценка для M3 Max; на других Mac дольше). Обучение идёт в фоне на этом Mac, уступает "
            @"память другим программам и встаёт на паузу при её нехватке. Его можно отменить в любой момент; "
            @"модель сменится, только если новая окажется лучше.",
            [SPLipTrainingPolicy estimateText:mode scan:self.scan] ?: @"несколько часов"];
        [alert addButtonWithTitle:@"Начать"];
        [alert addButtonWithTitle:@"Отмена"];
        if ([alert runModal] != NSAlertFirstButtonReturn) return;
    }
    self.startedAt = [NSDate date];
    self.startError = nil;
    [self render];
    __weak typeof(self) weakSelf = self;
    [[SPLipTrainingJob sharedJob] startMode:mode completion:^(NSString *error) {
        if (error) {
            weakSelf.startedAt = nil;
            weakSelf.startError = [@"Не получилось: " stringByAppendingString:error];
        }
        [weakSelf render];
    }];
}

- (void)cancelPressed:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Остановить обучение?";
    alert.informativeText = @"Текущая модель останется как есть. Начать заново можно в любой момент.";
    [alert addButtonWithTitle:@"Остановить"];
    [alert addButtonWithTitle:@"Продолжить обучение"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    self.busy = YES;
    [self render];
    __weak typeof(self) weakSelf = self;
    [[SPLipTrainingJob sharedJob] cancelWithCompletion:^(NSString *error) {
        weakSelf.busy = NO;
        if (error) NSLog(@"[VelikiyMoguchiy] lips training: cancel: %@", error);
        [weakSelf poll];
    }];
}

- (void)rollbackPressed:(id)sender {
    NSString *hint = [SPLipTrainingPolicy rollbackHintForScan:self.scan];
    if (!hint) return;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Вернуть прежнюю модель?";
    alert.informativeText = [NSString stringWithFormat:@"%@. Текущую модель можно будет вернуть этой же кнопкой.", hint];
    [alert addButtonWithTitle:@"Вернуть"];
    [alert addButtonWithTitle:@"Отмена"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    self.busy = YES;
    [self render];
    __weak typeof(self) weakSelf = self;
    [[SPLipTrainingJob sharedJob] rollbackWithCompletion:^(NSDictionary *reply, NSString *error) {
        weakSelf.busy = NO;
        if (error) {
            NSAlert *failure = [[NSAlert alloc] init];
            failure.messageText = @"Не удалось вернуть модель";
            failure.informativeText = error;
            [failure runModal];
        }
        [weakSelf refresh];
    }];
}

@end
