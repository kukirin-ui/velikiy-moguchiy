#import "SPStatusBarManager.h"
#import "SPPermissionManager.h"
#import "SPAudioDeviceManager.h"
#import "SPHistoryManager.h"
#import "SPLocalization.h"
#import "SPOutputModes.h"
#import "SPLipCaptureManager.h"
#import "velikiy_moguchiy_core.h"
#import "SPAppPaths.h"
#import "SPTheme.h"
#import "SPSettingsViews.h"
#import <Cocoa/Cocoa.h>
#import <ServiceManagement/ServiceManagement.h>
#import <UserNotifications/UserNotifications.h>

// Icon size for menu bar (points)
static const CGFloat kIconSize = 18.0;
static const NSInteger kHeaderItemTag = 1001;

@interface SPStatusBarManager ()

@property (nonatomic, weak) id<SPStatusBarDelegate> delegate;
@property (nonatomic, strong) SPPermissionManager *permissionManager;
@property (nonatomic, strong) SPAudioDeviceManager *audioDeviceManager;
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSMenuItem *permissionsWarningItem;
@property (nonatomic, strong) NSMenuItem *microphoneItem;
@property (nonatomic, strong) NSMenuItem *voiceInputItem;
@property (nonatomic, strong) NSMenuItem *statsItem;
@property (nonatomic, strong) NSMenuItem *outputModeItem;
@property (nonatomic, strong) NSMenuItem *appUpdateItem;
@property (nonatomic, strong) NSMenuItem *lipsModelUpdateItem;
@property (nonatomic, strong) NSTimer *animationTimer;
@property (nonatomic, assign) NSInteger animationFrame;
@property (nonatomic, copy) NSString *currentState;
@property (nonatomic, strong) NSMenu *previewMenu;

@end


@implementation SPStatusBarManager

- (instancetype)initWithDelegate:(id<SPStatusBarDelegate>)delegate
               permissionManager:(SPPermissionManager *)permissionManager
              audioDeviceManager:(SPAudioDeviceManager *)audioDeviceManager {
    self = [super init];
    if (self) {
        _delegate = delegate;
        _permissionManager = permissionManager;
        _audioDeviceManager = audioDeviceManager;
        _currentState = @"idle";
        _animationFrame = 0;
        [self setupStatusBar];
    }
    return self;
}

- (void)setupStatusBar {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
    self.statusItem.button.toolTip = @"Великий & Могучий";
    self.statusItem.button.accessibilityLabel = @"Великий & Могучий";

    [self applyIdleIcon];
    self.statusItem.menu = [self buildMenu];
}

- (instancetype)initMenuOnlyWithPermissionManager:(SPPermissionManager *)permissionManager
                               audioDeviceManager:(SPAudioDeviceManager *)audioDeviceManager {
    self = [super init];
    if (self) {
        _permissionManager = permissionManager;
        _audioDeviceManager = audioDeviceManager;
        _currentState = @"idle";
        _previewMenu = [self buildMenu];
        [self refreshVoiceInputItem];
    }
    return self;
}

