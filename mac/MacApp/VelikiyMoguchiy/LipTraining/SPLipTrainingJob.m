#import "SPLipTrainingJob.h"
#import "SPAppPaths.h"
#import "SPLipCaptureManager.h"
#import "SPLipsService.h"

#include <errno.h>
#include <signal.h>

/// scan reads the clip sidecars and starts Python: a few seconds at most.
static const NSTimeInterval kShortCommandTimeout = 30.0;

@interface SPLipTrainingJob () {
    dispatch_queue_t _queue;  // the blocking process calls
}
/// The last job this app started; kept so the NSTask is not released while it runs.
@property (atomic, strong) NSTask *task;
@end

@implementation SPLipTrainingJob

+ (instancetype)sharedJob {
    static SPLipTrainingJob *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SPLipTrainingJob alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("velikiy-moguchiy.lips.training", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (NSString *)pythonPath {
    return [[SPLipsService lipreadDirectory] stringByAppendingPathComponent:@".venv/bin/python"];
}

- (NSString *)scriptPath {
    return [[SPLipsService lipreadDirectory] stringByAppendingPathComponent:@"train_on_me.py"];
}

/// nil when the lipread checkout can run the job, else what is missing.
- (NSString *)setupProblem {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm isExecutableFileAtPath:[self pythonPath]]) {
        return @"Нет окружения lipread (.venv): запустите lipread/setup.sh или укажите lips.service_dir";
    }
    if (![fm fileExistsAtPath:[self scriptPath]]) {
        return @"В папке lipread нет train_on_me.py: обновите её (lips.service_dir)";
    }
    return nil;
}

- (NSDictionary<NSString *, NSString *> *)environmentForJob:(BOOL)job {
    NSMutableDictionary *environment = [[[NSProcessInfo processInfo] environment] mutableCopy];
    environment[@"PYTHONUNBUFFERED"] = @"1";
    environment[@"PYTHONIOENCODING"] = @"utf-8";
    // ffmpeg for the face crops; GUI apps do not inherit the shell's PATH.
    environment[@"PATH"] = [@"/opt/homebrew/bin:/usr/local/bin:" stringByAppendingString:environment[@"PATH"] ?: @"/usr/bin:/bin"];
    if (job) {
        // The one R11 allowance for ML on the Mac: memguard.py and tools/mem_guard.py let through only the
        // scripts of this job with it. Only this user-started job gets the variable.
        environment[@"VELIKIY_MOGUCHIY_APP_JOB"] = @"train-on-me";
    } else {
        [environment removeObjectForKey:@"VELIKIY_MOGUCHIY_APP_JOB"];
    }
    return environment;
}

- (NSTask *)taskForCommand:(NSString *)command mode:(SPLipTrainingMode)mode {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:[self pythonPath]];
    task.currentDirectoryURL = [NSURL fileURLWithPath:[SPLipsService lipreadDirectory]];
    task.arguments = [SPLipTrainingPolicy argumentsWithScript:[self scriptPath]
                                                      command:command
                                                         mode:mode
                                                      appData:SPAppDataDirectory()
                                                     clipsDir:[SPLipCaptureManager dataDirectory]];
    task.environment = [self environmentForJob:[command isEqualToString:@"run"]];
    return task;
}

/// On _queue. Runs a short command and decodes the JSON line it prints.
- (NSDictionary *)runShortCommand:(NSString *)command error:(NSString **)error {
    NSString *problem = [self setupProblem];
    if (problem) {
        if (error) *error = problem;
        return nil;
    }
    NSTask *task = [self taskForCommand:command mode:SPLipTrainingModeLight];
    NSPipe *output = [NSPipe pipe];
    task.standardOutput = output;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        NSLog(@"[VelikiyMoguchiy] lips training: cannot run %@: %@", command, launchError);
        if (error) *error = @"Не удалось запустить lipread/train_on_me.py";
        return nil;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kShortCommandTimeout * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (task.isRunning) [task terminate];
    });
    NSData *data = [output.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    id json = data.length > 0 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![json isKindOfClass:[NSDictionary class]]) {
        NSLog(@"[VelikiyMoguchiy] lips training: %@ exited with %d and no JSON", command, task.terminationStatus);
        if (error) *error = @"lipread/train_on_me.py не ответил";
        return nil;
    }
    return json;
}

- (void)scanWithCompletion:(void (^)(NSDictionary *, NSString *))completion {
    dispatch_async(_queue, ^{
        NSString *error = nil;
        NSDictionary *scan = [self runShortCommand:@"scan" error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(scan, error);
        });
    });
}

- (void)startMode:(SPLipTrainingMode)mode completion:(void (^)(NSString *))completion {
    dispatch_async(_queue, ^{
        NSString *failure = [self setupProblem];
        if (!failure) {
            NSTask *task = [self taskForCommand:@"run" mode:mode];
            // The job writes its own log (lips_training/job.log) and status.
            task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
            task.standardError = [NSFileHandle fileHandleWithNullDevice];
            NSError *error = nil;
            if ([task launchAndReturnError:&error]) {
                self.task = task;
                NSLog(@"[VelikiyMoguchiy] lips training: started %@ (pid %d)",
                      [SPLipTrainingPolicy modeArgument:mode], task.processIdentifier);
            } else {
                NSLog(@"[VelikiyMoguchiy] lips training: cannot start: %@", error);
                failure = @"Не удалось запустить обучение";
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(failure);
        });
    });
}

- (void)cancelWithCompletion:(void (^)(NSString *))completion {
    dispatch_async(_queue, ^{
        NSString *error = nil;
        NSDictionary *reply = [self runShortCommand:@"cancel" error:&error];
        if (reply && ![reply[@"ok"] boolValue]) {
            error = [reply[@"reason"] isKindOfClass:[NSString class]] ? reply[@"reason"] : @"Не удалось отменить";
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(error);
        });
    });
}

- (void)rollbackWithCompletion:(void (^)(NSDictionary *, NSString *))completion {
    dispatch_async(_queue, ^{
        NSString *error = nil;
        NSDictionary *reply = [self runShortCommand:@"rollback" error:&error];
        if (reply && ![reply[@"ok"] boolValue]) {
            error = [reply[@"reason"] isKindOfClass:[NSString class]] ? reply[@"reason"] : @"Не удалось вернуть модель";
            reply = nil;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(reply, error);
        });
    });
}

- (NSDictionary *)readStatus {
    NSData *data = [NSData dataWithContentsOfFile:SPAppDataPath(@"lips_training/status.json")];
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![json isKindOfClass:[NSDictionary class]]) return nil;
    id pidValue = ((NSDictionary *)json)[@"pid"];
    pid_t pid = [pidValue isKindOfClass:[NSNumber class]] ? (pid_t)[pidValue intValue] : 0;
    BOOL alive = pid > 1 && (kill(pid, 0) == 0 || errno == EPERM);
    return [SPLipTrainingPolicy effectiveStatus:json processAlive:alive];
}

@end
