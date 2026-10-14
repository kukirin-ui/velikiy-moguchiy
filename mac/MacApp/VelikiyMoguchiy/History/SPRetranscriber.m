#import "SPRetranscriber.h"
#import "SPHistoryManager.h"
#import "SPErrorExplainer.h"

NSNotificationName const SPRetranscriptionStateDidChangeNotification =
    @"SPRetranscriptionStateDidChangeNotification";

static const NSTimeInterval kRetranscribeTimeout = 60.0;
static const NSInteger kAutoRetryMinDurationMs = 500;
static NSString *const kNoSpeechReason = @"в записи не было речи";

@implementation SPRetranscriptionResult
@end

@interface SPRetranscriber () {
    NSMutableSet<NSNumber *> *_running;
}
@end

@implementation SPRetranscriber

+ (instancetype)sharedRetranscriber {
    static SPRetranscriber *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SPRetranscriber alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) _running = [NSMutableSet set];
    return self;
}

- (BOOL)isRunningForSessionId:(int64_t)sessionId {
    return [_running containsObject:@(sessionId)];
}

#pragma mark - Running

- (BOOL)retranscribeSession:(NSDictionary *)session
                 completion:(void (^)(SPRetranscriptionResult *))completion {
    NSNumber *sessionId = session[@"id"];
    NSString *audioPath = session[@"audio_path"];
    if (!sessionId || audioPath.length == 0 || [_running containsObject:sessionId]) return NO;

    NSString *appBundleId = session[@"app_bundle_id"];
    BOOL hasText = [session[@"text"] length] > 0;
    [_running addObject:sessionId];
    [[NSNotificationCenter defaultCenter] postNotificationName:SPRetranscriptionStateDidChangeNotification
                                                        object:self];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        SPRetranscriptionResult *result = [SPRetranscriber runCliForAudioPath:audioPath
                                                                  appBundleId:appBundleId];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_running removeObject:sessionId];
            [self store:result forSessionId:sessionId.longLongValue hasText:hasText];
            [[NSNotificationCenter defaultCenter] postNotificationName:SPRetranscriptionStateDidChangeNotification
                                                                object:self];
            if (completion) completion(result);
        });
    });
    return YES;
}

/// A failed or silent run never wipes text the row already has.
- (void)store:(SPRetranscriptionResult *)result forSessionId:(int64_t)sessionId hasText:(BOOL)hasText {
    SPHistoryManager *history = [SPHistoryManager sharedManager];
    if ([result.status isEqualToString:@"ok"]) {
        [history updateSessionWithId:sessionId text:result.text status:@"ok" error:nil];
    } else if (!hasText) {
        [history updateSessionWithId:sessionId text:nil status:result.status error:result.error];
    }
}

+ (SPRetranscriptionResult *)failureWithReason:(NSString *)reason {
    SPRetranscriptionResult *result = [[SPRetranscriptionResult alloc] init];
    result.status = @"error";
    result.error = reason;
    return result;
}

+ (NSString *)cliPath {
    return [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"Contents/MacOS/velikiy-moguchiy-cli"];
}

+ (SPRetranscriptionResult *)runCliForAudioPath:(NSString *)audioPath appBundleId:(NSString *)appBundleId {
    NSString *cli = [self cliPath];
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:cli]) {
        return [self failureWithReason:[SPHistoryManager errorReasonWithSummary:@"не найден velikiy-moguchiy-cli"
                                                                providerMessage:cli]];
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:audioPath]) {
        return [self failureWithReason:@"файл записи не найден"];
    }

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:cli];
    task.arguments = [self cliArgumentsForAudioPath:audioPath appBundleId:appBundleId];
    task.environment = [self childEnvironmentFrom:NSProcessInfo.processInfo.environment];
    NSPipe *outPipe = [NSPipe pipe];
    NSPipe *errPipe = [NSPipe pipe];
    task.standardOutput = outPipe;
    task.standardError = errPipe;
    task.standardInput = [NSFileHandle fileHandleWithNullDevice];

    dispatch_semaphore_t exited = dispatch_semaphore_create(0);
    task.terminationHandler = ^(NSTask *finished) {
        dispatch_semaphore_signal(exited);
    };
    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        return [self failureWithReason:[SPHistoryManager errorReasonWithSummary:@"не удалось запустить velikiy-moguchiy-cli"
                                                                providerMessage:launchError.localizedDescription]];
    }

    __block NSData *outData = nil;
    __block NSData *errData = nil;
    dispatch_group_t readers = dispatch_group_create();
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    dispatch_group_async(readers, queue, ^{
        outData = [outPipe.fileHandleForReading readDataToEndOfFile];
    });
    dispatch_group_async(readers, queue, ^{
        errData = [errPipe.fileHandleForReading readDataToEndOfFile];
    });

    BOOL timedOut = dispatch_semaphore_wait(
        exited, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRetranscribeTimeout * NSEC_PER_SEC))) != 0;
    if (timedOut) {
        [task terminate];
        dispatch_semaphore_wait(exited, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    }
    dispatch_group_wait(readers, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));

    if (timedOut) {
        return [self failureWithReason:[SPHistoryManager errorReasonWithSummary:@"таймаут повторного распознавания"
                                                                providerMessage:@"velikiy-moguchiy-cli не ответил за 60 с"]];
    }

    NSString *stdoutText = [[[NSString alloc] initWithData:outData ?: NSData.data encoding:NSUTF8StringEncoding]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *stderrText = [[NSString alloc] initWithData:errData ?: NSData.data encoding:NSUTF8StringEncoding];

    if (task.terminationStatus != 0) {
        return [self failureWithReason:[self errorReasonForCliStderr:stderrText]];
    }
    SPRetranscriptionResult *result = [[SPRetranscriptionResult alloc] init];
    if (stdoutText.length == 0) {
        result.status = @"empty";
        result.error = kNoSpeechReason;
        return result;
    }
    result.status = @"ok";
    result.text = stdoutText;
    return result;
}