- (NSMenu *)buildMenu {
    NSMenu *menu = [[NSMenu alloc] init];
    menu.delegate = self;
    menu.autoenablesItems = NO;

    [menu addItem:[self headerItem]];

    self.voiceInputItem = [[NSMenuItem alloc] initWithTitle:@"Начать диктовку"
                                                     action:@selector(toggleVoiceInput:)
                                              keyEquivalent:@""];
    self.voiceInputItem.target = self;
    self.voiceInputItem.image = [self menuSymbol:@"mic"];
    [menu addItem:self.voiceInputItem];

    NSMenuItem *recentDictations = [[NSMenuItem alloc] initWithTitle:SPLocalizedString(@"statusBar.menu.recentDictations")
                                                              action:@selector(openRecentDictations:)
                                                       keyEquivalent:@""];
    recentDictations.target = self;
    recentDictations.image = [self menuSymbol:@"scroll"];
    [menu addItem:recentDictations];

    [menu addItem:[self ornamentSeparatorItem]];

    self.appUpdateItem = [[NSMenuItem alloc] initWithTitle:@"Доступна новая версия"
                                                    action:@selector(openAppUpdate:)
                                             keyEquivalent:@""];
    self.appUpdateItem.target = self;
    self.appUpdateItem.image = [self menuSymbol:@"arrow.down.circle"];
    self.appUpdateItem.hidden = YES;
    [menu addItem:self.appUpdateItem];

    self.lipsModelUpdateItem = [[NSMenuItem alloc] initWithTitle:@"Новая модель губ"
                                                          action:@selector(updateLipsModel:)
                                                   keyEquivalent:@""];
    self.lipsModelUpdateItem.target = self;
    self.lipsModelUpdateItem.image = [self menuSymbol:@"arrow.down.circle"];
    self.lipsModelUpdateItem.hidden = YES;
    [menu addItem:self.lipsModelUpdateItem];

    self.permissionsWarningItem = [[NSMenuItem alloc] initWithTitle:@"⚠︎ Нужны разрешения…"
                                                             action:@selector(fixMissingPermission:)
                                                      keyEquivalent:@""];
    self.permissionsWarningItem.target = self;
    self.permissionsWarningItem.hidden = YES;
    [menu addItem:self.permissionsWarningItem];

    // Microphone selection submenu (filled in menuWillOpen)
    self.microphoneItem = [[NSMenuItem alloc] initWithTitle:@"Микрофон"
                                                     action:nil
                                              keyEquivalent:@""];
    self.microphoneItem.submenu = [[NSMenu alloc] initWithTitle:@"Микрофон"];
    self.microphoneItem.image = [self menuSymbol:@"music.mic"];
    [menu addItem:self.microphoneItem];

    NSMenuItem *onboarding = [[NSMenuItem alloc] initWithTitle:@"Начало работы…"
                                                       action:@selector(openOnboarding:)
                                                keyEquivalent:@""];
    onboarding.target = self;
    onboarding.image = [self menuSymbol:@"checklist"];
    [menu addItem:onboarding];

    NSMenuItem *setupWizard = [[NSMenuItem alloc] initWithTitle:@"Настройки…"
                                                        action:@selector(openSetupWizard:)
                                                 keyEquivalent:@","];
    setupWizard.target = self;
    setupWizard.image = [self menuSymbol:@"gearshape"];
    [menu addItem:setupWizard];

    NSMenuItem *reportProblem = [[NSMenuItem alloc] initWithTitle:@"Сообщить о проблеме…"
                                                           action:@selector(reportProblem:)
                                                    keyEquivalent:@""];
    reportProblem.target = self;
    reportProblem.image = [self menuSymbol:@"exclamationmark.bubble"];
    [menu addItem:reportProblem];

    // More submenu
    NSMenuItem *moreItem = [[NSMenuItem alloc] initWithTitle:@"Ещё" action:nil keyEquivalent:@""];
    NSMenu *moreSubmenu = [[NSMenu alloc] initWithTitle:@"Ещё"];
    moreSubmenu.autoenablesItems = NO;
    moreItem.submenu = moreSubmenu;
    moreItem.image = [self menuSymbol:@"ellipsis.circle"];
    [menu addItem:moreItem];

    self.outputModeItem = [[NSMenuItem alloc] initWithTitle:@"Режим текста" action:nil keyEquivalent:@""];
    NSMenu *outputModeSubmenu = [[NSMenu alloc] initWithTitle:@"Режим текста"];
    outputModeSubmenu.autoenablesItems = NO;
    for (NSString *mode in SPOutputModeIds()) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:SPOutputModeTitle(mode)
                                                      action:@selector(selectOutputMode:)
                                               keyEquivalent:@""];
        item.target = self;
        item.representedObject = mode;
        [outputModeSubmenu addItem:item];
    }
    self.outputModeItem.submenu = outputModeSubmenu;
    [moreSubmenu addItem:self.outputModeItem];

    NSMenuItem *undoItem = [[NSMenuItem alloc] initWithTitle:@"Отменить последнюю вставку"
                                                      action:@selector(undoLastInsertion:)
                                               keyEquivalent:@""];
    undoItem.target = self;
    [moreSubmenu addItem:undoItem];
    NSMenuItem *repasteItem = [[NSMenuItem alloc] initWithTitle:@"Вставить последнюю диктовку"
                                                         action:@selector(repasteLastDictation:)
                                                  keyEquivalent:@""];
    repasteItem.target = self;
    [moreSubmenu addItem:repasteItem];
    [moreSubmenu addItem:[NSMenuItem separatorItem]];

    self.statsItem = [[NSMenuItem alloc] initWithTitle:@"Статистика: …" action:nil keyEquivalent:@""];
    self.statsItem.enabled = NO;
    [moreSubmenu addItem:self.statsItem];

    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    NSString *version = info[@"CFBundleShortVersionString"] ?: @"?";
    NSString *build = info[@"CFBundleVersion"] ?: @"?";
    NSMenuItem *versionItem = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Версия %@ (%@)", version, build]
                                                         action:nil
                                                  keyEquivalent:@""];
    versionItem.enabled = NO;
    [moreSubmenu addItem:versionItem];

    NSMenuItem *openConfig = [[NSMenuItem alloc] initWithTitle:@"Открыть папку настроек…"
                                                       action:@selector(openConfigFolder:)
                                                keyEquivalent:@""];
    openConfig.target = self;
    [moreSubmenu addItem:openConfig];

    NSMenuItem *loginItem = [[NSMenuItem alloc] initWithTitle:@"Запускать при входе"
                                                      action:@selector(toggleLaunchAtLogin:)
                                               keyEquivalent:@""];
    loginItem.target = self;
    if (@available(macOS 13.0, *)) {
        loginItem.state = (SMAppService.mainAppService.status == SMAppServiceStatusEnabled)
                          ? NSControlStateValueOn : NSControlStateValueOff;
    }
    [moreSubmenu addItem:loginItem];

    [menu addItem:[self ornamentSeparatorItem]];

    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Выйти"
                                                 action:@selector(quitApp:)
                                          keyEquivalent:@"q"];
    quit.target = self;
    quit.image = [self menuSymbol:@"power"];
    [menu addItem:quit];
    return menu;
}

