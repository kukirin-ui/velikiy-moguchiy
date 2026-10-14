#import "SPLipCaptureManager.h"
#import "velikiy_moguchiy_core.h"
#import "SPAppPaths.h"
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <sys/stat.h>

const NSInteger SPLipCaptureFPS = 25;

/// A gap longer than this between two frames makes the clip unusable.
static const int64_t kMaxGapSlots = SPLipCaptureFPS / 2;
/// A finished clip that nobody resolved is deleted after this long.
static const double kStaleClipSeconds = 300.0;

typedef NS_ENUM(NSInteger, SPLipClipState) {
    SPLipClipStateWaiting = 0,   // armed, no frame written yet
    SPLipClipStateRecording,
    SPLipClipStateFinishing,
    SPLipClipStateDone,
};

static NSString *configString(const char *keyPath) {
    char *raw = sp_config_get(keyPath);
    if (!raw) return @"";
    NSString *value = [[NSString stringWithUTF8String:raw] ?: @""
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    sp_core_free_string(raw);
    return value;
}

static NSString *temporaryDirectory(void) {
    return SPAppDataPath(@"lipdata-tmp");
}

#pragma mark - SPLipClip

@interface SPLipClip ()
@property (nonatomic, assign) long long clipId;
@property (nonatomic, copy) NSString *temporaryPath;
@property (nonatomic, assign) double durationSec;
@property (nonatomic, assign) NSInteger width;
@property (nonatomic, assign) NSInteger height;
@property (nonatomic, assign) NSInteger captureWidth;
@property (nonatomic, assign) NSInteger captureHeight;
@property (nonatomic, assign) BOOL usable;
/// Set once the clip was resolved or discarded (atomic: read from other queues).
@property (atomic, assign) BOOL settled;
// Everything below is touched only on the manager's queue.
@property (nonatomic, assign) SPLipClipState state;
@property (nonatomic, assign) CMTime beginTime;
@property (nonatomic, assign) CMTime firstPts;
@property (nonatomic, assign) int64_t nextSlot;
@property (nonatomic, assign) NSInteger firstFrameLagMs;
@property (nonatomic, assign) NSInteger droppedFrames;
@property (nonatomic, assign) BOOL broken;
@property (nonatomic, assign) BOOL discardRequested;
@property (nonatomic, strong) AVAssetWriter *writer;
@property (nonatomic, strong) AVAssetWriterInput *writerInput;
@property (nonatomic, strong) AVAssetWriterInputPixelBufferAdaptor *adaptor;
@property (nonatomic, strong) dispatch_group_t finalized;
@end

@implementation SPLipClip

- (instancetype)init {
    self = [super init];
    if (self) {
        _finalized = dispatch_group_create();
        dispatch_group_enter(_finalized);
    }
    return self;
}

- (BOOL)waitUntilFinalizedWithTimeout:(NSTimeInterval)seconds {
    return dispatch_group_wait(self.finalized,
                               dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC))) == 0;
}

@end

#pragma mark - SPLipCaptureManager

@interface SPLipCaptureManager () <AVCaptureVideoDataOutputSampleBufferDelegate> {
    dispatch_queue_t _queue;         // clip state + sample buffers
    dispatch_queue_t _sessionQueue;  // session configuration and start / stop
    dispatch_queue_t _workQueue;     // saving files
    NSMutableArray<SPLipClip *> *_activeClips;  // on _queue
    // On _sessionQueue.
    AVCaptureSession *_session;
    AVCaptureDevice *_device;
    BOOL _observersInstalled;
}
@end

@implementation SPLipCaptureManager

+ (instancetype)sharedManager {
    static SPLipCaptureManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SPLipCaptureManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("velikiy-moguchiy.lipdata.frames", DISPATCH_QUEUE_SERIAL);
        _sessionQueue = dispatch_queue_create("velikiy-moguchiy.lipdata.session", DISPATCH_QUEUE_SERIAL);
        _workQueue = dispatch_queue_create("velikiy-moguchiy.lipdata.save", DISPATCH_QUEUE_SERIAL);
        _activeClips = [NSMutableArray array];
    }
    return self;
}

