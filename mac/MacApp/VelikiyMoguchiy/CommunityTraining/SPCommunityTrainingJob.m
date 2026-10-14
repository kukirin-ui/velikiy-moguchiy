#import "SPCommunityTrainingJob.h"
#import "SPCommunityTrainingPolicy.h"
#import "SPLipsRuntime.h"
#import "SPLipsService.h"

static const NSTimeInterval kShortCommandTimeout = 30.0;
/// `send` uploads a few megabytes with the transport's own retries.
static const NSTimeInterval kSendTimeout = 15.0 * 60.0;
/// GitHub device codes live 15 minutes; the client gives up by itself then.
static const NSTimeInterval kLoginTimeout = 20.0 * 60.0;
static NSString *const kAppJob = @"help-train";

/// The lipread folder every lips feature runs from (a developer checkout or the app's managed environment).
static NSString *lipreadDirectory(void) {
    return [SPLipsService lipreadDirectory].stringByStandardizingPath;
}

@interface SPCommunityTrainingJob ()
/// The last background job this app started; kept so the NSTask is not released while it runs.
@property (atomic, strong, nullable) NSTask *jobTask;
@property (atomic, strong, nullable) NSTask *loginTask;
@property (atomic) NSUInteger loginGeneration;
@end

@implementation SPCommunityTrainingJob

+ (instancetype)sharedJob {
    static SPCommunityTrainingJob *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SPCommunityTrainingJob alloc] init];
    });
    return instance;
}

- (NSString *)federatedDirectory {
    return [[SPLipsRuntime sharedRuntime] federatedDirectory].stringByStandardizingPath;
}

/// A developer's federated/.venv when there is one, else the lips environment (its uv.lock has the client's packages).
- (NSString *)pythonPath {
    NSString *own = [self.federatedDirectory stringByAppendingPathComponent:@".venv/bin/python"];
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:own]) return own;
    return [lipreadDirectory() stringByAppendingPathComponent:@".venv/bin/python"];
}

- (BOOL)needsInstall {
    SPLipsRuntime *runtime = [SPLipsRuntime sharedRuntime];
    return !runtime.usesDeveloperCheckout && !runtime.isReady;
}

- (NSString *)setupProblem {
    if ([self needsInstall]) return [SPCommunityTrainingPolicy installNote];
    NSString *dir = self.federatedDirectory;
    NSFileManager *fm = [NSFileManager defaultManager];
    return [SPCommunityTrainingPolicy
        setupProblemForFederatedDirectory:dir
                             pythonExists:[fm isExecutableFileAtPath:[self pythonPath]]
                             scriptExists:[fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"client/community.py"]]];
}

- (NSTask *)taskForCommand:(NSString *)command value:(NSString *)value {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:[self pythonPath]];
    task.currentDirectoryURL = [NSURL fileURLWithPath:self.federatedDirectory isDirectory:YES];
    task.arguments = [[SPCommunityTrainingPolicy argumentsForCommand:command value:value]
        arrayByAddingObjectsFromArray:@[ @"--lipread-dir", lipreadDirectory() ]];
    NSMutableDictionary *environment = [[[NSProcessInfo processInfo] environment] mutableCopy];
    environment[@"PYTHONUNBUFFERED"] = @"1";
    environment[@"PYTHONIOENCODING"] = @"utf-8";
    // yt-dlp and ffmpeg live in Homebrew; GUI apps do not inherit the shell's PATH.
    environment[@"PATH"] =
        [@"/opt/homebrew/bin:/usr/local/bin:" stringByAppendingString:environment[@"PATH"] ?: @"/usr/bin:/bin"];
    // The memory guard lets ML through only for the job the user started.
    if ([command isEqualToString:@"run"]) {
        environment[@"VELIKIY_MOGUCHIY_APP_JOB"] = kAppJob;
    } else {
        [environment removeObjectForKey:@"VELIKIY_MOGUCHIY_APP_JOB"];
    }
    task.environment = environment;
    return task;
}

static NSString *lastLine(NSData *data) {
    NSString *text = data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    NSArray *lines = [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    for (NSString *line in lines.reverseObjectEnumerator) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length) return trimmed.length > 200 ? [trimmed substringToIndex:200] : trimmed;
    }
    return nil;
}

/// Blocking; off the main thread.
- (id)runBlocking:(NSString *)command value:(NSString *)value error:(NSString **)error {
    NSString *problem = [self setupProblem];
    if (problem) {
        if (error) *error = problem;
        return nil;
    }
    NSTask *task = [self taskForCommand:command value:value];
    NSPipe *output = [NSPipe pipe];
    NSPipe *errors = [NSPipe pipe];
    task.standardOutput = output;
    task.standardError = errors;
    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        NSLog(@"[VelikiyMoguchiy] help-train: cannot run %@: %@", command, launchError);
        if (error) *error = @"Не удалось запустить клиент обучения (federated/client/community.py)";
        return nil;
    }
    __block NSData *errorData = nil;
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        errorData = [errors.fileHandleForReading readDataToEndOfFile];
    });
    NSTimeInterval timeout = [command isEqualToString:@"send"] ? kSendTimeout : kShortCommandTimeout;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (task.isRunning) [task terminate];
    });
    NSData *data = [output.fileHandleForReading readDataToEndOfFile];
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    [task waitUntilExit];
    id json = [SPCommunityTrainingPolicy lastJSONValueInOutput:data];
    if (!json) {
        NSString *detail = lastLine(errorData);
        NSLog(@"[VelikiyMoguchiy] help-train: %@ exited with %d and no JSON: %@", command, task.terminationStatus,
              detail ?: @"(no stderr)");
        // the detail is a Python message in English: it goes to the system log, the card stays in Russian
        if (error) *error = @"Клиент обучения не ответил (подробности в системном журнале)";
    }
    return json;
}

