#import "SPLipsRuntime.h"
#import <Cocoa/Cocoa.h>
#import <CommonCrypto/CommonDigest.h>
#import "SPAppPaths.h"
#import "SPLipsRuntimePolicy.h"
#import "SPLipsService.h"
#import "SPProgressPanel.h"
#import "SPRustBridge.h"
#import "SPUpdatePolicy.h"
#import "velikiy_moguchiy_core.h"

static NSString *const kBaseModelPath = @"lips/multivsr";
static NSString *const kToolsModelPath = @"lips/tools";
static NSString *const kReleasesModelPath = @"lips/releases";
static NSString *const kFfmpegPackage = @"imageio-ffmpeg==0.6.0";
static NSString *const kLastModelCheckKey = @"SPLipsModelLastCheck";
static const NSTimeInterval kNetworkTimeout = 30.0;

static NSString *configString(const char *keyPath) {
    char *raw = sp_config_get(keyPath);
    if (!raw) return @"";
    NSString *value = [[NSString stringWithUTF8String:raw] ?: @""
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    sp_core_free_string(raw);
    return value;
}

static NSString *formatBytes(unsigned long long bytes) {
    return [NSByteCountFormatter stringFromByteCount:(long long)bytes countStyle:NSByteCountFormatterCountStyleFile];
}

@interface SPLipsRuntime ()
@property (nonatomic, readwrite) BOOL isInstalling;
@property (atomic) BOOL cancelled;
@property (atomic, strong, nullable) NSTask *currentTask;
@property (atomic, copy, nullable) NSString *currentDownload;
@property (nonatomic, strong, nullable) SPProgressPanel *panel;
@property (nonatomic, strong) dispatch_queue_t workQueue;
@end

@implementation SPLipsRuntime

+ (instancetype)sharedRuntime {
    static SPLipsRuntime *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SPLipsRuntime alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _workQueue = dispatch_queue_create("velikiy-moguchiy.lips.runtime", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

#pragma mark - Paths

- (NSString *)lipsRoot {
    return SPAppDataPath(@"lips");
}

- (NSString *)managedServiceDirectory {
    return [[self lipsRoot] stringByAppendingPathComponent:@"service"];
}

- (NSString *)modelsDirectory {
    return SPAppDataPath(@"models");
}

- (NSString *)modelDirectory:(NSString *)relativePath {
    return [[self modelsDirectory] stringByAppendingPathComponent:relativePath];
}

- (NSString *)releaseModelPathForTag:(NSString *)tag {
    return [kReleasesModelPath stringByAppendingPathComponent:tag];
}

- (NSString *)statePath {
    return [[self lipsRoot] stringByAppendingPathComponent:@"state.json"];
}

- (NSString *)bundledCodeDirectory {
    return [[NSBundle mainBundle] pathForResource:@"lipread" ofType:nil];
}

/// tools/mem_guard.py, which «Обучить на мне» expects next to the lipread folder.
- (NSString *)bundledToolsDirectory {
    return [[NSBundle mainBundle] pathForResource:@"lipread-tools" ofType:nil];
}

- (NSString *)serviceDirectory {
    return [SPLipsRuntimePolicy serviceDirectoryForOverride:configString("lips.service_dir")
                                           managedDirectory:[self managedServiceDirectory]];
}

- (BOOL)usesDeveloperCheckout {
    return configString("lips.service_dir").length > 0;
}

- (NSString *)binDirectory {
    if ([self usesDeveloperCheckout]) return nil;
    return [[self managedServiceDirectory] stringByAppendingPathComponent:@"bin"];
}

#pragma mark - State

- (NSDictionary *)state {
    NSData *data = [NSData dataWithContentsOfFile:[self statePath]];
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [json isKindOfClass:[NSDictionary class]] ? json : @{};
}

- (void)updateState:(NSDictionary *)changes {
    NSMutableDictionary *state = [[self state] mutableCopy];
    [state addEntriesFromDictionary:changes];
    NSData *data = [NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingPrettyPrinted error:nil];
    [[NSFileManager defaultManager] createDirectoryAtPath:[self lipsRoot]
                              withIntermediateDirectories:YES attributes:nil error:nil];
    [data writeToFile:[self statePath] atomically:YES];
}

- (NSString *)installedReleaseTag {
    NSString *tag = [self state][@"release"];
    return [SPLipsRuntimePolicy directoryNameForTag:tag];
}

/// Changes when the app ships different lipread code, so the environment is
/// rebuilt for it (new dependencies in uv.lock included).
- (NSString *)bundledCodeFingerprint {
    NSString *code = [self bundledCodeDirectory];
    if (!code) return @"";
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    for (NSString *dir in @[ code, [self bundledToolsDirectory] ?: @"" ]) {
        NSArray<NSString *> *names = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil]
            sortedArrayUsingSelector:@selector(compare:)];
        for (NSString *name in names) {
            NSData *nameData = [name dataUsingEncoding:NSUTF8StringEncoding];
            NSData *content = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:name]] ?: [NSData data];
            CC_SHA256_Update(&ctx, nameData.bytes, (CC_LONG)nameData.length);
            CC_SHA256_Update(&ctx, content.bytes, (CC_LONG)content.length);
        }
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    NSMutableString *hex = [NSMutableString string];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

- (BOOL)modelInstalled:(NSString *)relativePath {
    return sp_model_status(relativePath.UTF8String, 1) == 2;
}

- (BOOL)modelsInstalled {
    NSString *tag = [self installedReleaseTag];
    return tag && [self modelInstalled:kBaseModelPath] && [self modelInstalled:[self releaseModelPathForTag:tag]];
}

- (BOOL)environmentCurrent {
    NSString *dir = [self managedServiceDirectory];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *fingerprint = [self bundledCodeFingerprint];
    return fingerprint.length > 0 && [[self state][@"environment"] isEqualToString:fingerprint] &&
           [fm isExecutableFileAtPath:[dir stringByAppendingPathComponent:@".venv/bin/python"]] &&
           [fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"lips_service.py"]] &&
           [fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"weights/model.pth"]] &&
           [fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"results/pod_runs/t1/checkpoints/me1/best.pt"]];
}

