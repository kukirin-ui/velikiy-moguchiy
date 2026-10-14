#import "SPOnboardingWindowController.h"
#import "SPHotkeyNames.h"
#import "SPLocalAsrOffer.h"
#import "SPLocalAsrPolicy.h"
#import "SPPermissionManager.h"
#import "SPTheme.h"
#import "SPTriggerKeyPolicy.h"
#import "velikiy_moguchiy_core.h"

static NSString *const kOnboardingDoneKey = @"SPOnboardingDone";
static NSString *const kDashScopeKeyHelpURL =
    @"https://github.com/zigansh1n/velikiy-moguchiy/blob/main/docs/DASHSCOPE-KEY.md";
static const CGFloat kWindowWidth = 560.0;
static const CGFloat kContentInset = 28.0;

static NSString *configString(const char *keyPath) {
    char *raw = sp_config_get(keyPath);
    if (!raw) return @"";
    NSString *value = [NSString stringWithUTF8String:raw] ?: @"";
    sp_core_free_string(raw);
    return value;
}

/// The chosen recognition can run: a local provider, or a cloud one with its key.
static BOOL recognitionReady(void) {
    NSDictionary *asr = [SPLocalAsrOffer currentAsrConfig];
    NSString *provider = [asr[@"provider"] isKindOfClass:[NSString class]] ? asr[@"provider"] : @"qwen";
    return [SPLocalAsrPolicy isLocalProvider:provider] ||
           [SPLocalAsrPolicy hasCredentialsForProvider:provider asrConfig:asr];
}

/// One checklist line: a mark, a title with a hint under it, and a button.
@interface SPOnboardingRow : NSObject
@property (nonatomic, strong) NSStackView *view;
@property (nonatomic, strong) NSTextField *mark;
@property (nonatomic, strong) NSTextField *title;
@property (nonatomic, strong) NSTextField *hint;
@property (nonatomic, strong) NSButton *button;
@end

@implementation SPOnboardingRow
@end

@interface SPOnboardingWindowController () <NSWindowDelegate>
@property (nonatomic, strong) SPPermissionManager *permissionManager;
@property (nonatomic, strong) SPLocalAsrOffer *localAsrOffer;
@property (nonatomic, strong) NSTimer *refreshTimer;
@property (nonatomic, strong) SPOnboardingRow *microphoneRow;
@property (nonatomic, strong) SPOnboardingRow *accessibilityRow;
@property (nonatomic, strong) SPOnboardingRow *inputMonitoringRow;
@property (nonatomic, strong) SPOnboardingRow *notificationsRow;
@property (nonatomic, strong) SPOnboardingRow *recognitionRow;
@property (nonatomic, strong) NSButton *keyHelpButton;
@property (nonatomic, strong) NSButton *localAsrButton;
@property (nonatomic, strong) NSTextField *tryInstruction;
@property (nonatomic, strong) NSTextField *fnWarning;
@property (nonatomic, strong) NSButton *fnWarningButton;
@property (nonatomic, strong) NSTextView *tryTextView;
@property (nonatomic, strong) NSTextField *tryResult;
@property (nonatomic, strong) NSMutableArray<NSView *> *sectionCaptions;
@end

@implementation SPOnboardingWindowController

+ (BOOL)shouldShowAtLaunch {
    return ![NSUserDefaults.standardUserDefaults boolForKey:kOnboardingDoneKey] && !recognitionReady();
}

- (instancetype)initWithPermissionManager:(SPPermissionManager *)permissionManager
                            localAsrOffer:(SPLocalAsrOffer *)localAsrOffer {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, kWindowWidth, 600)
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                     backing:NSBackingStoreBuffered
                                                       defer:YES];
    window.title = @"Начало работы";
    window.releasedWhenClosed = NO;
    self = [super initWithWindow:window];
    if (self) {
        _permissionManager = permissionManager;
        _localAsrOffer = localAsrOffer;
        window.delegate = self;
        [self buildContent];
    }
    return self;
}

#pragma mark - Layout