#pragma mark Config and permission

+ (BOOL)isFeatureEnabled {
    NSString *value = configString("lipdata.capture_video").lowercaseString;
    return [value isEqualToString:@"true"] || [value isEqualToString:@"1"] ||
           [value isEqualToString:@"yes"] || [value isEqualToString:@"on"];
}

+ (NSString *)dataDirectory {
    NSString *configured = [configString("lipdata.dir") stringByExpandingTildeInPath];
    if (configured.length > 0 && configured.isAbsolutePath) return configured.stringByStandardizingPath;
    if (configured.length > 0) {
        NSLog(@"[VelikiyMoguchiy] lipdata.dir must be an absolute path (got \"%@\"); using the default", configured);
    }
    return SPLipDataDefaultDirectory();
}

+ (AVAuthorizationStatus)authorizationStatus {
    return [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
}

+ (void)requestAccessIfNeeded:(void (^)(AVAuthorizationStatus))completion {
    AVAuthorizationStatus status = [self authorizationStatus];
    if (status != AVAuthorizationStatusNotDetermined) {
        if (completion) completion(status);
        return;
    }
    NSLog(@"[VelikiyMoguchiy] lipdata: requesting camera access (first use)");
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSLog(@"[VelikiyMoguchiy] lipdata: camera access %@", granted ? @"granted" : @"denied");
            if (completion) completion([self authorizationStatus]);
        });
    }];
}

+ (void)cleanUpStaleTemporaryClips {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = temporaryDirectory();
    for (NSString *name in [fm contentsOfDirectoryAtPath:dir error:nil]) {
        [fm removeItemAtPath:[dir stringByAppendingPathComponent:name] error:nil];
    }
}

#pragma mark Starting a clip

- (SPLipClip *)beginPreCapture {
    if (![SPLipCaptureManager isFeatureEnabled]) return nil;
    return [self beginClip];
}

- (SPLipClip *)beginLipsClip {
    return [self beginClip];
}

- (SPLipClip *)beginClip {
    AVAuthorizationStatus status = [SPLipCaptureManager authorizationStatus];
    if (status != AVAuthorizationStatusAuthorized) {
        static dispatch_once_t logged;
        dispatch_once(&logged, ^{
            NSLog(@"[VelikiyMoguchiy] lipdata: camera access is not granted (status %ld); no video is recorded",
                  (long)status);
        });
        return nil;
    }

    SPLipClip *clip = [[SPLipClip alloc] init];
    clip.clipId = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
    clip.temporaryPath = [temporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:@"%lld.mp4", clip.clipId]];
    clip.beginTime = CMClockGetTime(CMClockGetHostTimeClock());
    clip.state = SPLipClipStateWaiting;

    dispatch_async(_queue, ^{
        [self->_activeClips addObject:clip];
    });
    dispatch_async(_sessionQueue, ^{
        if ([self startSessionLocked]) return;
        dispatch_async(self->_queue, ^{
            // Nothing will arrive: the clips armed so far can only be thrown away.
            for (SPLipClip *armed in self->_activeClips) armed.broken = YES;
        });
    });
    return clip;
}

/// On _sessionQueue. Returns NO (after logging why) when no video can be recorded.
- (BOOL)startSessionLocked {
    if (_session.isRunning) return YES;
    if (!_session && ![self configureSessionLocked]) return NO;
    if (_device.isInUseByAnotherApplication) {
        NSLog(@"[VelikiyMoguchiy] lipdata: the camera is in use by another app; this dictation gets no video");
        return NO;
    }
    [self applyFrameRateLocked];
    [_session startRunning];
    if (!_session.isRunning) {
        NSLog(@"[VelikiyMoguchiy] lipdata: the camera session did not start");
        return NO;
    }
    // A preset can reset the frame rate when the session starts; set it again.
    [self applyFrameRateLocked];
    CMTime minDuration = _device.activeVideoMinFrameDuration;
    CMTime maxDuration = _device.activeVideoMaxFrameDuration;
    NSLog(@"[VelikiyMoguchiy] lipdata: camera running (%@), frame duration %lld/%d..%lld/%d",
          _device.localizedName, minDuration.value, minDuration.timescale,
          maxDuration.value, maxDuration.timescale);
    return YES;
}

