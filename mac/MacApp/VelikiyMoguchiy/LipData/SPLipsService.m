#import "SPLipsService.h"
#import "SPLipsPolicy.h"
#import "velikiy_moguchiy_core.h"
#import "SPAppPaths.h"

/// Python start, imports and binding the port take a few seconds; the model
/// itself loads later, in the background.
static const NSTimeInterval kStartTimeout = 20.0;
/// Covers a cold model load (about 10 s) plus preprocessing and rescoring.
static const NSTimeInterval kTranscribeTimeout = 120.0;
static const unsigned long long kMaxLogBytes = 5ull * 1024 * 1024;

static NSString *configString(const char *keyPath) {
    char *raw = sp_config_get(keyPath);
    if (!raw) return @"";
    NSString *value = [[NSString stringWithUTF8String:raw] ?: @""
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    sp_core_free_string(raw);
    return value;
}

static BOOL configFlag(const char *keyPath, BOOL defaultValue) {
    NSString *value = configString(keyPath).lowercaseString;
    if (value.length == 0) return defaultValue;
    return [value isEqualToString:@"true"] || [value isEqualToString:@"1"] ||
           [value isEqualToString:@"yes"] || [value isEqualToString:@"on"];
}

@interface SPLipsService () {
    dispatch_queue_t _queue;  // process management and the blocking HTTP calls
    NSURLSession *_session;
}
/// Set on _queue; read by -shutdown from the main thread.
@property (atomic, strong) NSTask *task;
@end

@implementation SPLipsService

+ (instancetype)sharedService {
    static SPLipsService *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SPLipsService alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("velikiy-moguchiy.lips.service", DISPATCH_QUEUE_SERIAL);
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.connectionProxyDictionary = @{};
        _session = [NSURLSession sessionWithConfiguration:configuration];
    }
    return self;
}

- (NSString *)serviceDirectory {
    return [SPLipsService lipreadDirectory];
}

+ (NSString *)lipreadDirectory {
    NSString *dir = [configString("lips.service_dir") stringByExpandingTildeInPath];
    if (dir.length == 0) {
        // The folder was lipread-ru before the monorepo layout; keep using such a checkout.
        dir = [NSHomeDirectory() stringByAppendingPathComponent:@"velikiy-moguchiy/lipread"];
        NSString *legacy = [NSHomeDirectory() stringByAppendingPathComponent:@"velikiy-moguchiy/lipread-ru"];
        BOOL isDir = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:dir]
            && [[NSFileManager defaultManager] fileExistsAtPath:legacy isDirectory:&isDir] && isDir) {
            dir = legacy;
        }
    }
    return dir.stringByStandardizingPath;
}