- (void)runCommand:(NSString *)command value:(NSString *)value completion:(void (^)(id, NSString *))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *error = nil;
        id json = [self runBlocking:command value:value error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(json, error);
        });
    });
}

- (void)statusWithCompletion:(void (^)(NSDictionary *, NSString *))completion {
    [self runCommand:@"status" value:nil completion:^(id json, NSString *error) {
        NSDictionary *status = [SPCommunityTrainingPolicy statusFromJSON:json];
        completion(status, status ? nil : (error ?: @"Клиент обучения ответил непонятно"));
    }];
}

#pragma mark Login

- (BOOL)loginInProgress {
    return self.loginTask != nil;
}

- (void)cancelLogin {
    self.loginGeneration += 1;
    NSTask *task = self.loginTask;
    self.loginTask = nil;
    if (task.isRunning) [task terminate];
}

- (void)loginWithCodeHandler:(void (^)(NSString *, NSURL *))codeHandler
                  completion:(void (^)(BOOL, NSString *))completion {
    [self cancelLogin];
    NSUInteger generation = self.loginGeneration;
    NSString *problem = [self setupProblem];
    if (problem) {
        completion(NO, problem);
        return;
    }
    NSTask *task = [self taskForCommand:@"login" value:nil];
    NSPipe *output = [NSPipe pipe];
    task.standardOutput = output;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        NSLog(@"[VelikiyMoguchiy] help-train: cannot run login: %@", launchError);
        completion(NO, @"Не удалось запустить клиент обучения (federated/client/community.py)");
        return;
    }
    self.loginTask = task;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kLoginTimeout * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (task.isRunning) [task terminate];
    });
    __weak typeof(self) weakSelf = self;
    BOOL (^current)(void) = ^BOOL {
        return weakSelf.loginGeneration == generation;
    };
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileHandle *handle = output.fileHandleForReading;
        NSMutableData *buffer = [NSMutableData data];
        __block NSNumber *result = nil;
        __block NSString *resultError = nil;
        // Lines arrive minutes apart (the code first, the result once the user confirms on GitHub).
        for (;;) {
            NSData *chunk = handle.availableData;
            if (chunk.length == 0) break;
            [buffer appendData:chunk];
            NSRange newline;
            while ((newline = [buffer rangeOfData:[NSData dataWithBytes:"\n" length:1]
                                          options:0
                                            range:NSMakeRange(0, buffer.length)]).location != NSNotFound) {
                NSData *line = [buffer subdataWithRange:NSMakeRange(0, newline.location)];
                [buffer replaceBytesInRange:NSMakeRange(0, newline.location + 1) withBytes:NULL length:0];
                id json = [SPCommunityTrainingPolicy lastJSONValueInOutput:line];
                NSDictionary *code = [SPCommunityTrainingPolicy loginCodeFromJSON:json];
                if (code) {
                    NSURL *url = [NSURL URLWithString:code[@"verification_uri"]];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (current()) codeHandler(code[@"user_code"], url);
                    });
                    continue;
                }
                NSString *error = nil;
                NSNumber *loggedIn = [SPCommunityTrainingPolicy loginResultFromJSON:json error:&error];
                if (loggedIn) {
                    result = loggedIn;
                    resultError = error;
                }
            }
        }
        [task waitUntilExit];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!current()) return;
            weakSelf.loginTask = nil;
            if (result) {
                completion(result.boolValue, resultError);
            } else {
                completion(NO, @"Вход прервался: клиент обучения не сообщил результат");
            }
        });
    });
}

#pragma mark Background job

- (NSFileHandle *)jobLogHandle {
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/VelikiyMoguchiy"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [dir stringByAppendingPathComponent:@"help-train.log"];
    [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:@{NSFilePosixPermissions : @0600}];
    return [NSFileHandle fileHandleForWritingAtPath:path] ?: [NSFileHandle fileHandleWithNullDevice];
}

- (void)startWithCompletion:(void (^)(NSString *))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *failure = [self setupProblem];
        if (!failure) {
            NSTask *task = [self taskForCommand:@"run" value:nil];
            // The job reports through status.json; its output is only for diagnosing a failed start.
            task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
            task.standardError = [self jobLogHandle];
            NSError *error = nil;
            if ([task launchAndReturnError:&error]) {
                self.jobTask = task;
                NSLog(@"[VelikiyMoguchiy] help-train: started (pid %d)", task.processIdentifier);
            } else {
                NSLog(@"[VelikiyMoguchiy] help-train: cannot start: %@", error);
                failure = @"Не удалось запустить задание";
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(failure);
        });
    });
}

@end