/// On _sessionQueue. Builds the session once; it is then kept for the process lifetime.
- (BOOL)configureSessionLocked {
    AVCaptureDeviceDiscoverySession *discovery = [AVCaptureDeviceDiscoverySession
        discoverySessionWithDeviceTypes:@[ AVCaptureDeviceTypeBuiltInWideAngleCamera ]
                              mediaType:AVMediaTypeVideo
                               position:AVCaptureDevicePositionUnspecified];
    AVCaptureDevice *device = discovery.devices.firstObject;
    if (!device) {
        NSLog(@"[VelikiyMoguchiy] lipdata: no built-in camera found");
        return NO;
    }
    NSError *error = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    if (!input) {
        NSLog(@"[VelikiyMoguchiy] lipdata: cannot open the camera: %@", error);
        return NO;
    }

    AVCaptureSession *session = [[AVCaptureSession alloc] init];
    [session beginConfiguration];
    if (![session canAddInput:input]) {
        [session commitConfiguration];
        NSLog(@"[VelikiyMoguchiy] lipdata: the camera input cannot be added");
        return NO;
    }
    [session addInput:input];
    // Ask the camera for a 1280x720 format directly (no scaling in the writer);
    // when it has none, fall back to the 720p preset, else to the preset's default.
    if (![self selectFormatWithWidth:SPLipDataOutputWidth height:SPLipDataOutputHeight onDevice:device]) {
        if ([session canSetSessionPreset:AVCaptureSessionPreset1280x720]) {
            session.sessionPreset = AVCaptureSessionPreset1280x720;
        } else if ([session canSetSessionPreset:AVCaptureSessionPreset640x480]) {
            session.sessionPreset = AVCaptureSessionPreset640x480;
        }
    }

    AVCaptureVideoDataOutput *output = [[AVCaptureVideoDataOutput alloc] init];
    output.alwaysDiscardsLateVideoFrames = YES;
    NSNumber *nativeFormat = @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    if ([output.availableVideoCVPixelFormatTypes containsObject:nativeFormat]) {
        output.videoSettings = @{(NSString *)kCVPixelBufferPixelFormatTypeKey : nativeFormat};
    }
    [output setSampleBufferDelegate:self queue:_queue];
    if (![session canAddOutput:output]) {
        [session commitConfiguration];
        NSLog(@"[VelikiyMoguchiy] lipdata: the video output cannot be added");
        return NO;
    }
    [session addOutput:output];
    [session commitConfiguration];

    _device = device;
    _session = session;
    if (!_observersInstalled) {
        _observersInstalled = YES;
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        __weak typeof(self) weakSelf = self;
        for (NSNotificationName name in @[ AVCaptureSessionWasInterruptedNotification,
                                           AVCaptureSessionRuntimeErrorNotification ]) {
            [center addObserverForName:name object:session queue:nil usingBlock:^(NSNotification *note) {
                [weakSelf cameraWasInterrupted:note];
            }];
        }
    }
    return YES;
}

/// On _sessionQueue. Makes a width x height format with a 25 fps mode (and the
/// camera's native 4:2:0 pixel format) the device's activeFormat; NO when there
/// is none or it cannot be set.
- (BOOL)selectFormatWithWidth:(NSInteger)width height:(NSInteger)height onDevice:(AVCaptureDevice *)device {
    AVCaptureDeviceFormat *best = nil;
    for (AVCaptureDeviceFormat *format in device.formats) {
        CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
        if (dims.width != width || dims.height != height) continue;
        BOOL fps = NO;
        for (AVFrameRateRange *range in format.videoSupportedFrameRateRanges) {
            if (range.minFrameRate <= SPLipCaptureFPS && range.maxFrameRate >= SPLipCaptureFPS) fps = YES;
        }
        if (!fps) continue;
        FourCharCode subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription);
        if (!best || subtype == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) best = format;
    }
    if (!best) {
        NSLog(@"[VelikiyMoguchiy] lipdata: the camera has no %ldx%ld format; the writer will scale", (long)width, (long)height);
        return NO;
    }
    NSError *error = nil;
    if (![device lockForConfiguration:&error]) {
        NSLog(@"[VelikiyMoguchiy] lipdata: cannot lock the camera to pick a format: %@", error);
        return NO;
    }
    device.activeFormat = best;
    [device unlockForConfiguration];
    NSLog(@"[VelikiyMoguchiy] lipdata: camera format %ldx%ld selected", (long)width, (long)height);
    return YES;
}