- (BOOL)isReady {
    if ([self usesDeveloperCheckout]) return YES;
    return [self modelsInstalled] && [self environmentCurrent];
}

#pragma mark - Setup

- (void)offerSetupWithCompletion:(void (^)(BOOL))completion {
    if (self.isInstalling) {
        [self.panel present];
        if (completion) completion(NO);
        return;
    }
    if ([self isReady]) {
        if (completion) completion(YES);
        return;
    }
    if ([self modelsInstalled]) {
        [self runSetupWithTitle:@"Обновление режима губ" completion:completion];
        return;
    }
    if (![self bundledCodeDirectory]) {
        [self showAlert:@"В этой сборке нет кода сервиса губ"
                   info:@"Соберите приложение заново или укажите папку lipread в lips.service_dir."];
        if (completion) completion(NO);
        return;
    }
    unsigned long long needed = [SPLipsRuntimePolicy requiredFreeBytes];
    unsigned long long available = [self availableBytes];
    if (available > 0 && available < needed) {
        [self showAlert:@"Недостаточно места на диске"
                   info:[NSString stringWithFormat:@"Для режима губ нужно около %@ свободного места, сейчас доступно %@.",
                                                   formatBytes(needed), formatBytes(available)]];
        if (completion) completion(NO);
        return;
    }
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Установить режим чтения по губам?";
    alert.informativeText = [NSString stringWithFormat:
        @"Приложение скачает:\n"
        @"• базовую модель MultiVSR у её авторов (Оксфорд, около 4,5 ГБ);\n"
        @"• дообученную модель губ с Hugging Face (если он недоступен — из релиза на GitHub);\n"
        @"• uv, Python и библиотеки для сервиса губ.\n\n"
        @"Понадобится около %@ на диске. Каждый файл проверяется по SHA-256. Всё ляжет в папку %@, "
        @"видео с камеры никуда не отправляется. Загрузку можно отменить и продолжить позже.",
        formatBytes(needed), [SPAppDataDirectory() stringByAbbreviatingWithTildeInPath]];
    [alert addButtonWithTitle:@"Скачать"];
    [alert addButtonWithTitle:@"Не сейчас"];
    [NSApp activateIgnoringOtherApps:YES];
    if ([alert runModal] != NSAlertFirstButtonReturn) {
        if (completion) completion(NO);
        return;
    }
    [self runSetupWithTitle:@"Установка режима губ" completion:completion];
}

- (unsigned long long)availableBytes {
    NSURL *url = [NSURL fileURLWithPath:NSHomeDirectory()];
    NSNumber *capacity = nil;
    [url getResourceValue:&capacity forKey:NSURLVolumeAvailableCapacityForImportantUsageKey error:nil];
    return capacity.unsignedLongLongValue;
}