- (NSMenu *)menu {
    return self.statusItem.menu ?: self.previewMenu;
}

- (NSView *)designPreviewView {
    NSMenu *menu = self.menu;
    CGFloat width = 280, rowH = 24, y = 6;
    NSMutableArray<NSView *> *rows = [NSMutableArray array];
    for (NSMenuItem *item in menu.itemArray) {
        if (item.hidden) continue;
        NSView *row;
        if (item.view) {
            // Fresh copies: a view that belongs to a menu item is laid out by the menu.
            row = item.tag == kHeaderItemTag ? [self headerItem].view : [self ornamentSeparatorItem].view;
            [row removeFromSuperview];
            row.frame = NSMakeRect(0, 0, width, NSHeight(row.frame));
        } else if (item.isSeparatorItem) {
            row = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, 11)];
            NSBox *line = [[NSBox alloc] initWithFrame:NSMakeRect(12, 5, width - 24, 1)];
            line.boxType = NSBoxSeparator;
            [row addSubview:line];
        } else {
            row = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, rowH)];
            if (item.image) {
                NSImageView *icon = [NSImageView imageViewWithImage:item.image];
                icon.contentTintColor = NSColor.labelColor;
                icon.frame = NSMakeRect(12, 4, 16, 16);
                [row addSubview:icon];
            }
            NSTextField *title = [NSTextField labelWithString:item.title];
            title.font = [NSFont menuFontOfSize:0];
            title.textColor = item.enabled ? NSColor.labelColor : NSColor.disabledControlTextColor;
            title.frame = NSMakeRect(36, 3, width - 90, 18);
            [row addSubview:title];
            NSString *trailing = item.submenu ? @"›"
                : item.keyEquivalent.length > 0 ? [@"⌘" stringByAppendingString:item.keyEquivalent.uppercaseString]
                : @"";
            NSTextField *right = [NSTextField labelWithString:trailing];
            right.font = [NSFont menuFontOfSize:0];
            right.textColor = NSColor.secondaryLabelColor;
            right.alignment = NSTextAlignmentRight;
            right.frame = NSMakeRect(width - 60, 3, 46, 18);
            [row addSubview:right];
        }
        [rows addObject:row];
        y += NSHeight(row.frame);
    }
    y += 6;
    NSVisualEffectView *plate = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, width, y)];
    plate.material = NSVisualEffectMaterialMenu;
    plate.state = NSVisualEffectStateActive;
    plate.wantsLayer = YES;
    plate.layer.cornerRadius = 10;
    plate.layer.masksToBounds = YES;
    // Material does not draw into an offscreen snapshot; a solid menu-coloured
    // fill under the rows keeps the preview readable either way.
    NSBox *fill = [[NSBox alloc] initWithFrame:plate.bounds];
    fill.boxType = NSBoxCustom;
    fill.borderWidth = 0;
    fill.fillColor = [NSColor.windowBackgroundColor colorWithAlphaComponent:0.97];
    [plate addSubview:fill];
    CGFloat top = y - 6;
    for (NSView *row in rows) {
        top -= NSHeight(row.frame);
        [row setFrameOrigin:NSMakePoint(0, top)];
        [plate addSubview:row];
    }
    return plate;
}

#pragma mark - Menu decoration

/// The menu's title plate: the logo (vyaz with gilded capitals) over a divider.
- (NSMenuItem *)headerItem {
    NSView *plate = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 260, 64)];
    NSImage *logo = [NSImage imageNamed:@"Logo"];
    NSImageView *title = [NSImageView imageViewWithImage:logo];
    title.imageScaling = NSImageScaleProportionallyUpOrDown;
    title.frame = NSMakeRect(16, 22, 228, 38);
    title.accessibilityLabel = @"Великий & Могучий";
    title.autoresizingMask = NSViewWidthSizable;
    [plate addSubview:title];
    SPOrnamentDividerView *divider = [[SPOrnamentDividerView alloc] initWithFrame:NSMakeRect(16, 2, 228, 20)];
    divider.autoresizingMask = NSViewWidthSizable;
    [plate addSubview:divider];
    plate.autoresizingMask = NSViewWidthSizable;
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"Великий & Могучий" action:nil keyEquivalent:@""];
    item.view = plate;
    item.enabled = NO;
    item.tag = kHeaderItemTag;
    return item;
}