/// On _sessionQueue. Pins the device to 25 fps (when its format allows it).
- (void)applyFrameRateLocked {
    AVCaptureDevice *device = _device;
    if (!device) return;
    BOOL supported = NO;
    for (AVFrameRateRange *range in device.activeFormat.videoSupportedFrameRateRanges) {
        if (range.minFrameRate <= SPLipCaptureFPS && range.maxFrameRate >= SPLipCaptureFPS) supported = YES;
    }
    if (!supported) {
        NSLog(@"[VelikiyMoguchiy] lipdata: the camera format has no %ld fps mode; frames are resampled to it", (long)SPLipCaptureFPS);
        return;
    }
    NSError *error = nil;
    if (![device lockForConfiguration:&error]) {
        NSLog(@"[VelikiyMoguchiy] lipdata: cannot lock the camera to set the frame rate: %@", error);
        return;
    }
    CMTime frameDuration = CMTimeMake(1, (int32_t)SPLipCaptureFPS);
    device.activeVideoMinFrameDuration = frameDuration;
    device.activeVideoMaxFrameDuration = frameDuration;
    [device unlockForConfiguration];
}

- (void)cameraWasInterrupted:(NSNotification *)note {
    NSLog(@"[VelikiyMoguchiy] lipdata: camera session %@ (%@); the current clips are dropped", note.name, note.userInfo);
    dispatch_async(_queue, ^{
        for (SPLipClip *clip in self->_activeClips) clip.broken = YES;
    });
}

#pragma mark Frames

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    CVImageBufferRef pixels = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixels) return;
    [self handlePixels:pixels pts:CMSampleBufferGetPresentationTimeStamp(sampleBuffer)];
}

/// On _queue.
- (void)handlePixels:(CVImageBufferRef)pixels pts:(CMTime)pts {
    if (_activeClips.count == 0) return;
    for (SPLipClip *clip in [_activeClips copy]) {
        // Frames captured before the trigger went down are not part of the clip.
        if (CMTimeCompare(pts, clip.beginTime) < 0) continue;
        if (clip.state == SPLipClipStateWaiting && ![self startWriterForClip:clip pixels:pixels pts:pts]) continue;
        if (clip.state == SPLipClipStateRecording) [self appendPixels:pixels pts:pts toClip:clip];
    }
}