- (void)runSetupWithTitle:(NSString *)title completion:(void (^)(BOOL))completion {
    self.isInstalling = YES;
    self.cancelled = NO;
    SPProgressPanel *panel = [[SPProgressPanel alloc] initWithTitle:title];
    __weak typeof(self) weakSelf = self;
    panel.cancelHandler = ^{
        [weakSelf cancelWork];
    };
    self.panel = panel;
    [panel setStep:@"Подготовка…" detail:nil];
    [panel present];
    dispatch_async(self.workQueue, ^{
        NSString *failure = [self performSetup];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.isInstalling = NO;
            BOOL ok = failure == nil;
            if (self.cancelled) {
                [panel finishWithMessage:@"Остановлено. Скачанное сохранится, продолжим с того же места." success:NO];
            } else if (ok) {
                [[SPLipsService sharedService] shutdown];
                [panel finishWithMessage:@"Режим губ готов. Держите клавишу губ и говорите беззвучно." success:YES];
            } else {
                [panel finishWithMessage:[@"Не получилось: " stringByAppendingString:failure] success:NO];
            }
            NSLog(@"[VelikiyMoguchiy] lips setup: %@", ok ? @"done" : (self.cancelled ? @"cancelled" : failure));
            if (completion) completion(ok);
        });
    });
}

- (void)cancelWork {
    self.cancelled = YES;
    NSString *download = self.currentDownload;
    if (download) sp_core_cancel_download(download.UTF8String);
    NSTask *task = self.currentTask;
    if (task.isRunning) [task terminate];
}

/// On workQueue. Nil on success, else a short reason for the user.
- (NSString *)performSetup {
    NSString *tag = [self installedReleaseTag];
    if (!tag || ![self modelInstalled:[self releaseModelPathForTag:tag]]) {
        [self reportStep:@"Поиск модели губ…" detail:@"Hugging Face и GitHub" progress:-1];
        NSString *error = nil;
        NSDictionary *manifest = nil, *fallback = nil;
        tag = [self fetchNewestModel:&manifest fallback:&fallback error:&error];
        if (!tag) return error;
        NSString *failure = [self installModelManifest:manifest fallback:fallback tag:tag step:@"Шаг 2 из 5. Загрузка модели губ"];
        if (failure) return failure;
    }
    NSArray *downloads = @[
        @[ kToolsModelPath, [SPLipsRuntimePolicy toolsManifest], @"Загрузка uv и кода MultiVSR" ],
        @[ [self releaseModelPathForTag:tag], [NSNull null], [NSString stringWithFormat:@"Загрузка модели губ %@", tag] ],
        @[ kBaseModelPath, [SPLipsRuntimePolicy baseModelManifest], @"Загрузка базовой модели MultiVSR" ],
    ];
    NSUInteger index = 0;
    for (NSArray *item in downloads) {
        index++;
        if (self.cancelled) return @"отменено";
        if ([item[1] isKindOfClass:[NSDictionary class]]) {
            NSString *failure = [self writeManifest:item[1] toModelPath:item[0]];
            if (failure) return failure;
        }
        NSString *step = [NSString stringWithFormat:@"Шаг %lu из 5. %@", (unsigned long)index, item[2]];
        NSString *failure = [self downloadModelPath:item[0] step:step];
        if (failure) return failure;
    }
    if (self.cancelled) return @"отменено";
    [self reportStep:@"Шаг 4 из 5. Python и библиотеки" detail:@"Первый раз это займёт несколько минут" progress:-1];
    NSString *failure = [self buildEnvironmentForRelease:tag];
    if (failure) return failure;
    if (self.cancelled) return @"отменено";
    [self reportStep:@"Шаг 5 из 5. Проверка файлов по SHA-256" detail:nil progress:-1];
    for (NSString *path in @[ kBaseModelPath, [self releaseModelPathForTag:tag], kToolsModelPath ]) {
        if (sp_model_status(path.UTF8String, 0) != 2) return @"файлы модели не прошли проверку, запустите ещё раз";
    }
    [self updateState:@{@"release" : tag, @"environment" : [self bundledCodeFingerprint]}];
    return nil;
}

- (void)reportStep:(NSString *)step detail:(NSString *)detail progress:(double)progress {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.panel setStep:step detail:detail];
        [self.panel setProgress:progress];
    });
}

- (NSString *)writeManifest:(NSDictionary *)manifest toModelPath:(NSString *)relativePath {
    NSString *dir = [self modelDirectory:relativePath];
    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&error]) {
        NSLog(@"[VelikiyMoguchiy] lips setup: cannot create %@: %@", relativePath, error);
        return @"не удалось создать папку для модели";
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingPrettyPrinted error:nil];
    NSString *path = [dir stringByAppendingPathComponent:@".koe-manifest.json"];
    NSData *existing = [NSData dataWithContentsOfFile:path];
    if ([existing isEqualToData:data]) return nil;
    return [data writeToFile:path atomically:YES] ? nil : @"не удалось записать описание модели";
}

