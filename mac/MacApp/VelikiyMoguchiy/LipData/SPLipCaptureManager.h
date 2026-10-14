#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import "SPLipDataPolicy.h"

NS_ASSUME_NONNULL_BEGIN

/// Frame rate of every recorded clip.
extern const NSInteger SPLipCaptureFPS;

/// One camera recording that accompanies one dictation. Created by
/// -[SPLipCaptureManager beginPreCapture]; owned by the caller until it is
/// handed back through endClip: / discardClip: / resolveClip:.
@interface SPLipClip : NSObject

/// Unix milliseconds of the trigger-down; the base name of the saved files.
@property (nonatomic, readonly) long long clipId;
/// Where the MP4 is written while the dictation is in flight.
@property (nonatomic, readonly, copy) NSString *temporaryPath;
/// Seconds of video, valid once the clip is finalized.
@property (nonatomic, readonly) double durationSec;
@property (nonatomic, readonly) NSInteger width;
@property (nonatomic, readonly) NSInteger height;

/// Blocks until the file is finalized (or the clip failed). For tests / smoke runs.
- (BOOL)waitUntilFinalizedWithTimeout:(NSTimeInterval)seconds;
/// YES when the camera delivered an uninterrupted recording. Valid once finalized.
@property (nonatomic, readonly) BOOL usable;

@end

/// Optional camera recording during dictation, for collecting lip-reading
/// training data (opt-in: `lipdata.capture_video`). With the feature off the
/// camera is never touched. The AVCaptureSession object is kept between
/// dictations but only runs while a clip is being recorded, so the camera's
/// green light is off when idle. Nothing leaves the Mac.
@interface SPLipCaptureManager : NSObject

+ (instancetype)sharedManager;

/// `lipdata.capture_video`.
+ (BOOL)isFeatureEnabled;
/// `lipdata.dir`, with a default; always an absolute path.
+ (NSString *)dataDirectory;

+ (AVAuthorizationStatus)authorizationStatus;
/// Shows the system camera prompt when (and only when) the status is
/// notDetermined; otherwise reports the current status right away. Meant for
/// the moment the user turns the switch on, never for mid-dictation.
+ (void)requestAccessIfNeeded:(nullable void (^)(AVAuthorizationStatus status))completion;

/// Removes temporary clips left by a crashed run.
+ (void)cleanUpStaleTemporaryClips;

/// Trigger-down: starts the camera session (if needed) and a clip. Returns nil
/// when the feature is off, access is missing, there is no built-in camera or
/// another app is using it (then nothing is recorded and a line is logged).
- (nullable SPLipClip *)beginPreCapture;

/// Same as beginPreCapture without the `lipdata.capture_video` opt-in: the
/// lips mode (experimental.lips) needs the video to read it. The caller ends
/// it with endClip: and deletes it with discardClip:; it is never saved.
- (nullable SPLipClip *)beginLipsClip;

/// Stops recording the clip and finalizes the file in the background (audio
/// capture stopped). Safe to call repeatedly or with nil.
- (void)endClip:(nullable SPLipClip *)clip;

/// Stops the clip and deletes its file.
- (void)discardClip:(nullable SPLipClip *)clip;

/// The dictation has a result: ends the clip, applies the keep/discard rules
/// and, when kept, saves <unix-ms>.mp4/.txt/.json into the data directory.
/// `recognizedText` is the ASR transcript before LLM correction and snippets.
/// The completion runs on a background queue; `savedBasePath` is the path
/// without extension of the saved files (nil when discarded).
- (void)resolveClip:(nullable SPLipClip *)clip
            dictate:(BOOL)isDictate
             status:(nullable NSString *)status
          finalText:(nullable NSString *)finalText
     recognizedText:(nullable NSString *)recognizedText
        appBundleId:(nullable NSString *)appBundleId
         outputMode:(nullable NSString *)outputMode
         completion:(nullable void (^)(SPLipClipVerdict verdict, NSString *_Nullable savedBasePath))completion;

/// Discards every clip in flight and stops the camera (app quitting).
- (void)shutdown;

@end

NS_ASSUME_NONNULL_END