/// On _queue.
- (BOOL)startWriterForClip:(SPLipClip *)clip pixels:(CVImageBufferRef)pixels pts:(CMTime)pts {
    NSInteger width = (NSInteger)CVPixelBufferGetWidth(pixels);
    NSInteger height = (NSInteger)CVPixelBufferGetHeight(pixels);
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *error = nil;
    [fm createDirectoryAtPath:temporaryDirectory()
  withIntermediateDirectories:YES
                   attributes:@{NSFilePosixPermissions : @(0700)}
                        error:&error];
    [fm removeItemAtPath:clip.temporaryPath error:nil];
    AVAssetWriter *writer = error ? nil : [AVAssetWriter assetWriterWithURL:[NSURL fileURLWithPath:clip.temporaryPath]
                                                                   fileType:AVFileTypeMPEG4
                                                                      error:&error];
    if (!writer) {
        NSLog(@"[VelikiyMoguchiy] lipdata: cannot create the video file: %@", error);
        clip.broken = YES;
        clip.state = SPLipClipStateDone;
        [self->_activeClips removeObject:clip];
        dispatch_group_leave(clip.finalized);
        [self stopSessionWhenIdle];
        return NO;
    }

    // The writer scales whatever the camera delivers into 1280x720, aspect kept.
    NSDictionary *settings = [SPLipDataPolicy videoOutputSettingsWithFPS:SPLipCaptureFPS];
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                                   outputSettings:settings];
    input.expectsMediaDataInRealTime = YES;
    NSDictionary *pixelAttributes = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey : @(CVPixelBufferGetPixelFormatType(pixels)),
        (NSString *)kCVPixelBufferWidthKey : @(width),
        (NSString *)kCVPixelBufferHeightKey : @(height),
    };
    AVAssetWriterInputPixelBufferAdaptor *adaptor =
        [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input
                                                                         sourcePixelBufferAttributes:pixelAttributes];
    if (![writer canAddInput:input]) {
        NSLog(@"[VelikiyMoguchiy] lipdata: the video input was refused by the writer");
        clip.broken = YES;
        clip.state = SPLipClipStateDone;
        [self->_activeClips removeObject:clip];
        dispatch_group_leave(clip.finalized);
        [self stopSessionWhenIdle];
        return NO;
    }
    [writer addInput:input];
    if (![writer startWriting]) {
        NSLog(@"[VelikiyMoguchiy] lipdata: cannot start writing the video: %@", writer.error);
        clip.broken = YES;
        clip.state = SPLipClipStateDone;
        [self->_activeClips removeObject:clip];
        dispatch_group_leave(clip.finalized);
        [self stopSessionWhenIdle];
        return NO;
    }
    [writer startSessionAtSourceTime:kCMTimeZero];
    chmod(clip.temporaryPath.UTF8String, 0600);

    clip.writer = writer;
    clip.writerInput = input;
    clip.adaptor = adaptor;
    clip.captureWidth = width;
    clip.captureHeight = height;
    clip.width = SPLipDataOutputWidth;
    clip.height = SPLipDataOutputHeight;
    NSLog(@"[VelikiyMoguchiy] lipdata: capture %ldx%ld, writing %ldx%ld", (long)width, (long)height,
          (long)SPLipDataOutputWidth, (long)SPLipDataOutputHeight);
    clip.firstPts = pts;
    clip.nextSlot = 0;
    clip.firstFrameLagMs = (NSInteger)llround(CMTimeGetSeconds(CMTimeSubtract(pts, clip.beginTime)) * 1000.0);
    clip.state = SPLipClipStateRecording;
    return YES;
}

/// On _queue. Frames land on an exact 25 fps grid whatever the camera delivers.
- (void)appendPixels:(CVImageBufferRef)pixels pts:(CMTime)pts toClip:(SPLipClip *)clip {
    double elapsed = CMTimeGetSeconds(CMTimeSubtract(pts, clip.firstPts));
    int64_t slot = (int64_t)llround(elapsed * SPLipCaptureFPS);
    if (slot < clip.nextSlot) return;  // the camera is faster than 25 fps: this slot is taken
    if (!clip.writerInput.readyForMoreMediaData) {
        clip.droppedFrames += 1;
        return;
    }
    int64_t missed = slot - clip.nextSlot;
    if (missed > 0) clip.droppedFrames += missed;
    if (missed > kMaxGapSlots) clip.broken = YES;
    if (![clip.adaptor appendPixelBuffer:pixels withPresentationTime:CMTimeMake(slot, (int32_t)SPLipCaptureFPS)]) {
        NSLog(@"[VelikiyMoguchiy] lipdata: appending a frame failed: %@", clip.writer.error);
        clip.broken = YES;
        return;
    }
    clip.nextSlot = slot + 1;
}

#pragma mark Finishing a clip