/// A separator drawn as a Bilibin divider: ochre rules out of a rosette.
- (NSMenuItem *)ornamentSeparatorItem {
    SPOrnamentDividerView *divider = [[SPOrnamentDividerView alloc] initWithFrame:NSMakeRect(0, 0, 260, 16)];
    divider.autoresizingMask = NSViewWidthSizable;
    NSView *wrap = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 260, 16)];
    divider.frame = NSInsetRect(wrap.bounds, 14, 0);
    [wrap addSubview:divider];
    wrap.autoresizingMask = NSViewWidthSizable;
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    item.view = wrap;
    item.enabled = NO;
    return item;
}

- (NSImage *)menuSymbol:(NSString *)name {
    NSImage *image = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    NSImageSymbolConfiguration *config =
        [NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightRegular];
    return [image imageWithSymbolConfiguration:config] ?: image;
}

#pragma mark - NSMenuDelegate

- (void)menuWillOpen:(NSMenu *)menu {
    [self refreshPermissionStatus];
    [self refreshStats];
    [self refreshOutputModeSubmenu];
    [self refreshMicrophoneSubmenu];
    if ([self.delegate respondsToSelector:@selector(statusBarMenuDidOpen)]) {
        [self.delegate statusBarMenuDidOpen];
    }
}

- (void)menuDidClose:(NSMenu *)menu {
    if ([self.delegate respondsToSelector:@selector(statusBarMenuDidClose)]) {
        [self.delegate statusBarMenuDidClose];
    }
}

#pragma mark - Permissions

/// Notifications are optional and never raise the warning.
- (void)refreshPermissionStatus {
    BOOL mic = [self.permissionManager isMicrophoneGranted];
    BOOL ax = [self.permissionManager isAccessibilityGranted];
    BOOL input = [self.permissionManager isInputMonitoringGranted];
    NSLog(@"[VelikiyMoguchiy] Permissions: mic=%d ax=%d input=%d", mic, ax, input);

    NSMutableArray<NSString *> *missingNames = [NSMutableArray array];
    if (!mic) [missingNames addObject:@"Микрофон"];
    if (!ax) [missingNames addObject:@"Универсальный доступ"];
    if (!input) [missingNames addObject:@"Мониторинг ввода"];
    // The camera is only needed while lip-reading data collection is switched on.
    BOOL lipdataOn = [SPLipCaptureManager isFeatureEnabled];
    BOOL camera = !lipdataOn || [self.permissionManager isCameraGranted];
    if (!camera) [missingNames addObject:@"Камера"];
    self.permissionsWarningItem.hidden = missingNames.count == 0;
    if (missingNames.count > 0) {
        self.permissionsWarningItem.title =
            [NSString stringWithFormat:@"⚠︎ Нет доступа: %@", [missingNames componentsJoinedByString:@", "]];
    }
}

/// Same action the old per-permission rows had, for the first missing one.
- (void)fixMissingPermission:(id)sender {
    if (![self.permissionManager isMicrophoneGranted]) {
        [self openMicrophoneSettings];
    } else if (![self.permissionManager isAccessibilityGranted]) {
        [self requestAccessibilityPermission];
    } else if (![self.permissionManager isInputMonitoringGranted]) {
        [self openInputMonitoringSettings];
    } else if ([SPLipCaptureManager isFeatureEnabled] && ![self.permissionManager isCameraGranted]) {
        // First use: the system prompt (this click is the user's own action);
        // after a refusal only System Settings can grant it.
        if ([SPLipCaptureManager authorizationStatus] == AVAuthorizationStatusNotDetermined) {
            [SPLipCaptureManager requestAccessIfNeeded:nil];
        } else {
            [self openCameraSettings];
        }
    }
}

- (void)openCameraSettings {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"]];
}

- (void)openMicrophoneSettings {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"]];
}

- (void)requestAccessibilityPermission {
    [self.permissionManager requestAccessibilityPermission];
}

- (void)openInputMonitoringSettings {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"]];
}

#pragma mark - Output mode

/// A checkmark on the global mode. Apps with a mode of their own still use it.
- (void)refreshOutputModeSubmenu {
    char *raw = sp_config_get("asr.qwen.output_mode");
    NSString *current = raw ? [NSString stringWithUTF8String:raw] : nil;
    if (raw) sp_core_free_string(raw);
    NSString *normalized = SPNormalizedOutputMode(current);
    for (NSMenuItem *item in self.outputModeItem.submenu.itemArray) {
        item.state = [item.representedObject isEqualToString:normalized]
                         ? NSControlStateValueOn
                         : NSControlStateValueOff;
    }
}

