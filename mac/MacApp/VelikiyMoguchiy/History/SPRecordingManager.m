#import "SPRecordingManager.h"
#import "SPHistoryManager.h"
#import "velikiy_moguchiy_core.h"
#import "SPAppPaths.h"
#import <AudioToolbox/AudioToolbox.h>
#import <sys/stat.h>

static const NSInteger kDefaultRetentionDays = 30;
static const uint64_t kRetentionIntervalSeconds = 6 * 60 * 60;
static const Float64 kSampleRate = 16000.0;

static NSString *configString(const char *keyPath) {
    char *raw = sp_config_get(keyPath);
    if (!raw) return @"";
    NSString *value = [[NSString stringWithUTF8String:raw] ?: @""
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    sp_core_free_string(raw);
    return value;
}

static BOOL saveRecordingsEnabled(void) {
    NSString *value = configString("history.save_recordings").lowercaseString;
    if (value.length == 0) return YES;
    return ![value isEqualToString:@"false"] && ![value isEqualToString:@"0"] &&
           ![value isEqualToString:@"no"] && ![value isEqualToString:@"off"];
}

static NSInteger retentionDays(void) {
    NSString *value = configString("history.recordings_retention_days");
    if (value.length == 0) return kDefaultRetentionDays;
    return MAX(1, value.integerValue);
}

@interface SPRecordingManager () {
    dispatch_queue_t _queue;
    dispatch_source_t _retentionTimer;
    // Touched only on _queue.
    ExtAudioFileRef _file;
    NSString *_filePath;
    SInt64 _framesWritten;
}
@end

@implementation SPRecordingManager

+ (instancetype)sharedManager {
    static SPRecordingManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SPRecordingManager alloc] init];
    });
    return instance;
}