- (NSURL *)urlForPath:(NSString *)path {
    NSInteger port = [SPLipsPolicy portFromConfigValue:configString("lips.port")];
    return [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%ld%@", (long)port, path]];
}

/// Blocking; call on _queue. Returns the decoded JSON object (nil on any failure).
- (NSDictionary *)requestPath:(NSString *)path
                         body:(NSDictionary *)body
                      timeout:(NSTimeInterval)timeout
                   statusCode:(NSInteger *)statusCode
                        error:(NSError **)error {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[self urlForPath:path]];
    request.timeoutInterval = timeout;
    if (body) {
        request.HTTPMethod = @"POST";
        request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    }
    __block NSData *data = nil;
    __block NSError *failure = nil;
    __block NSInteger code = 0;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[_session dataTaskWithRequest:request completionHandler:^(NSData *d, NSURLResponse *response, NSError *e) {
        data = d;
        failure = e;
        if ([response isKindOfClass:[NSHTTPURLResponse class]]) code = ((NSHTTPURLResponse *)response).statusCode;
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    if (statusCode) *statusCode = code;
    if (error) *error = failure;
    if (!data) return nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [json isKindOfClass:[NSDictionary class]] ? json : nil;
}

- (BOOL)isHealthy {
    NSInteger code = 0;
    NSDictionary *health = [self requestPath:@"/health" body:nil timeout:1.0 statusCode:&code error:nil];
    return code == 200 && health[@"pid"] != nil;
}

/// On _queue. Returns nil when the service answers, else why it cannot.
- (NSString *)ensureRunning {
    if ([self isHealthy]) return nil;
    if (!self.task.isRunning) {
        NSString *failure = [self launch];
        if (failure) return failure;
    }
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:kStartTimeout];
    while ([deadline timeIntervalSinceNow] > 0) {
        if ([self isHealthy]) return nil;
        if (!self.task.isRunning) break;
        [NSThread sleepForTimeInterval:0.2];
    }
    NSLog(@"[VelikiyMoguchiy] lips: the service did not come up (see %@)", SPAppDataPath(@"lips_service.log"));
    return @"Сервис губ не запустился";
}

/// On _queue.
- (NSString *)launch {
    NSString *dir = [self serviceDirectory];
    NSString *python = [dir stringByAppendingPathComponent:@".venv/bin/python"];
    NSString *script = [dir stringByAppendingPathComponent:@"lips_service.py"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm isExecutableFileAtPath:python] || ![fm fileExistsAtPath:script]) {
        NSLog(@"[VelikiyMoguchiy] lips: %@ or %@ is missing; check lips.service_dir", python, script);
        return @"Нет сервиса губ (lips.service_dir)";
    }
    NSString *logPath = SPAppDataPath(@"lips_service.log");
    NSNumber *size = [[fm attributesOfItemAtPath:logPath error:nil] objectForKey:NSFileSize];
    if (!size || size.unsignedLongLongValue > kMaxLogBytes) {
        [fm createFileAtPath:logPath contents:nil attributes:@{NSFilePosixPermissions : @(0600)}];
    }
    NSFileHandle *log = [NSFileHandle fileHandleForWritingAtPath:logPath];
    [log seekToEndOfFile];

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:python];
    task.currentDirectoryURL = [NSURL fileURLWithPath:dir];
    task.arguments = [SPLipsPolicy serviceArgumentsWithScript:script
                                                         port:[SPLipsPolicy portFromConfigValue:configString("lips.port")]
                                                  idleMinutes:[SPLipsPolicy idleMinutesFromConfigValue:configString("lips.idle_minutes")]
                                                    parentPid:getpid()];
    NSMutableDictionary *environment = [[[NSProcessInfo processInfo] environment] mutableCopy];
    environment[@"PYTHONUNBUFFERED"] = @"1";
    environment[@"PYTHONIOENCODING"] = @"utf-8";
    // ffmpeg for the face crop; GUI apps do not inherit the shell's PATH.
    environment[@"PATH"] = [@"/opt/homebrew/bin:/usr/local/bin:" stringByAppendingString:environment[@"PATH"] ?: @"/usr/bin:/bin"];
    task.environment = environment;
    task.standardOutput = log ?: [NSFileHandle fileHandleWithNullDevice];
    task.standardError = log ?: [NSFileHandle fileHandleWithNullDevice];
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        NSLog(@"[VelikiyMoguchiy] lips: cannot start the service: %@", error);
        return @"Сервис губ не запустился";
    }
    self.task = task;
    NSLog(@"[VelikiyMoguchiy] lips: service started (pid %d)", task.processIdentifier);
    return nil;
}

- (void)warmUp {
    dispatch_async(_queue, ^{
        if ([self ensureRunning]) return;
        [self requestPath:@"/warm" body:@{} timeout:2.0 statusCode:nil error:nil];
    });
}

- (void)transcribeClipAtPath:(NSString *)path
                     context:(NSString *)context
                  completion:(void (^)(NSDictionary *, NSString *))completion {
    BOOL rescore = configFlag("lips.rescore", YES);
    dispatch_async(_queue, ^{
        NSString *failure = [self ensureRunning];
        NSDictionary *reply = nil;
        if (!failure) {
            NSInteger code = 0;
            NSError *error = nil;
            reply = [self requestPath:@"/transcribe"
                                 body:@{@"path" : path, @"rescore" : @(rescore), @"context" : context ?: @""}
                              timeout:kTranscribeTimeout
                           statusCode:&code
                                error:&error];
            if (code != 200) {
                NSString *detail = [reply[@"error"] isKindOfClass:[NSString class]] ? reply[@"error"] : error.localizedDescription;
                NSLog(@"[VelikiyMoguchiy] lips: transcribe failed (HTTP %ld): %@", (long)code, detail);
                failure = [detail containsString:@"MemoryError"] ? @"Мало памяти для модели губ"
                        : [detail containsString:@"лицо не найдено"] ? @"Лицо не найдено в кадре"
                        : @"Губы: ошибка распознавания";
                reply = nil;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(reply, failure);
        });
    });
}

- (void)shutdown {
    NSTask *task = self.task;
    if (task.isRunning) [task terminate];
}

@end