- (NSTextField *)labelWithString:(NSString *)string font:(NSFont *)font color:(NSColor *)color {
    NSTextField *label = [NSTextField wrappingLabelWithString:string];
    label.font = font;
    label.textColor = color;
    label.preferredMaxLayoutWidth = kWindowWidth - 2 * kContentInset - 140;
    return label;
}

- (NSTextField *)sectionCaption:(NSString *)text {
    NSTextField *caption = [NSTextField labelWithString:text];
    caption.font = SPTheme.cardTitleFont;
    caption.textColor = SPTheme.headingText;
    if (!self.sectionCaptions) self.sectionCaptions = [NSMutableArray array];
    [self.sectionCaptions addObject:caption];
    return caption;
}

- (NSButton *)buttonWithTitle:(NSString *)title action:(SEL)action {
    NSButton *button = [NSButton buttonWithTitle:title target:self action:action];
    button.bezelStyle = NSBezelStyleRounded;
    button.controlSize = NSControlSizeSmall;
    button.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    return button;
}

- (SPOnboardingRow *)rowWithTitle:(NSString *)title hint:(NSString *)hint button:(NSButton *)button {
    SPOnboardingRow *row = [[SPOnboardingRow alloc] init];
    row.mark = [NSTextField labelWithString:@"○"];
    row.mark.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
    [row.mark.widthAnchor constraintEqualToConstant:20].active = YES;
    row.title = [self labelWithString:title font:SPTheme.formLabelFont color:SPTheme.primaryText];
    row.hint = [self labelWithString:hint font:SPTheme.descriptionFont color:SPTheme.secondaryLabel];
    NSStackView *texts = [NSStackView stackViewWithViews:@[ row.title, row.hint ]];
    texts.orientation = NSUserInterfaceLayoutOrientationVertical;
    texts.alignment = NSLayoutAttributeLeading;
    texts.spacing = 1;
    row.button = button;
    NSMutableArray<NSView *> *views = [NSMutableArray arrayWithObjects:row.mark, texts, nil];
    NSView *spacer = [[NSView alloc] init];
    [spacer setContentHuggingPriority:NSLayoutPriorityDefaultLow - 1
                       forOrientation:NSLayoutConstraintOrientationHorizontal];
    [views addObject:spacer];
    if (button) [views addObject:button];
    row.view = [NSStackView stackViewWithViews:views];
    row.view.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.view.alignment = NSLayoutAttributeFirstBaseline;
    row.view.spacing = 8;
    return row;
}