- (void)undoLastInsertion:(NSMenuItem *)sender {
    if ([self.delegate respondsToSelector:@selector(statusBarDidSelectUndoLastInsertion)]) {
        [self.delegate statusBarDidSelectUndoLastInsertion];
    }
}

- (void)repasteLastDictation:(NSMenuItem *)sender {
    if ([self.delegate respondsToSelector:@selector(statusBarDidSelectRepasteLastDictation)]) {
        [self.delegate statusBarDidSelectRepasteLastDictation];
    }
}

- (void)selectOutputMode:(NSMenuItem *)sender {
    if ([self.delegate respondsToSelector:@selector(statusBarDidSelectOutputMode:)]) {
        [self.delegate statusBarDidSelectOutputMode:sender.representedObject];
    }
}

#pragma mark - Statistics

- (void)refreshStats {
    SPHistoryStats *stats = [[SPHistoryManager sharedManager] aggregateStats];

    NSMutableArray *parts = [NSMutableArray array];

    NSMutableArray *counts = [NSMutableArray array];
    if (stats.totalCharCount > 0) {
        [counts addObject:[NSString stringWithFormat:@"%ld симв.", (long)stats.totalCharCount]];
    }
    if (stats.totalWordCount > 0) {
        [counts addObject:[NSString stringWithFormat:@"%ld сл.", (long)stats.totalWordCount]];
    }
    if (counts.count > 0) {
        [parts addObject:[counts componentsJoinedByString:@" / "]];
    }

    if (stats.sessionCount > 0) {
        NSInteger totalSec = stats.totalDurationMs / 1000;
        [parts addObject:[NSString stringWithFormat:@"%ld мин %ld с, %ld диктовок",
                          (long)(totalSec / 60), (long)(totalSec % 60), (long)stats.sessionCount]];
    }

    if (stats.totalDurationMs > 0 && (stats.totalCharCount + stats.totalWordCount) > 0) {
        double minutes = (double)stats.totalDurationMs / 60000.0;
        if (stats.totalCharCount > stats.totalWordCount) {
            [parts addObject:[NSString stringWithFormat:@"%.0f симв./мин", (double)stats.totalCharCount / minutes]];
        } else {
            [parts addObject:[NSString stringWithFormat:@"%.0f сл./мин", (double)stats.totalWordCount / minutes]];
        }
    }

    self.statsItem.title = parts.count > 0
        ? [@"Статистика: " stringByAppendingString:[parts componentsJoinedByString:@" · "]]
        : @"Статистика: пока нет данных";
}

#pragma mark - Microphone Selection

- (void)refreshMicrophoneSubmenu {
    NSMenu *submenu = self.microphoneItem.submenu;
    [submenu removeAllItems];

    NSString *selectedUID = self.audioDeviceManager.selectedDeviceUID;
    NSArray<SPAudioInputDevice *> *devices = [self.audioDeviceManager availableInputDevices];

    // Check if selected device is currently available
    BOOL selectedFound = NO;
    if (selectedUID) {
        for (SPAudioInputDevice *device in devices) {
            if ([device.uid isEqualToString:selectedUID]) {
                selectedFound = YES;
                break;
            }
        }
    }

    // "System Default" option
    NSMenuItem *defaultItem = [[NSMenuItem alloc] initWithTitle:SPLocalizedString(@"statusBar.menu.systemDefault")
                                                        action:@selector(selectAudioDevice:)
                                                 keyEquivalent:@""];
    defaultItem.target = self;
    defaultItem.representedObject = nil;
    defaultItem.state = (selectedUID == nil) ? NSControlStateValueOn : NSControlStateValueOff;
    [submenu addItem:defaultItem];

    if (devices.count > 0) {
        [submenu addItem:[NSMenuItem separatorItem]];
    }

    // Available input devices
    // NOTE: Only device.name is shown. If the user has multiple devices with identical
    // names (e.g. two identical USB mics), they cannot be distinguished visually.
    // A future improvement could append a disambiguator (manufacturer, UID suffix, etc.).
    for (SPAudioInputDevice *device in devices) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:device.name
                                                      action:@selector(selectAudioDevice:)
                                               keyEquivalent:@""];
        item.target = self;
        item.representedObject = device.uid;
        item.state = [device.uid isEqualToString:selectedUID] ? NSControlStateValueOn : NSControlStateValueOff;
        [submenu addItem:item];
    }

    // Show disconnected but still-selected device as a greyed-out item
    if (selectedUID && !selectedFound) {
        NSString *deviceName = self.audioDeviceManager.selectedDeviceName ?: selectedUID;
        [submenu addItem:[NSMenuItem separatorItem]];
        NSMenuItem *unavailableItem = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:SPLocalizedString(@"statusBar.menu.unavailable"), deviceName]
                                                                action:nil
                                                         keyEquivalent:@""];
        unavailableItem.state = NSControlStateValueOn;
        unavailableItem.enabled = NO;
        [submenu addItem:unavailableItem];
    }
}