- (void)endClip:(SPLipClip *)clip {
    if (!clip) return;
    dispatch_async(_queue, ^{
        if (clip.state == SPLipClipStateFinishing || clip.state == SPLipClipStateDone) return;
        [self->_activeClips removeObject:clip];
        [self stopSessionWhenIdle];

        if (clip.state == SPLipClipStateWaiting) {
            // The camera never delivered a frame.
            clip.broken = YES;
            clip.state = SPLipClipStateDone;
            dispatch_group_leave(clip.finalized);
            return;
        }
        clip.state = SPLipClipStateFinishing;
        if (clip.discardRequested) {
            [clip.writer cancelWriting];
            [[NSFileManager defaultManager] removeItemAtPath:clip.temporaryPath error:nil];
            clip.state = SPLipClipStateDone;
            clip.broken = YES;
            dispatch_group_leave(clip.finalized);
            return;
        }
        [clip.writerInput markAsFinished];
        [clip.writer endSessionAtSourceTime:CMTimeMake(clip.nextSlot, (int32_t)SPLipCaptureFPS)];
        [clip.writer finishWritingWithCompletionHandler:^{
            dispatch_async(self->_queue, ^{
                clip.durationSec = (double)clip.nextSlot / SPLipCaptureFPS;
                if (clip.writer.status != AVAssetWriterStatusCompleted) {
                    NSLog(@"[VelikiyMoguchiy] lipdata: the video file was not finalized: %@", clip.writer.error);
                    clip.broken = YES;
                }
                clip.usable = !clip.broken && clip.nextSlot > 0;
                clip.state = SPLipClipStateDone;
                clip.writer = nil;
                clip.writerInput = nil;
                clip.adaptor = nil;
                dispatch_group_leave(clip.finalized);
                // A dictation can end without ever reporting a result (a silent
                // recording): do not keep its video around.
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kStaleClipSeconds * NSEC_PER_SEC)),
                               self->_workQueue, ^{
                    if (!clip.settled) {
                        [[NSFileManager defaultManager] removeItemAtPath:clip.temporaryPath error:nil];
                    }
                });
            });
        }];
    });
}

- (void)discardClip:(SPLipClip *)clip {
    if (!clip) return;
    clip.settled = YES;
    dispatch_async(_queue, ^{
        clip.discardRequested = YES;
    });
    [self endClip:clip];
    // A clip that already finished (or is finishing) is removed once it is done.
    dispatch_group_notify(clip.finalized, _workQueue, ^{
        [[NSFileManager defaultManager] removeItemAtPath:clip.temporaryPath error:nil];
    });
}

/// Stops the camera (and its green light) once no clip is being recorded.
/// Callable from any queue.
- (void)stopSessionWhenIdle {
    dispatch_async(_sessionQueue, ^{
        if (!self->_session.isRunning) return;
        __block NSUInteger remaining = 0;
        dispatch_sync(self->_queue, ^{
            remaining = self->_activeClips.count;
        });
        if (remaining > 0) return;
        [self->_session stopRunning];
        NSLog(@"[VelikiyMoguchiy] lipdata: camera stopped");
    });
}

- (void)shutdown {
    __block NSArray<SPLipClip *> *clips = nil;
    dispatch_sync(_queue, ^{
        clips = [self->_activeClips copy];
    });
    for (SPLipClip *clip in clips) [self discardClip:clip];
    dispatch_sync(_sessionQueue, ^{
        if (self->_session.isRunning) [self->_session stopRunning];
    });
}

#pragma mark Saving

- (void)resolveClip:(SPLipClip *)clip
            dictate:(BOOL)isDictate
             status:(NSString *)status
          finalText:(NSString *)finalText
     recognizedText:(NSString *)recognizedText
        appBundleId:(NSString *)appBundleId
         outputMode:(NSString *)outputMode
         completion:(void (^)(SPLipClipVerdict, NSString *))completion {
    if (!clip) {
        if (completion) completion(SPLipClipVerdictDiscard, nil);
        return;
    }
    clip.settled = YES;
    [self endClip:clip];
    NSString *label = [SPLipDataPolicy sidecarTextFromRecognizedText:recognizedText];
    dispatch_group_notify(clip.finalized, _workQueue, ^{
        SPLipClipVerdict verdict = [SPLipDataPolicy verdictForDictate:isDictate
                                                               status:status
                                                            finalText:finalText
                                                            labelText:label
                                                          durationSec:clip.durationSec
                                                           clipUsable:clip.usable];
        NSFileManager *fm = [NSFileManager defaultManager];
        if (verdict == SPLipClipVerdictDiscard) {
            [fm removeItemAtPath:clip.temporaryPath error:nil];
            NSLog(@"[VelikiyMoguchiy] lipdata: clip %lld discarded (status=%@ dictate=%d duration=%.2fs usable=%d)",
                  clip.clipId, status, isDictate, clip.durationSec, clip.usable);
            if (completion) completion(verdict, nil);
            return;
        }
        NSString *base = [self saveClip:clip
                                  label:label
                                tooLong:verdict == SPLipClipVerdictKeepTooLong
                            appBundleId:appBundleId
                             outputMode:outputMode];
        if (!base) {
            [fm removeItemAtPath:clip.temporaryPath error:nil];
            if (completion) completion(SPLipClipVerdictDiscard, nil);
            return;
        }
        NSLog(@"[VelikiyMoguchiy] lipdata: saved %@.mp4 (%.2fs%@)", base, clip.durationSec,
              verdict == SPLipClipVerdictKeepTooLong ? @", too_long" : @"");
        if (completion) completion(verdict, base);
    });
}