/// On workQueue: blocks until the core's downloader finishes.
- (NSString *)downloadModelPath:(NSString *)relativePath step:(NSString *)step {
    if ([self modelInstalled:relativePath]) return nil;
    SPRustBridge *bridge = self.rustBridge;
    if (!bridge) return @"ядро приложения не запущено";
    NSData *data = [NSData dataWithContentsOfFile:[[self modelDirectory:relativePath]
                                                      stringByAppendingPathComponent:@".koe-manifest.json"]];
    NSDictionary *manifest = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    unsigned long long total = 0;
    for (NSDictionary *file in manifest[@"files"]) total += [file[@"size"] unsignedLongLongValue];
    NSMutableDictionary<NSString *, NSNumber *> *perFile = [NSMutableDictionary dictionary];

    [self reportStep:step detail:formatBytes(total) progress:0];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block BOOL success = NO;
    __block NSString *message = nil;
    self.currentDownload = relativePath;
    dispatch_async(dispatch_get_main_queue(), ^{
        [bridge downloadModel:relativePath
            progress:^(NSUInteger fileIndex, NSUInteger fileCount, uint64_t downloaded, uint64_t fileTotal, NSString *filename) {
                perFile[filename] = @(downloaded);
                unsigned long long sum = 0;
                for (NSNumber *bytes in perFile.allValues) sum += bytes.unsignedLongLongValue;
                [self.panel setStep:step detail:[NSString stringWithFormat:@"%@ из %@", formatBytes(sum), formatBytes(total)]];
                [self.panel setProgress:total > 0 ? (double)sum / (double)total : -1];
            }
            completion:^(BOOL ok, NSString *msg) {
                success = ok;
                message = msg;
                dispatch_semaphore_signal(done);
            }];
    });
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    self.currentDownload = nil;
    if (success) return nil;
    NSLog(@"[VelikiyMoguchiy] lips setup: download of %@ failed: %@", relativePath, message);
    if (self.cancelled) return @"отменено";
    return [message containsString:@"sha256"] ? @"файл повреждён при загрузке, запустите ещё раз"
                                              : @"загрузка прервалась, проверьте интернет и запустите ещё раз";
}

#pragma mark - GitHub

- (NSData *)fetchURL:(NSURL *)url error:(NSString **)error {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = kNetworkTimeout;
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"velikiy-moguchiy" forHTTPHeaderField:@"User-Agent"];
    __block NSData *body = nil;
    __block NSInteger status = 0;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *e) {
        body = data;
        if ([response isKindOfClass:[NSHTTPURLResponse class]]) status = ((NSHTTPURLResponse *)response).statusCode;
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    if (status != 200 || !body) {
        NSLog(@"[VelikiyMoguchiy] lips: GET %@ -> HTTP %ld", url, (long)status);
        if (error) *error = @"GitHub недоступен, проверьте интернет";
        return nil;
    }
    return body;
}

/// Blocking. The newest lips-* release on GitHub and its manifest, or nil with a reason.
- (NSString *)fetchGitHubManifest:(NSDictionary **)manifest error:(NSString **)error {
    NSString *api = [NSString stringWithFormat:@"https://api.github.com/repos/%@/releases?per_page=30",
                                               SPLipsRuntimePolicy.modelsRepository];
    NSData *data = [self fetchURL:[NSURL URLWithString:api] error:error];
    if (!data) return nil;
    id releases = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSDictionary *release = [SPUpdatePolicy newestReleaseIn:releases tagPrefix:SPLipsRuntimePolicy.releaseTagPrefix];
    NSString *tag = [SPLipsRuntimePolicy directoryNameForTag:release[@"tag_name"]];
    if (!release || !tag) {
        if (error) *error = @"на GitHub нет опубликованной модели губ";
        return nil;
    }
    NSString *sumsURL = nil;
    for (NSDictionary *asset in release[@"assets"]) {
        if ([asset isKindOfClass:[NSDictionary class]] && [asset[@"name"] isEqual:@"SHA256SUMS.txt"]) {
            sumsURL = asset[@"browser_download_url"];
        }
    }
    NSString *expectedPrefix = [NSString stringWithFormat:@"https://github.com/%@/releases/download/",
                                                          SPLipsRuntimePolicy.modelsRepository];
    if (![sumsURL isKindOfClass:[NSString class]] || ![sumsURL hasPrefix:expectedPrefix]) {
        if (error) *error = @"в релизе модели нет SHA256SUMS.txt";
        return nil;
    }
    NSDictionary *sums = [self fetchSha256Sums:[NSURL URLWithString:sumsURL] error:error];
    if (!sums) return nil;
    NSString *reason = nil;
    NSDictionary *result = [SPLipsRuntimePolicy modelManifestForRelease:release sha256Sums:sums error:&reason];
    if (!result) {
        NSLog(@"[VelikiyMoguchiy] lips: release %@ rejected: %@", tag, reason);
        if (error) *error = [@"релиз модели не подходит: " stringByAppendingString:reason ?: @"?"];
        return nil;
    }
    if (manifest) *manifest = result;
    return tag;
}