- (void)buildContent {
    NSMutableArray<NSView *> *sections = [NSMutableArray array];

    NSTextField *title = [NSTextField labelWithAttributedString:[SPTheme titleString:@"Великий & Могучий" size:28]];
    NSTextField *lead = [self labelWithString:@"Зажмите клавишу и говорите — текст появится там, где стоит курсор. "
                                              @"Три шага, и можно диктовать."
                                         font:SPTheme.bodyFont
                                        color:SPTheme.label];
    lead.preferredMaxLayoutWidth = kWindowWidth - 2 * kContentInset;
    [sections addObjectsFromArray:@[ title, lead ]];

    [sections addObject:[self sectionCaption:@"1. Разрешения"]];
    self.microphoneRow = [self rowWithTitle:@"Микрофон"
                                       hint:@"Чтобы слышать вас."
                                     button:[self buttonWithTitle:@"Разрешить" action:@selector(grantMicrophone:)]];
    self.accessibilityRow =
        [self rowWithTitle:@"Универсальный доступ"
                      hint:@"Чтобы вставлять текст в другие приложения."
                    button:[self buttonWithTitle:@"Открыть настройки" action:@selector(grantAccessibility:)]];
    self.inputMonitoringRow =
        [self rowWithTitle:@"Мониторинг ввода"
                      hint:@"Чтобы клавиша диктовки работала в любом приложении."
                    button:[self buttonWithTitle:@"Открыть настройки" action:@selector(grantInputMonitoring:)]];
    self.notificationsRow =
        [self rowWithTitle:@"Уведомления (необязательно)"
                      hint:@"Объяснения ошибок. Без них коротко скажет плашка внизу экрана."
                    button:[self buttonWithTitle:@"Разрешить" action:@selector(grantNotifications:)]];
    for (SPOnboardingRow *row in @[ self.microphoneRow, self.accessibilityRow, self.inputMonitoringRow,
                                    self.notificationsRow ]) {
        [sections addObject:row.view];
    }

    [sections addObject:[self sectionCaption:@"2. Распознавание"]];
    self.recognitionRow = [self rowWithTitle:@"" hint:@"" button:nil];
    [sections addObject:self.recognitionRow.view];
    self.keyHelpButton = [self buttonWithTitle:@"Как получить ключ" action:@selector(openKeyHelp:)];
    NSButton *pasteKey = [self buttonWithTitle:@"Вставить ключ…" action:@selector(openRecognitionSettings:)];
    self.localAsrButton = [self buttonWithTitle:@"Распознавать на этом Mac" action:@selector(useLocalAsr:)];
    NSStackView *recognitionButtons =
        [NSStackView stackViewWithViews:@[ self.keyHelpButton, pasteKey, self.localAsrButton ]];
    recognitionButtons.spacing = 8;
    [sections addObject:recognitionButtons];

    [sections addObject:[self sectionCaption:@"3. Попробуйте"]];
    self.tryInstruction = [self labelWithString:@"" font:SPTheme.bodyFont color:SPTheme.label];
    self.tryInstruction.preferredMaxLayoutWidth = kWindowWidth - 2 * kContentInset;
    [sections addObject:self.tryInstruction];
    self.fnWarning = [self labelWithString:@"" font:SPTheme.descriptionFont color:SPTheme.warning];
    self.fnWarningButton = [self buttonWithTitle:@"Выбрать другую клавишу" action:@selector(openHotkeySettings:)];
    NSStackView *fnLine = [NSStackView stackViewWithViews:@[ self.fnWarning, self.fnWarningButton ]];
    fnLine.alignment = NSLayoutAttributeFirstBaseline;
    fnLine.spacing = 8;
    [sections addObject:fnLine];

    CGFloat fieldWidth = kWindowWidth - 2 * kContentInset;
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, fieldWidth, 76)];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    NSSize contentSize = scroll.contentSize;
    self.tryTextView =
        [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, contentSize.width, contentSize.height)];
    self.tryTextView.minSize = NSMakeSize(0, contentSize.height);
    self.tryTextView.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    self.tryTextView.verticallyResizable = YES;
    self.tryTextView.horizontallyResizable = NO;
    self.tryTextView.autoresizingMask = NSViewWidthSizable;
    self.tryTextView.textContainer.widthTracksTextView = YES;
    self.tryTextView.textContainer.containerSize = NSMakeSize(contentSize.width, CGFLOAT_MAX);
    self.tryTextView.font = [NSFont systemFontOfSize:14];
    self.tryTextView.richText = NO;
    self.tryTextView.textContainerInset = NSMakeSize(4, 6);
    scroll.documentView = self.tryTextView;
    [scroll.heightAnchor constraintEqualToConstant:76].active = YES;
    [scroll.widthAnchor constraintEqualToConstant:fieldWidth].active = YES;
    [sections addObject:scroll];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(tryTextChanged:)
                                               name:NSTextDidChangeNotification
                                             object:self.tryTextView];
    self.tryResult = [self labelWithString:@"" font:SPTheme.descriptionFont color:SPTheme.success];
    [sections addObject:self.tryResult];

    NSTextField *later = [self labelWithString:@"Это окно открывается снова из меню значка: «Начало работы…»."
                                          font:SPTheme.descriptionFont
                                         color:SPTheme.secondaryLabel];
    NSButton *done = [NSButton buttonWithTitle:@"Готово" target:self action:@selector(finish:)];
    done.bezelStyle = NSBezelStyleRounded;
    done.keyEquivalent = @"\r";
    NSView *spacer = [[NSView alloc] init];
    [spacer setContentHuggingPriority:NSLayoutPriorityDefaultLow - 1
                       forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *footer = [NSStackView stackViewWithViews:@[ later, spacer, done ]];
    footer.alignment = NSLayoutAttributeCenterY;
    [sections addObject:footer];

    NSStackView *stack = [NSStackView stackViewWithViews:sections];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 10;
    stack.edgeInsets = NSEdgeInsetsMake(22, kContentInset, 22, kContentInset);
    for (NSView *view in @[ lead, recognitionButtons, fnLine, footer ]) {
        [view.widthAnchor constraintLessThanOrEqualToConstant:kWindowWidth - 2 * kContentInset].active = YES;
    }
    for (SPOnboardingRow *row in @[ self.microphoneRow, self.accessibilityRow, self.inputMonitoringRow,
                                    self.notificationsRow, self.recognitionRow ]) {
        [row.view.widthAnchor constraintEqualToConstant:kWindowWidth - 2 * kContentInset].active = YES;
    }
    [footer.widthAnchor constraintEqualToConstant:kWindowWidth - 2 * kContentInset].active = YES;
    // Extra air above each section caption.
    for (NSView *caption in self.sectionCaptions) {
        NSUInteger index = [sections indexOfObject:caption];
        if (index != NSNotFound && index > 0) [stack setCustomSpacing:18 afterView:sections[index - 1]];
    }

    stack.translatesAutoresizingMaskIntoConstraints = NO;
    NSView *content = [[NSView alloc] init];
    [content addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:content.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
        [content.widthAnchor constraintEqualToConstant:kWindowWidth],
    ]];
    self.window.contentView = content;
}