- (void)selectAudioDevice:(NSMenuItem *)sender {
    NSString *uid = sender.representedObject;
    NSString *name = uid ? sender.title : nil;
    [self.audioDeviceManager selectDevice:uid name:name];
    NSLog(@"[VelikiyMoguchiy] Audio device selected: %@", uid ?: @"System Default");

    if ([self.delegate respondsToSelector:@selector(statusBarDidSelectAudioDeviceWithUID:)]) {
        [self.delegate statusBarDidSelectAudioDeviceWithUID:uid];
    }
}

#pragma mark - Custom Icon Drawing

/// Create a template image drawn with the given block. Template images auto-adapt to dark/light mode.
- (NSImage *)templateImageWithDrawing:(void (^)(NSSize size))drawBlock {
    NSSize size = NSMakeSize(kIconSize, kIconSize);
    NSImage *image = [NSImage imageWithSize:size flipped:NO drawingHandler:^BOOL(NSRect rect) {
        drawBlock(size);
        return YES;
    }];
    image.template = YES;
    return image;
}

/// The octagonal frame of the menu bar mark (MenuBarIcon.pdf), so every state
/// keeps the same silhouette and only its contents change.
- (void)strokeMarkFrameInSize:(NSSize)size {
    CGFloat s = size.width, k = 3.5;
    NSBezierPath *frame = [NSBezierPath bezierPath];
    [frame moveToPoint:NSMakePoint(k, 1.2)];
    [frame lineToPoint:NSMakePoint(s - k, 1.2)];
    [frame lineToPoint:NSMakePoint(s - 1.2, k)];
    [frame lineToPoint:NSMakePoint(s - 1.2, s - k)];
    [frame lineToPoint:NSMakePoint(s - k, s - 1.2)];
    [frame lineToPoint:NSMakePoint(k, s - 1.2)];
    [frame lineToPoint:NSMakePoint(1.2, s - k)];
    [frame lineToPoint:NSMakePoint(1.2, k)];
    [frame closePath];
    frame.lineWidth = 1.5;
    frame.lineJoinStyle = NSLineJoinStyleRound;
    [[NSColor blackColor] set];
    [frame stroke];
    for (NSValue *v in @[ [NSValue valueWithPoint:NSMakePoint(s / 2, 0.2)],
                          [NSValue valueWithPoint:NSMakePoint(s / 2, s - 0.2)],
                          [NSValue valueWithPoint:NSMakePoint(0.2, s / 2)],
                          [NSValue valueWithPoint:NSMakePoint(s - 0.2, s / 2)] ]) {
        NSPoint p = v.pointValue;
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(p.x - 1.05, p.y - 1.05, 2.1, 2.1)] fill];
    }
}

/// Idle: the cinnabar-initial mark, «В» in its frame (a template image).
- (void)applyIdleIcon {
    NSImage *icon = [NSImage imageNamed:@"MenuBarIcon"];
    if (!icon) {
        icon = [self templateImageWithDrawing:^(NSSize size) {
            [self strokeMarkFrameInSize:size];
        }];
    }
    icon.size = NSMakeSize(kIconSize, kIconSize);
    icon.template = YES;
    self.statusItem.button.image = icon;
}

/// Recording: animated waveform bars with varying heights — voice activity
- (void)applyRecordingIconWithFrame:(NSInteger)frame {
    // 5 bars, heights shift each frame to create a wave animation
    NSImage *icon = [self templateImageWithDrawing:^(NSSize size) {
        [self strokeMarkFrameInSize:size];
        CGFloat barWidth = 1.6;
        CGFloat spacing = 1.3;
        CGFloat centerX = size.width / 2.0;
        CGFloat centerY = size.height / 2.0;
        NSInteger barCount = 4;

        CGFloat totalWidth = barCount * barWidth + (barCount - 1) * spacing;
        CGFloat startX = centerX - totalWidth / 2.0;

        [[NSColor blackColor] setFill];
        for (NSInteger i = 0; i < barCount; i++) {
            // Sine wave pattern that shifts with frame
            double phase = (double)(i + frame) * 0.8;
            CGFloat h = 3.0 + 6.0 * fabs(sin(phase));
            CGFloat x = startX + i * (barWidth + spacing);
            CGFloat y = centerY - h / 2.0;
            NSBezierPath *bar = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x, y, barWidth, h)
                                                               xRadius:barWidth / 2.0
                                                               yRadius:barWidth / 2.0];
            [bar fill];
        }
    }];
    self.statusItem.button.image = icon;
}