#pragma mark - Pure helpers

+ (BOOL)shouldAutoRetryForStatus:(NSString *)status
                      durationMs:(NSInteger)durationMs
                     audioExists:(BOOL)audioExists
                         enabled:(BOOL)enabled {
    return enabled && audioExists && [status isEqualToString:@"error"] &&
           durationMs >= kAutoRetryMinDurationMs;
}

+ (NSArray<NSString *> *)cliArgumentsForAudioPath:(NSString *)audioPath
                                      appBundleId:(NSString *)appBundleId {
    NSMutableArray<NSString *> *arguments =
        [NSMutableArray arrayWithObjects:@"transcribe", audioPath, @"-p", @"qwen", nil];
    if (appBundleId.length > 0) {
        [arguments addObjectsFromArray:@[ @"--app", appBundleId ]];
    }
    return arguments;
}

+ (NSDictionary<NSString *, NSString *> *)childEnvironmentFrom:(NSDictionary<NSString *, NSString *> *)environment {
    NSMutableDictionary *result = [environment mutableCopy] ?: [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSString *entry in [result[@"PATH"] componentsSeparatedByString:@":"]) {
        if (entry.length > 0) [paths addObject:entry];
    }
    for (NSString *extra in @[ @"/opt/homebrew/bin", @"/usr/local/bin", @"/usr/bin", @"/bin" ]) {
        if (![paths containsObject:extra]) [paths addObject:extra];
    }
    result[@"PATH"] = [paths componentsJoinedByString:@":"];
    return result;
}

+ (NSString *)errorReasonForCliStderr:(NSString *)stderrText {
    NSString *message = nil;
    NSString *lastLine = nil;
    for (NSString *line in [stderrText componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length == 0) continue;
        lastLine = trimmed;
        if ([trimmed hasPrefix:@"error:"]) message = [[trimmed substringFromIndex:6]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    }
    NSString *provider = message ?: lastLine ?: @"";
    return [SPHistoryManager errorReasonWithSummary:[self summaryForProviderMessage:provider]
                                    providerMessage:provider];
}

+ (NSString *)summaryForProviderMessage:(NSString *)message {
    if (message.length == 0) return @"ошибка распознавания";
    if ([message.lowercaseString containsString:@"ffmpeg"]) return @"не удалось декодировать запись (ffmpeg)";
    switch ([SPErrorExplainer kindForMessage:message]) {
        case SPErrorKindNoKey:
        case SPErrorKindBadKey:
        case SPErrorKindAccessDenied:
            return @"проблема с API-ключом";
        case SPErrorKindNoBalance:
        case SPErrorKindRateLimit:
            return @"лимит или баланс ключа исчерпан";
        case SPErrorKindTimeout:
            return @"сервис распознавания не ответил вовремя";
        case SPErrorKindNetwork:
            return @"нет связи с сервисом распознавания";
        case SPErrorKindService:
            return @"сбой сервиса распознавания";
        case SPErrorKindLocalModel:
            return @"нет локальной модели распознавания";
        case SPErrorKindMicrophone:
            return @"проблема с аудио";
        case SPErrorKindUnknown:
            break;
    }
    return @"ошибка распознавания";
}

@end