#pragma mark - State

- (void)setRow:(SPOnboardingRow *)row done:(BOOL)done {
    row.mark.stringValue = done ? @"✓" : @"○";
    row.mark.textColor = done ? SPTheme.success : SPTheme.secondaryLabel;
    row.button.hidden = done;
}

- (void)refresh {
    [self setRow:self.microphoneRow done:[self.permissionManager isMicrophoneGranted]];
    [self setRow:self.accessibilityRow done:[self.permissionManager isAccessibilityGranted]];
    [self setRow:self.inputMonitoringRow done:[self.permissionManager isInputMonitoringGranted]];
    __weak typeof(self) weakSelf = self;
    [self.permissionManager checkNotificationPermissionWithCompletion:^(BOOL granted) {
        [weakSelf setRow:weakSelf.notificationsRow done:granted];
    }];

    NSDictionary *asr = [SPLocalAsrOffer currentAsrConfig];
    NSString *provider = [asr[@"provider"] isKindOfClass:[NSString class]] ? asr[@"provider"] : @"qwen";
    BOOL local = [SPLocalAsrPolicy isLocalProvider:provider];
    BOOL ready = recognitionReady();
    [self setRow:self.recognitionRow done:ready];
    if (local) {
        self.recognitionRow.title.stringValue = @"Распознавание на этом Mac";
        self.recognitionRow.hint.stringValue = @"Звук никуда не уходит. Облачное распознавание точнее: ключ "
                                               @"можно указать в настройках в любой момент.";
    } else if (ready) {
        self.recognitionRow.title.stringValue =
            [provider isEqualToString:@"qwen"] ? @"Ключ DashScope указан" : @"Ключ распознавания указан";
        self.recognitionRow.hint.stringValue = @"Проверить его можно в настройках: «Проверить ключ».";
    } else {
        self.recognitionRow.title.stringValue = @"Нужен ключ DashScope";
        self.recognitionRow.hint.stringValue =
            @"Речь распознают модели Qwen в облаке Alibaba Cloud по вашему ключу. Без ключа можно "
            @"распознавать прямо на этом Mac: хуже, но бесплатно и без интернета.";
    }
    self.keyHelpButton.hidden = ready && !local;
    self.localAsrButton.hidden = ready || ![self.localAsrOffer canSwitchToLocalAsr];

    NSString *triggerValue = configString("hotkey.trigger_key");
    NSString *keyName = SPHotkeyShortName(triggerValue);
    NSString *mode = configString("hotkey.trigger_mode");
    NSString *instruction;
    if (!keyName) {
        instruction = @"Нажмите клавишу диктовки (её видно в «Настройки → Управление»), скажите фразу — "
                      @"текст появится в поле ниже.";
    } else if ([mode isEqualToString:@"toggle"] || [mode isEqualToString:@"auto"]) {
        instruction = [NSString stringWithFormat:@"Нажмите %@, скажите фразу и нажмите %@ ещё раз — текст "
                                                 @"появится в поле ниже.", keyName, keyName];
    } else if ([mode isEqualToString:@"double_tap"]) {
        instruction = [NSString stringWithFormat:@"Дважды нажмите %@, скажите фразу и нажмите %@ ещё раз — "
                                                 @"текст появится в поле ниже.", keyName, keyName];
    } else {
        instruction = [NSString stringWithFormat:@"Зажмите %@, скажите фразу и отпустите — текст появится в "
                                                 @"поле ниже.", keyName];
    }
    self.tryInstruction.stringValue = instruction;

    NSString *conflict = [[triggerValue lowercaseString] isEqualToString:@"fn"] ? SPFnUsageConflict(SPFnUsageType()) : nil;
    self.fnWarning.stringValue = conflict ? [NSString stringWithFormat:@"Сейчас 🌐 при нажатии ещё и %@.", conflict] : @"";
    self.fnWarning.hidden = conflict == nil;
    self.fnWarningButton.hidden = conflict == nil;
    [self fitWindowToContent];
}