/// Processing: pulsing dot pattern (thinking/working)
- (void)applyProcessingIconWithFrame:(NSInteger)frame {
    NSImage *icon = [self templateImageWithDrawing:^(NSSize size) {
        CGFloat centerY = size.height / 2.0;
        CGFloat centerX = size.width / 2.0;
        [self strokeMarkFrameInSize:size];
        CGFloat dotSpacing = 4.0;
        NSInteger dotCount = 3;
        CGFloat totalWidth = (dotCount - 1) * dotSpacing;
        CGFloat startX = centerX - totalWidth / 2.0;

        for (NSInteger i = 0; i < dotCount; i++) {
            // Cascade: each dot pulses in sequence
            double phase = (double)(frame - i) * 0.7;
            CGFloat radius = 1.1 + 0.9 * fmax(0, sin(phase));
            CGFloat alpha = 0.4 + 0.6 * fmax(0, sin(phase));
            CGFloat x = startX + i * dotSpacing;

            [[NSColor colorWithWhite:0 alpha:alpha] setFill];
            NSBezierPath *dot = [NSBezierPath bezierPathWithOvalInRect:
                NSMakeRect(x - radius, centerY - radius, radius * 2, radius * 2)];
            [dot fill];
        }
    }];
    self.statusItem.button.image = icon;
}

/// Error: X mark
- (void)applyErrorIcon {
    NSImage *icon = [self templateImageWithDrawing:^(NSSize size) {
        CGFloat centerX = size.width / 2.0;
        CGFloat centerY = size.height / 2.0;
        CGFloat arm = 3.0;
        [self strokeMarkFrameInSize:size];

        NSBezierPath *path = [NSBezierPath bezierPath];
        path.lineWidth = 2.0;
        path.lineCapStyle = NSLineCapStyleRound;

        [path moveToPoint:NSMakePoint(centerX - arm, centerY - arm)];
        [path lineToPoint:NSMakePoint(centerX + arm, centerY + arm)];
        [path moveToPoint:NSMakePoint(centerX + arm, centerY - arm)];
        [path lineToPoint:NSMakePoint(centerX - arm, centerY + arm)];

        [[NSColor blackColor] setStroke];
        [path stroke];
    }];
    self.statusItem.button.image = icon;
}

/// Pasting: checkmark
- (void)applyPasteIcon {
    NSImage *icon = [self templateImageWithDrawing:^(NSSize size) {
        CGFloat centerX = size.width / 2.0;
        CGFloat centerY = size.height / 2.0;

        [self strokeMarkFrameInSize:size];
        NSBezierPath *path = [NSBezierPath bezierPath];
        path.lineWidth = 1.8;
        path.lineCapStyle = NSLineCapStyleRound;
        path.lineJoinStyle = NSLineJoinStyleRound;

        // Checkmark
        [path moveToPoint:NSMakePoint(centerX - 3.2, centerY)];
        [path lineToPoint:NSMakePoint(centerX - 0.8, centerY - 2.8)];
        [path lineToPoint:NSMakePoint(centerX + 3.6, centerY + 3)];

        [[NSColor blackColor] setStroke];
        [path stroke];
    }];
    self.statusItem.button.image = icon;
}

#pragma mark - State Updates

- (void)updateState:(NSString *)state {
    self.currentState = state;
    [self stopAnimation];
    [self refreshVoiceInputItem];

    if ([state isEqualToString:@"idle"] || [state isEqualToString:@"completed"]) {
        [self applyIdleIcon];

    } else if ([state hasPrefix:@"recording"]) {
        [self startRecordingAnimation];

    } else if ([state isEqualToString:@"connecting_asr"] ||
               [state isEqualToString:@"finalizing_asr"] ||
               [state isEqualToString:@"correcting"]) {
        [self startProcessingAnimation];

    } else if ([state hasPrefix:@"preparing_paste"] || [state isEqualToString:@"pasting"]) {
        [self applyPasteIcon];

    } else if ([state isEqualToString:@"error"] || [state isEqualToString:@"failed"]) {
        [self applyErrorIcon];

    } else {
        [self startProcessingAnimation];
    }
}

/// The manual voice-input item mirrors `currentState`: idle/completed can start
/// a session, any `recording*` state can stop it, and every intermediate state
/// (connecting, finalizing, correcting, pasting, error) offers neither.
- (void)refreshVoiceInputItem {
    BOOL recording = [self.currentState hasPrefix:@"recording"];
    BOOL idle = [self.currentState isEqualToString:@"idle"] ||
                [self.currentState isEqualToString:@"completed"];
    self.voiceInputItem.title = recording ? @"Остановить диктовку" : @"Начать диктовку";
    self.voiceInputItem.enabled = recording || idle;
}