/// Blocking. The newest lips model in the Hugging Face mirror and its manifest, or nil with a reason.
- (NSString *)fetchHuggingFaceManifest:(NSDictionary **)manifest error:(NSString **)error {
    NSString *repo = SPLipsRuntimePolicy.huggingFaceRepository;
    NSString *api = [NSString stringWithFormat:@"https://huggingface.co/api/models/%@?blobs=true", repo];
    NSData *data = [self fetchURL:[NSURL URLWithString:api] error:error];
    id info = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSString *revision = [info isKindOfClass:[NSDictionary class]] ? info[@"sha"] : nil;
    if (![revision isKindOfClass:[NSString class]]) {
        if (error) *error = @"Hugging Face недоступен";
        return nil;
    }
    NSURL *sumsURL = [NSURL URLWithString:[NSString stringWithFormat:@"https://huggingface.co/%@/resolve/%@/SHA256SUMS.txt",
                                                                     repo, revision]];
    NSDictionary *sums = [self fetchSha256Sums:sumsURL error:error];
    if (!sums) return nil;
    NSString *tag = nil, *reason = nil;
    NSDictionary *result = [SPLipsRuntimePolicy huggingFaceManifestFromModelInfo:info sha256Sums:sums tag:&tag error:&reason];
    if (!result || ![SPLipsRuntimePolicy directoryNameForTag:tag]) {
        NSLog(@"[VelikiyMoguchiy] lips: Hugging Face model rejected: %@", reason);
        if (error) *error = [@"модель на Hugging Face не подходит: " stringByAppendingString:reason ?: @"?"];
        return nil;
    }
    if (manifest) *manifest = result;
    return tag;
}

- (NSDictionary *)fetchSha256Sums:(NSURL *)url error:(NSString **)error {
    NSData *data = [self fetchURL:url error:error];
    if (!data) return nil;
    NSDictionary *sums = [SPLipsRuntimePolicy sha256SumsFromText:[[NSString alloc] initWithData:data
                                                                                         encoding:NSUTF8StringEncoding]];
    if (!sums && error) *error = @"SHA256SUMS.txt модели повреждён";
    return sums;
}

/// Blocking. The newest lips model across both sources. Hugging Face comes
/// first and the GitHub release is the fallback when both carry the same
/// files; a version only one source has is taken from that source alone.
- (NSString *)fetchNewestModel:(NSDictionary **)primary fallback:(NSDictionary **)fallback error:(NSString **)error {
    NSDictionary *hf = nil, *gh = nil;
    NSString *hfError = nil, *ghError = nil;
    NSString *hfTag = [self fetchHuggingFaceManifest:&hf error:&hfError];
    NSString *ghTag = [self fetchGitHubManifest:&gh error:&ghError];
    if (!hfTag && !ghTag) {
        if (error) *error = ghError ?: hfError ?: @"модель губ не найдена";
        return nil;
    }
    NSString *prefix = SPLipsRuntimePolicy.releaseTagPrefix;
    NSComparisonResult order = (hfTag && ghTag)
        ? [SPUpdatePolicy compareVersion:[SPUpdatePolicy versionFromTag:hfTag prefix:prefix] ?: @"0"
                               toVersion:[SPUpdatePolicy versionFromTag:ghTag prefix:prefix] ?: @"0"]
        : (hfTag ? NSOrderedDescending : NSOrderedAscending);
    if (order == NSOrderedSame && ![SPLipsRuntimePolicy manifest:hf hasSameFilesAs:gh]) {
        NSLog(@"[VelikiyMoguchiy] lips: %@ differs between Hugging Face and GitHub; using the GitHub release", ghTag);
        order = NSOrderedAscending;
    }
    if (primary) *primary = order == NSOrderedAscending ? gh : hf;
    if (fallback) *fallback = order == NSOrderedSame ? gh : nil;
    return order == NSOrderedAscending ? ghTag : hfTag;
}