/// On _workQueue. Writes .txt and .json first and moves the .mp4 last, so a
/// video in the directory always has its label next to it. Returns the saved
/// path without extension, nil on failure.
- (NSString *)saveClip:(SPLipClip *)clip
                 label:(NSString *)label
               tooLong:(BOOL)tooLong
           appBundleId:(NSString *)appBundleId
            outputMode:(NSString *)outputMode {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [SPLipCaptureManager dataDirectory];
    NSError *error = nil;
    if (![fm createDirectoryAtPath:dir
       withIntermediateDirectories:YES
                        attributes:@{NSFilePosixPermissions : @(0700)}
                             error:&error]) {
        NSLog(@"[VelikiyMoguchiy] lipdata: cannot create %@: %@", dir, error);
        return nil;
    }

    long long clipId = clip.clipId;
    NSString *base = nil;
    for (int attempt = 0; attempt < 1000; attempt++) {
        NSString *candidate = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%lld", clipId]];
        BOOL taken = NO;
        for (NSString *ext in @[ @"mp4", @"txt", @"json" ]) {
            if ([fm fileExistsAtPath:[candidate stringByAppendingPathExtension:ext]]) taken = YES;
        }
        if (!taken) {
            base = candidate;
            break;
        }
        clipId += 1;
    }
    if (!base) return nil;

    NSDictionary *meta = [SPLipDataPolicy sidecarMetadataWithClipId:clipId
                                                        durationSec:clip.durationSec
                                                                fps:SPLipCaptureFPS
                                                              width:clip.width
                                                             height:clip.height
                                                       captureWidth:clip.captureWidth
                                                      captureHeight:clip.captureHeight
                                                        appBundleId:appBundleId
                                                         outputMode:outputMode
                                                            tooLong:tooLong
                                                    firstFrameLagMs:clip.firstFrameLagMs
                                                      droppedFrames:clip.droppedFrames];
    NSData *json = [NSJSONSerialization dataWithJSONObject:meta
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:&error];
    NSData *text = [[label stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    NSString *txtPath = [base stringByAppendingPathExtension:@"txt"];
    NSString *jsonPath = [base stringByAppendingPathExtension:@"json"];
    NSString *mp4Path = [base stringByAppendingPathExtension:@"mp4"];
    if (!json || ![text writeToFile:txtPath options:NSDataWritingAtomic error:&error] ||
        ![json writeToFile:jsonPath options:NSDataWritingAtomic error:&error]) {
        NSLog(@"[VelikiyMoguchiy] lipdata: cannot write the sidecar files for %@: %@", base, error);
        [fm removeItemAtPath:txtPath error:nil];
        [fm removeItemAtPath:jsonPath error:nil];
        return nil;
    }
    chmod(txtPath.UTF8String, 0600);
    chmod(jsonPath.UTF8String, 0600);
    if (![fm moveItemAtPath:clip.temporaryPath toPath:mp4Path error:&error]) {
        NSLog(@"[VelikiyMoguchiy] lipdata: cannot move the video to %@: %@", mp4Path, error);
        [fm removeItemAtPath:txtPath error:nil];
        [fm removeItemAtPath:jsonPath error:nil];
        return nil;
    }
    return base;
}

@end
