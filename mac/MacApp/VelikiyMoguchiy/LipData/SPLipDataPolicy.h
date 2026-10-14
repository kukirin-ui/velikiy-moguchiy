#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Default for `lipdata.dir`: lipdata/voiced inside the app's data directory.
NSString *SPLipDataDefaultDirectory(void);

/// Clips shorter than this are dropped; longer than SPLipDataMaxGoodDurationSec
/// are kept but flagged `too_long` in the sidecar.
extern const double SPLipDataMinDurationSec;
extern const double SPLipDataMaxGoodDurationSec;

/// Resolution, bitrate and keyframe interval of the recorded MP4. The camera is
/// asked for the same 1280x720 format; whatever it really delivers is scaled
/// into this frame with its aspect ratio kept (no cropping).
extern const NSInteger SPLipDataOutputWidth;
extern const NSInteger SPLipDataOutputHeight;
extern const NSInteger SPLipDataAverageBitRate;

typedef NS_ENUM(NSInteger, SPLipClipVerdict) {
    SPLipClipVerdictDiscard = 0,
    SPLipClipVerdictKeep,
    /// Kept, but longer than SPLipDataMaxGoodDurationSec (`too_long` in the sidecar).
    SPLipClipVerdictKeepTooLong,
};

typedef struct {
    NSInteger clipCount;
    double totalSeconds;
} SPLipDataStats;

/// Pure rules for the lip-reading dataset (no AVFoundation, no config access),
/// so they can be unit-tested.
@interface SPLipDataPolicy : NSObject

/// Whether a finished camera clip is worth keeping.
/// - `isDictate`: only the Dictate purpose (not translate / ask);
/// - `status`: the history status, only "ok" counts;
/// - `finalText`: the delivered text must be non-empty;
/// - `labelText`: the prepared sidecar text must be non-empty;
/// - `clipUsable`: the camera delivered an uninterrupted recording.
+ (SPLipClipVerdict)verdictForDictate:(BOOL)isDictate
                               status:(nullable NSString *)status
                            finalText:(nullable NSString *)finalText
                            labelText:(nullable NSString *)labelText
                          durationSec:(double)durationSec
                           clipUsable:(BOOL)clipUsable;

/// The label for a clip: the recognized text as spoken, taken from the ASR
/// transcript BEFORE the LLM correction and snippet replacement (snippet text
/// is not spoken words, so the delivered text is never used). Command markers
/// ⟦…⟧ are unwrapped to the words that were actually said; line breaks and
/// repeated spaces collapse into single spaces. nil when nothing is left.
+ (nullable NSString *)sidecarTextFromRecognizedText:(nullable NSString *)recognized;

/// AVAssetWriterInput output settings of a clip: H.264, 1280x720, ~1.5 Mbit/s,
/// one keyframe per second (every `fps` frames), full frame kept (resizeAspect).
+ (NSDictionary<NSString *, id> *)videoOutputSettingsWithFPS:(NSInteger)fps;

/// Contents of `<unix-ms>.json`. `width` / `height` are the MP4's real size,
/// `captureWidth` / `captureHeight` what the camera delivered.
+ (NSDictionary<NSString *, id> *)sidecarMetadataWithClipId:(long long)clipId
                                                 durationSec:(double)durationSec
                                                         fps:(NSInteger)fps
                                                       width:(NSInteger)width
                                                      height:(NSInteger)height
                                                captureWidth:(NSInteger)captureWidth
                                               captureHeight:(NSInteger)captureHeight
                                                 appBundleId:(nullable NSString *)appBundleId
                                                  outputMode:(nullable NSString *)outputMode
                                                    tooLong:(BOOL)tooLong
                                            firstFrameLagMs:(NSInteger)firstFrameLagMs
                                              droppedFrames:(NSInteger)droppedFrames;

/// Counts finished clips (`*.json` sidecars with a matching `*.mp4`) in `dir`.
+ (SPLipDataStats)statsForDirectory:(NSString *)dir;

/// "Собрано: 3 клипа, 1,5 минуты".
+ (NSString *)counterSummaryForStats:(SPLipDataStats)stats;

/// Russian plural form: forms = @[one, few, many] (клип, клипа, клипов).
+ (NSString *)pluralForm:(NSInteger)n forms:(NSArray<NSString *> *)forms;

@end

NS_ASSUME_NONNULL_END