/// On workQueue: writes the manifest of `tag` and downloads it, from the
/// fallback source when the first one fails.
- (NSString *)installModelManifest:(NSDictionary *)manifest
                          fallback:(NSDictionary *)fallback
                               tag:(NSString *)tag
                              step:(NSString *)step {
    NSString *path = [self releaseModelPathForTag:tag];
    NSString *failure = [self writeManifest:manifest toModelPath:path] ?: [self downloadModelPath:path step:step];
    if (failure && fallback && !self.cancelled) {
        NSLog(@"[VelikiyMoguchiy] lips: %@ from %@ failed (%@), trying %@", tag, manifest[@"repo"], failure, fallback[@"repo"]);
        failure = [self writeManifest:fallback toModelPath:path] ?: [self downloadModelPath:path step:step];
    }
    return failure;
}

#pragma mark - Environment

/// On workQueue: runs a tool, its output going to lips/setup.log. Nil on success.
- (NSString *)run:(NSString *)executable
        arguments:(NSArray<NSString *> *)arguments
      environment:(NSDictionary<NSString *, NSString *> *)environment
           output:(NSString *_Nullable *_Nullable)output {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:executable];
    task.arguments = arguments;
    task.currentDirectoryURL = [NSURL fileURLWithPath:[self managedServiceDirectory]];
    task.environment = environment;
    NSPipe *stdoutPipe = [NSPipe pipe];
    task.standardOutput = stdoutPipe;
    NSString *logPath = [[self lipsRoot] stringByAppendingPathComponent:@"setup.log"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:logPath]) {
        [[NSFileManager defaultManager] createFileAtPath:logPath contents:nil attributes:@{NSFilePosixPermissions : @(0600)}];
    }
    NSFileHandle *log = [NSFileHandle fileHandleForWritingAtPath:logPath];
    [log seekToEndOfFile];
    [log writeData:[[NSString stringWithFormat:@"$ %@ %@\n", executable.lastPathComponent,
                                               [arguments componentsJoinedByString:@" "]]
                       dataUsingEncoding:NSUTF8StringEncoding]];
    task.standardError = log ?: [NSFileHandle fileHandleWithNullDevice];
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        NSLog(@"[VelikiyMoguchiy] lips setup: cannot run %@: %@", executable.lastPathComponent, error);
        return @"не удалось запустить установку окружения";
    }
    self.currentTask = task;
    NSData *outData = [stdoutPipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    self.currentTask = nil;
    [log closeFile];
    if (output) *output = [[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding];
    if (self.cancelled) return @"отменено";
    if (task.terminationStatus != 0) {
        NSLog(@"[VelikiyMoguchiy] lips setup: %@ exited with %d (see lips/setup.log)",
              executable.lastPathComponent, task.terminationStatus);
        return @"не удалось подготовить Python (подробности в lips/setup.log)";
    }
    return nil;
}

- (NSDictionary<NSString *, NSString *> *)toolEnvironment {
    NSMutableDictionary *environment = [[[NSProcessInfo processInfo] environment] mutableCopy];
    NSString *root = [self lipsRoot];
    environment[@"UV_CACHE_DIR"] = [root stringByAppendingPathComponent:@"uv-cache"];
    environment[@"UV_PYTHON_INSTALL_DIR"] = [root stringByAppendingPathComponent:@"python"];
    environment[@"UV_PYTHON_PREFERENCE"] = @"only-managed";
    environment[@"UV_NO_CONFIG"] = @"1";
    environment[@"UV_NO_PROGRESS"] = @"1";
    [environment removeObjectForKey:@"VIRTUAL_ENV"];
    [environment removeObjectForKey:@"UV_PROJECT_ENVIRONMENT"];
    environment[@"PYTHONIOENCODING"] = @"utf-8";
    environment[@"PATH"] = @"/usr/bin:/bin:/usr/sbin:/sbin";
    return environment;
}

/// Replaces whatever is at `linkPath` with a symlink to `target`.
- (BOOL)linkPath:(NSString *)linkPath to:(NSString *)target {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:linkPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *temporary = [linkPath stringByAppendingString:@".new"];
    [fm removeItemAtPath:temporary error:nil];
    if (![fm createSymbolicLinkAtPath:temporary withDestinationPath:target error:nil]) return NO;
    // rename(2) swaps the link in one step, so the service never sees no model.
    return rename(temporary.fileSystemRepresentation, linkPath.fileSystemRepresentation) == 0;
}

- (NSString *)buildEnvironmentForRelease:(NSString *)tag {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *service = [self managedServiceDirectory];
    NSString *toolsDir = [[self lipsRoot] stringByAppendingPathComponent:@"tools"];
    NSString *archives = [self modelDirectory:kToolsModelPath];
    NSDictionary *environment = [self toolEnvironment];
    [fm createDirectoryAtPath:service withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:toolsDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *uv = [toolsDir stringByAppendingPathComponent:@"uv-aarch64-apple-darwin/uv"];
    NSString *failure = [self run:@"/usr/bin/tar"
                        arguments:@[ @"-xzf", [archives stringByAppendingPathComponent:SPLipsRuntimePolicy.uvArchiveName],
                                     @"-C", toolsDir ]
                      environment:environment output:nil];
    if (failure) return failure;
    if (![fm isExecutableFileAtPath:uv]) return @"в архиве uv нет программы uv";

    NSArray *copies = @[ @[ [self bundledCodeDirectory], service ], @[ [self bundledToolsDirectory] ?: @"", toolsDir ] ];
    for (NSArray *pair in copies) {
        for (NSString *name in [fm contentsOfDirectoryAtPath:pair[0] error:nil]) {
            NSString *destination = [pair[1] stringByAppendingPathComponent:name];
            [fm removeItemAtPath:destination error:nil];
            if (![fm copyItemAtPath:[pair[0] stringByAppendingPathComponent:name] toPath:destination error:nil]) {
                return @"не удалось скопировать код сервиса губ";
            }
        }
    }

    NSString *multivsr = [service stringByAppendingPathComponent:@"multivsr"];
    if (![fm fileExistsAtPath:multivsr]) {
        NSString *unpack = [[self lipsRoot] stringByAppendingPathComponent:@"unpack"];
        [fm removeItemAtPath:unpack error:nil];
        [fm createDirectoryAtPath:unpack withIntermediateDirectories:YES attributes:nil error:nil];
        failure = [self run:@"/usr/bin/tar"
                  arguments:@[ @"-xzf", [archives stringByAppendingPathComponent:SPLipsRuntimePolicy.multivsrArchiveName],
                               @"-C", unpack ]
                environment:environment output:nil];
        if (failure) return failure;
        NSString *unpacked = [unpack stringByAppendingPathComponent:SPLipsRuntimePolicy.multivsrArchiveRoot];
        if (![fm moveItemAtPath:unpacked toPath:multivsr error:nil]) return @"в архиве MultiVSR не та папка";
        [fm removeItemAtPath:unpack error:nil];
    }

    [self reportStep:@"Шаг 4 из 5. Python и библиотеки" detail:@"uv ставит Python 3.13 и PyTorch" progress:-1];
    // --inexact keeps the ffmpeg package below, which is not in uv.lock.
    failure = [self run:uv arguments:@[ @"sync", @"--frozen", @"--inexact", @"--project", service ]
            environment:environment output:nil];
    if (failure) return failure;
    NSString *python = [service stringByAppendingPathComponent:@".venv/bin/python"];
    [self reportStep:@"Шаг 4 из 5. Python и библиотеки" detail:@"ffmpeg для кадров с камеры" progress:-1];
    failure = [self run:uv arguments:@[ @"pip", @"install", @"--python", python, kFfmpegPackage ]
            environment:environment output:nil];
    if (failure) return failure;
    NSString *ffmpegPath = nil;
    failure = [self run:python
              arguments:@[ @"-I", @"-c", @"import imageio_ffmpeg; print(imageio_ffmpeg.get_ffmpeg_exe())" ]
            environment:environment output:&ffmpegPath];
    if (failure) return failure;
    ffmpegPath = [ffmpegPath stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (![fm isExecutableFileAtPath:ffmpegPath] ||
        ![self linkPath:[service stringByAppendingPathComponent:@"bin/ffmpeg"] to:ffmpegPath]) {
        return @"не удалось подготовить ffmpeg";
    }

    [self reportStep:@"Шаг 4 из 5. Правки MultiVSR для Apple Silicon" detail:nil progress:-1];
    failure = [self run:python arguments:@[ @"multivsr_compat.py", @"multivsr" ] environment:environment output:nil];
    if (failure) return failure;
    failure = [self run:python arguments:@[ @"multivsr_compat.py", @"--check", @"multivsr" ]
            environment:environment output:nil];
    if (failure) {
        // A copy edited some other way cannot be fixed in place; the next run unpacks it afresh.
        [fm removeItemAtPath:multivsr error:nil];
        return @"код MultiVSR не прошёл проверку, запустите установку ещё раз";
    }

    if (![self linkPath:[service stringByAppendingPathComponent:@"weights"] to:[self modelDirectory:kBaseModelPath]] ||
        ![self linkPath:[service stringByAppendingPathComponent:@"results/pod_runs/t1/checkpoints/me1"]
                     to:[self modelDirectory:[self releaseModelPathForTag:tag]]]) {
        return @"не удалось подключить модели к сервису";
    }
    [fm removeItemAtPath:environment[@"UV_CACHE_DIR"] error:nil];
    return nil;
}

#pragma mark - Model updates

- (void)checkForModelUpdateWithHandler:(void (^)(NSString *))handler {
    NSString *installed = [self installedReleaseTag];
    if (!installed || [self usesDeveloperCheckout] || self.isInstalling) return;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDate *last = [defaults objectForKey:kLastModelCheckKey];
    if (![SPUpdatePolicy isCheckDueWithLastCheck:[last isKindOfClass:[NSDate class]] ? last : nil now:[NSDate date]]) return;
    [defaults setObject:[NSDate date] forKey:kLastModelCheckKey];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *tag = [self fetchNewestModel:nil fallback:nil error:nil];
        NSString *prefix = SPLipsRuntimePolicy.releaseTagPrefix;
        NSString *newestVersion = [SPUpdatePolicy versionFromTag:tag prefix:prefix];
        NSString *installedVersion = [SPUpdatePolicy versionFromTag:installed prefix:prefix];
        if (!newestVersion || !installedVersion ||
            [SPUpdatePolicy compareVersion:newestVersion toVersion:installedVersion] != NSOrderedDescending) {
            return;
        }
        NSLog(@"[VelikiyMoguchiy] lips: model %@ is available (installed %@)", tag, installed);
        dispatch_async(dispatch_get_main_queue(), ^{
            handler(tag);
        });
    });
}

- (void)offerModelUpdate:(NSString *)tag completion:(void (^)(BOOL))completion {
    if (self.isInstalling) {
        [self.panel present];
        if (completion) completion(NO);
        return;
    }
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"Новая модель губ %@", tag];
    alert.informativeText = [NSString stringWithFormat:
        @"Установлена %@. Новая модель скачается с Hugging Face или из релиза на GitHub (около 110 МБ) и проверится по SHA-256; "
        @"прежняя будет удалена после установки.", [self installedReleaseTag] ?: @"—"];
    [alert addButtonWithTitle:@"Обновить"];
    [alert addButtonWithTitle:@"Позже"];
    [NSApp activateIgnoringOtherApps:YES];
    if ([alert runModal] != NSAlertFirstButtonReturn) {
        if (completion) completion(NO);
        return;
    }

    NSString *previous = [self installedReleaseTag];
    self.isInstalling = YES;
    self.cancelled = NO;
    SPProgressPanel *panel = [[SPProgressPanel alloc] initWithTitle:@"Обновление модели губ"];
    __weak typeof(self) weakSelf = self;
    panel.cancelHandler = ^{
        [weakSelf cancelWork];
    };
    self.panel = panel;
    [panel present];
    dispatch_async(self.workQueue, ^{
        NSDictionary *manifest = nil, *fallback = nil;
        NSString *failure = nil;
        NSString *newTag = [self fetchNewestModel:&manifest fallback:&fallback error:&failure];
        if (newTag) {
            NSString *path = [self releaseModelPathForTag:newTag];
            failure = [self installModelManifest:manifest fallback:fallback tag:newTag
                                            step:[NSString stringWithFormat:@"Загрузка модели губ %@", newTag]];
            if (!failure && sp_model_status(path.UTF8String, 0) != 2) failure = @"файлы модели не прошли проверку";
            if (!failure && ![self linkPath:[[self managedServiceDirectory]
                                                stringByAppendingPathComponent:@"results/pod_runs/t1/checkpoints/me1"]
                                         to:[self modelDirectory:path]]) {
                failure = @"не удалось подключить модель к сервису";
            }
            if (!failure) {
                [self updateState:@{@"release" : newTag}];
                if (previous && ![previous isEqualToString:newTag]) {
                    [[NSFileManager defaultManager] removeItemAtPath:[self modelDirectory:[self releaseModelPathForTag:previous]]
                                                               error:nil];
                }
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.isInstalling = NO;
            if (!failure) {
                [[SPLipsService sharedService] shutdown];
                [panel finishWithMessage:[NSString stringWithFormat:@"Модель губ %@ установлена.", newTag] success:YES];
            } else if (self.cancelled) {
                [panel finishWithMessage:@"Остановлено. Работает прежняя модель." success:NO];
            } else {
                [panel finishWithMessage:[@"Не получилось: " stringByAppendingString:failure] success:NO];
            }
            if (completion) completion(failure == nil);
        });
    });
}

#pragma mark - Alerts

- (void)showAlert:(NSString *)message info:(NSString *)info {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = message;
    alert.informativeText = info;
    [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
}

@end