+ (NSString *)recordingsDirectory {
    return SPAppDataPath(@"recordings");
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("velikiy-moguchiy.recording", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

#pragma mark - Recording

- (NSString *)beginRecording {
    if (!saveRecordingsEnabled()) return nil;

    NSDate *now = [NSDate date];
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyy-MM-dd";
    NSString *dayDir = [[SPRecordingManager recordingsDirectory]
        stringByAppendingPathComponent:[formatter stringFromDate:now]];
    long long unixMs = (long long)([now timeIntervalSince1970] * 1000.0);
    NSString *path = [dayDir stringByAppendingPathComponent:
        [NSString stringWithFormat:@"%lld.m4a", unixMs]];

    dispatch_async(_queue, ^{
        [self closeFileLocked];
        [self openFileAtPath:path];
    });
    return path;
}

- (void)appendPCM:(const void *)buffer length:(uint32_t)length {
    if (!buffer || length < sizeof(int16_t)) return;
    NSData *copy = [NSData dataWithBytes:buffer length:length];
    dispatch_async(_queue, ^{
        if (!self->_file) return;
        UInt32 frames = (UInt32)(copy.length / sizeof(int16_t));
        AudioBufferList list;
        list.mNumberBuffers = 1;
        list.mBuffers[0].mNumberChannels = 1;
        list.mBuffers[0].mDataByteSize = (UInt32)(frames * sizeof(int16_t));
        list.mBuffers[0].mData = (void *)copy.bytes;
        OSStatus status = ExtAudioFileWrite(self->_file, frames, &list);
        if (status != noErr) {
            NSLog(@"[VelikiyMoguchiy] Recording write failed (%d); closing %@", (int)status, self->_filePath);
            [self closeFileLocked];
            return;
        }
        self->_framesWritten += frames;
    });
}

- (void)endRecording {
    dispatch_async(_queue, ^{
        [self closeFileLocked];
    });
}

- (void)endRecordingAndWait {
    dispatch_sync(_queue, ^{
        [self closeFileLocked];
    });
}

- (NSString *)existingPathForRecording:(NSString *)path {
    if (path.length == 0) return nil;
    __block BOOL exists = NO;
    dispatch_sync(_queue, ^{
        struct stat st;
        exists = stat(path.UTF8String, &st) == 0 && st.st_size > 0;
    });
    return exists ? path : nil;
}

- (void)openFileAtPath:(NSString *)path {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = [SPRecordingManager recordingsDirectory];
    NSDictionary *attrs = @{NSFilePosixPermissions : @(0700)};
    NSError *error = nil;
    if (![fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:attrs error:&error] ||
        ![fm createDirectoryAtPath:path.stringByDeletingLastPathComponent
       withIntermediateDirectories:YES attributes:attrs error:&error]) {
        NSLog(@"[VelikiyMoguchiy] Cannot create recordings directory: %@", error);
        return;
    }

    AudioStreamBasicDescription client = {0};
    client.mSampleRate = kSampleRate;
    client.mFormatID = kAudioFormatLinearPCM;
    client.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    client.mBitsPerChannel = 16;
    client.mChannelsPerFrame = 1;
    client.mBytesPerFrame = 2;
    client.mFramesPerPacket = 1;
    client.mBytesPerPacket = 2;

    AudioStreamBasicDescription aac = {0};
    aac.mSampleRate = kSampleRate;
    aac.mFormatID = kAudioFormatMPEG4AAC;
    aac.mChannelsPerFrame = 1;

    NSURL *url = [NSURL fileURLWithPath:path];
    ExtAudioFileRef file = NULL;
    OSStatus status = ExtAudioFileCreateWithURL((__bridge CFURLRef)url, kAudioFileM4AType, &aac,
                                                NULL, kAudioFileFlags_EraseFile, &file);
    if (status == noErr) {
        status = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
                                         sizeof(client), &client);
    }
    if (status != noErr) {
        NSLog(@"[VelikiyMoguchiy] Cannot open recording %@ (%d)", path, (int)status);
        if (file) ExtAudioFileDispose(file);
        return;
    }
    chmod(path.UTF8String, 0600);
    _file = file;
    _filePath = path;
    _framesWritten = 0;
}

/// Must run on _queue. Finalizes the file; a recording that never received
/// audio is removed instead of leaving an empty container behind.
- (void)closeFileLocked {
    if (!_file) return;
    ExtAudioFileDispose(_file);
    _file = NULL;
    if (_framesWritten == 0 && _filePath.length > 0) {
        [[NSFileManager defaultManager] removeItemAtPath:_filePath error:nil];
    }
    _filePath = nil;
    _framesWritten = 0;
}

#pragma mark - Retention

- (void)startRetention {
    if (_retentionTimer) return;
    _retentionTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(_retentionTimer, dispatch_walltime(NULL, 0),
                              kRetentionIntervalSeconds * NSEC_PER_SEC, 300 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(_retentionTimer, ^{
        [self purgeExpiredLocked];
    });
    dispatch_resume(_retentionTimer);
}

/// Must run on _queue.
- (void)purgeExpiredLocked {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = [[SPRecordingManager recordingsDirectory] stringByStandardizingPath];
    [fm createDirectoryAtPath:root
  withIntermediateDirectories:YES
                   attributes:@{NSFilePosixPermissions : @(0700)}
                        error:nil];
    NSString *rootPrefix = [root stringByAppendingString:@"/"];
    NSTimeInterval cutoff = [[NSDate date] timeIntervalSince1970] - retentionDays() * 86400.0;

    NSInteger removedFiles = 0;
    for (NSString *dayName in [fm contentsOfDirectoryAtPath:root error:nil]) {
        NSString *dayDir = [root stringByAppendingPathComponent:dayName];
        struct stat dayStat;
        if (lstat(dayDir.UTF8String, &dayStat) != 0 || !S_ISDIR(dayStat.st_mode)) continue;

        for (NSString *name in [fm contentsOfDirectoryAtPath:dayDir error:nil]) {
            if (![name.pathExtension isEqualToString:@"m4a"]) continue;
            NSString *path = [dayDir stringByAppendingPathComponent:name];
            if (![path hasPrefix:rootPrefix] || [path isEqualToString:_filePath]) continue;

            struct stat st;
            if (lstat(path.UTF8String, &st) != 0 || !S_ISREG(st.st_mode)) continue;
            long long unixMs = name.stringByDeletingPathExtension.longLongValue;
            NSTimeInterval stamp = unixMs > 0 ? unixMs / 1000.0 : (NSTimeInterval)st.st_mtime;
            if (stamp >= cutoff) continue;

            if ([fm removeItemAtPath:path error:nil]) {
                removedFiles++;
                [[SPHistoryManager sharedManager] detachAudioPath:path];
            }
        }

        NSArray<NSString *> *left = [fm contentsOfDirectoryAtPath:dayDir error:nil];
        if (left.count == 0 || (left.count == 1 && [left[0] isEqualToString:@".DS_Store"])) {
            [fm removeItemAtPath:[dayDir stringByAppendingPathComponent:@".DS_Store"] error:nil];
            rmdir(dayDir.UTF8String);
        }
    }
    if (removedFiles > 0) {
        NSLog(@"[VelikiyMoguchiy] Recording retention removed %ld file(s) older than %ld day(s)",
              (long)removedFiles, (long)retentionDays());
    }
}

@end