/// Texts and buttons come and go with the state; the window keeps its top edge.
- (void)fitWindowToContent {
    NSView *content = self.window.contentView;
    [content layoutSubtreeIfNeeded];
    NSSize fitting = content.fittingSize;
    if (fabs(fitting.height - NSHeight(content.frame)) < 1) return;
    NSRect frame = [self.window frameRectForContentRect:NSMakeRect(0, 0, fitting.width, fitting.height)];
    frame.origin.x = NSMinX(self.window.frame);
    frame.origin.y = NSMaxY(self.window.frame) - NSHeight(frame);
    [self.window setFrame:frame display:YES];
}

- (void)tryTextChanged:(NSNotification *)notification {
    NSString *text = [self.tryTextView.string
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    self.tryResult.stringValue = text.length > 0 ? @"✓ Получилось. Так же текст вставится в любом приложении." : @"";
}

#pragma mark - Actions

- (void)grantMicrophone:(id)sender {
    if ([self.permissionManager isMicrophoneUndetermined]) {
        __weak typeof(self) weakSelf = self;
        [self.permissionManager requestMicrophonePermissionWithCompletion:^(BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf refresh];
            });
        }];
        return;
    }
    [[NSWorkspace sharedWorkspace] openURL:[SPPermissionManager settingsURLForType:SPPermissionTypeMicrophone]];
}

- (void)grantAccessibility:(id)sender {
    [self.permissionManager requestAccessibilityPermission];
    [[NSWorkspace sharedWorkspace] openURL:[SPPermissionManager settingsURLForType:SPPermissionTypeAccessibility]];
}

- (void)grantInputMonitoring:(id)sender {
    [[NSWorkspace sharedWorkspace] openURL:[SPPermissionManager settingsURLForType:SPPermissionTypeInputMonitoring]];
}

- (void)grantNotifications:(id)sender {
    [self.permissionManager requestNotificationPermission];
}

- (void)openKeyHelp:(id)sender {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:kDashScopeKeyHelpURL]];
}

- (void)openRecognitionSettings:(id)sender {
    if (self.openSettingsPane) self.openSettingsPane(@"asr");
}

- (void)openHotkeySettings:(id)sender {
    if (self.openSettingsPane) self.openSettingsPane(@"hotkey");
}

- (void)useLocalAsr:(id)sender {
    [self.localAsrOffer switchToLocalAsrOnUserRequest];
}

- (void)finish:(id)sender {
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:kOnboardingDoneKey];
    [self.window performClose:nil];
}

#pragma mark - Window

- (void)present {
    [self refresh];
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [self.window makeFirstResponder:self.tryTextView];
    [self.refreshTimer invalidate];
    __weak typeof(self) weakSelf = self;
    // Grants and keys change in System Settings and the Settings window: the checklist follows them.
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.5
                                                        repeats:YES
                                                          block:^(NSTimer *timer) {
        [weakSelf refresh];
    }];
}

- (void)windowWillClose:(NSNotification *)notification {
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
    // Closed with everything in place counts as finished, so it does not come back at launch.
    if (recognitionReady()) {
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:kOnboardingDoneKey];
    }
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_refreshTimer invalidate];
}

@end
