#import "SPProblemReportWindowController.h"
#import <OSLog/OSLog.h>
#import <sys/sysctl.h>
#import "SPProblemReport.h"
#import "velikiy_moguchiy_core.h"

static const NSUInteger kLogLines = 150;

@interface SPProblemReportWindowController ()
@property (nonatomic, strong) NSTextField *summaryLabel;
@property (nonatomic, strong) NSTextView *logView;
@property (nonatomic, copy) NSString *appVersion;
@property (nonatomic, copy) NSString *system;
@property (nonatomic, copy) NSString *provider;
@end

@implementation SPProblemReportWindowController

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 520)
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                             NSWindowStyleMaskResizable
                                                     backing:NSBackingStoreBuffered
                                                       defer:YES];
    window.title = @"Сообщить о проблеме";
    window.releasedWhenClosed = NO;
    window.minSize = NSMakeSize(480, 360);
    self = [super initWithWindow:window];
    if (self) [self buildContent];
    return self;
}

- (void)buildContent {
    NSView *content = self.window.contentView;
    NSTextField *intro = [NSTextField wrappingLabelWithString:
        @"Ниже — всё, что попадёт в сообщение. Ничего не отправляется само: «Открыть на GitHub» откроет в браузере "
        @"заполненную форму, и вы отправите её сами. Ключи, почта, тексты диктовок и ваше имя в путях уже скрыты; "
        @"проверьте и сотрите лишнее."];
    intro.font = [NSFont systemFontOfSize:12];
    self.summaryLabel = [NSTextField wrappingLabelWithString:@""];
    self.summaryLabel.font = [NSFont monospacedSystemFontOfSize:11.5 weight:NSFontWeightRegular];
    self.summaryLabel.selectable = YES;

    NSScrollView *scroll = [[NSScrollView alloc] init];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    self.logView = [[NSTextView alloc] init];
    self.logView.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.logView.richText = NO;
    self.logView.automaticQuoteSubstitutionEnabled = NO;
    self.logView.automaticDashSubstitutionEnabled = NO;
    self.logView.automaticTextReplacementEnabled = NO;
    self.logView.verticallyResizable = YES;
    self.logView.autoresizingMask = NSViewWidthSizable;
    self.logView.textContainer.widthTracksTextView = YES;
    self.logView.string = @"Собираю лог…";
    scroll.documentView = self.logView;

    NSButton *open = [NSButton buttonWithTitle:@"Открыть на GitHub" target:self action:@selector(openIssue:)];
    open.keyEquivalent = @"\r";
    NSButton *copy = [NSButton buttonWithTitle:@"Скопировать" target:self action:@selector(copyReport:)];
    NSButton *cancel = [NSButton buttonWithTitle:@"Отмена" target:self action:@selector(cancel:)];
    cancel.keyEquivalent = @"\e";

    for (NSView *view in @[ intro, self.summaryLabel, scroll, open, copy, cancel ]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [intro.topAnchor constraintEqualToAnchor:content.topAnchor constant:16],
        [intro.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20],
        [intro.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],
        [self.summaryLabel.topAnchor constraintEqualToAnchor:intro.bottomAnchor constant:12],
        [self.summaryLabel.leadingAnchor constraintEqualToAnchor:intro.leadingAnchor],
        [self.summaryLabel.trailingAnchor constraintEqualToAnchor:intro.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:self.summaryLabel.bottomAnchor constant:10],
        [scroll.leadingAnchor constraintEqualToAnchor:intro.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:intro.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:open.topAnchor constant:-14],
        [open.trailingAnchor constraintEqualToAnchor:intro.trailingAnchor],
        [open.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-16],
        [copy.trailingAnchor constraintEqualToAnchor:open.leadingAnchor constant:-8],
        [copy.centerYAnchor constraintEqualToAnchor:open.centerYAnchor],
        [cancel.leadingAnchor constraintEqualToAnchor:intro.leadingAnchor],
        [cancel.centerYAnchor constraintEqualToAnchor:open.centerYAnchor],
    ]];
}

- (void)present {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    self.appVersion = [NSString stringWithFormat:@"%@ (%@)", info[@"CFBundleShortVersionString"] ?: @"?",
                                                 info[@"CFBundleVersion"] ?: @"?"];
    NSOperatingSystemVersion os = NSProcessInfo.processInfo.operatingSystemVersion;
    self.system = [NSString stringWithFormat:@"macOS %ld.%ld.%ld, %@", (long)os.majorVersion, (long)os.minorVersion,
                                             (long)os.patchVersion, [self machineModel]];
    char *raw = sp_config_get("asr.provider");
    self.provider = raw ? ([NSString stringWithUTF8String:raw] ?: @"") : @"";
    if (raw) sp_core_free_string(raw);
    self.summaryLabel.stringValue = [NSString stringWithFormat:@"Версия: %@\nСистема: %@\nРаспознавание: %@",
                                                               self.appVersion, self.system, self.provider];
    [self.window center];
    [NSApp activateIgnoringOtherApps:YES];
    [self showWindow:nil];
    [self.window makeKeyAndOrderFront:nil];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *log = [SPProblemReport redactedLog:[self recentLog] homeDirectory:NSHomeDirectory()];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.logView.string = log.length > 0 ? log : @"(в логе этого запуска пока пусто)";
        });
    });
}

- (NSString *)machineModel {
    char model[256] = {0};
    size_t size = sizeof(model);
    if (sysctlbyname("hw.model", model, &size, NULL, 0) != 0) return @"Mac";
    return [NSString stringWithUTF8String:model] ?: @"Mac";
}

/// The last messages this process logged since launch (NSLog and the core).
- (NSString *)recentLog {
    NSError *error = nil;
    OSLogStore *store = [OSLogStore storeWithScope:OSLogStoreCurrentProcessIdentifier error:&error];
    if (!store) {
        NSLog(@"[VelikiyMoguchiy] problem report: no log store: %@", error);
        return @"";
    }
    OSLogEnumerator *entries = [store entriesEnumeratorWithOptions:OSLogEnumeratorReverse
                                                          position:[store positionWithDate:[NSDate date]]
                                                         predicate:nil
                                                             error:&error];
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"HH:mm:ss";
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (OSLogEntry *entry in entries) {
        if (![entry isKindOfClass:[OSLogEntryLog class]]) continue;
        NSString *message = [entry.composedMessage stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
        if (message.length == 0) continue;
        [lines insertObject:[NSString stringWithFormat:@"%@ %@", [formatter stringFromDate:entry.date], message] atIndex:0];
        if (lines.count >= kLogLines) break;
    }
    return [lines componentsJoinedByString:@"\n"];
}

- (NSString *)reportText {
    return [NSString stringWithFormat:@"%@\n\n%@", self.summaryLabel.stringValue, self.logView.string];
}

- (void)openIssue:(id)sender {
    NSURL *url = [SPProblemReport issueURLWithAppVersion:self.appVersion
                                                  system:self.system
                                                provider:self.provider
                                                     log:self.logView.string];
    [[NSWorkspace sharedWorkspace] openURL:url];
    [self.window orderOut:nil];
}

- (void)copyReport:(id)sender {
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:[self reportText] forType:NSPasteboardTypeString];
}

- (void)cancel:(id)sender {
    [self.window orderOut:nil];
}

@end