#pragma mark - Animations

- (void)startRecordingAnimation {
    self.animationFrame = 0;
    [self applyRecordingIconWithFrame:0];
    self.animationTimer = [NSTimer scheduledTimerWithTimeInterval:0.15
                                                         repeats:YES
                                                           block:^(NSTimer *timer) {
        self.animationFrame++;
        [self applyRecordingIconWithFrame:self.animationFrame];
    }];
}

- (void)startProcessingAnimation {
    self.animationFrame = 0;
    [self applyProcessingIconWithFrame:0];
    self.animationTimer = [NSTimer scheduledTimerWithTimeInterval:0.2
                                                         repeats:YES
                                                           block:^(NSTimer *timer) {
        self.animationFrame++;
        [self applyProcessingIconWithFrame:self.animationFrame];
    }];
}

- (void)stopAnimation {
    [self.animationTimer invalidate];
    self.animationTimer = nil;
    self.animationFrame = 0;
}

#pragma mark - Actions

- (void)openRecentDictations:(id)sender {
    if ([self.delegate respondsToSelector:@selector(statusBarDidSelectRecentDictations)]) {
        [self.delegate statusBarDidSelectRecentDictations];
    }
}

- (void)openOnboarding:(id)sender {
    if ([self.delegate respondsToSelector:@selector(statusBarDidSelectOnboarding)]) {
        [self.delegate statusBarDidSelectOnboarding];
    }
}

- (void)openSetupWizard:(id)sender {
    if ([self.delegate respondsToSelector:@selector(statusBarDidSelectSetupWizard)]) {
        [self.delegate statusBarDidSelectSetupWizard];
    }
}

- (void)reportProblem:(id)sender {
    if ([self.delegate respondsToSelector:@selector(statusBarDidSelectReportProblem)]) {
        [self.delegate statusBarDidSelectReportProblem];
    }
}

- (void)openAppUpdate:(id)sender {
    if ([self.delegate respondsToSelector:@selector(statusBarDidSelectAppUpdate)]) {
        [self.delegate statusBarDidSelectAppUpdate];
    }
}

- (void)updateLipsModel:(id)sender {
    if ([self.delegate respondsToSelector:@selector(statusBarDidSelectLipsModelUpdate)]) {
        [self.delegate statusBarDidSelectLipsModelUpdate];
    }
}

- (void)showAppUpdateVersion:(NSString *)version {
    self.appUpdateItem.title = version.length > 0 ? [NSString stringWithFormat:@"Доступна новая версия %@…", version] : @"";
    self.appUpdateItem.hidden = version.length == 0;
}

- (void)showLipsModelUpdate:(NSString *)tag {
    self.lipsModelUpdateItem.title = tag.length > 0 ? [NSString stringWithFormat:@"Обновить модель губ до %@…", tag] : @"";
    self.lipsModelUpdateItem.hidden = tag.length == 0;
}

- (void)toggleVoiceInput:(id)sender {
    if ([self.delegate respondsToSelector:@selector(statusBarDidSelectToggleVoiceInput)]) {
        [self.delegate statusBarDidSelectToggleVoiceInput];
    }
}

- (void)openConfigFolder:(id)sender {
    NSString *path = SPAppDataDirectory();
    [[NSFileManager defaultManager] createDirectoryAtPath:path
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:path]];
}

- (void)reloadConfig:(id)sender {
    if ([self.delegate respondsToSelector:@selector(statusBarDidSelectReloadConfig)]) {
        [self.delegate statusBarDidSelectReloadConfig];
    }
}

- (void)toggleLaunchAtLogin:(NSMenuItem *)sender {
    if (@available(macOS 13.0, *)) {
        SMAppService *service = SMAppService.mainAppService;
        NSError *error = nil;
        if (service.status == SMAppServiceStatusEnabled) {
            [service unregisterAndReturnError:&error];
            sender.state = NSControlStateValueOff;
        } else {
            [service registerAndReturnError:&error];
            sender.state = NSControlStateValueOn;
        }
        if (error) {
            NSLog(@"[VelikiyMoguchiy] Launch at login toggle failed: %@", error.localizedDescription);
        }
    }
}

- (void)quitApp:(id)sender {
    if ([self.delegate respondsToSelector:@selector(statusBarDidSelectQuit)]) {
        [self.delegate statusBarDidSelectQuit];
    } else {
        [NSApp terminate:nil];
    }
}

- (void)dealloc {
    [self stopAnimation];
}

@end
