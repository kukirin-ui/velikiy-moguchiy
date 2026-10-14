#import "SPLipDataPolicy.h"
#import "SPAppPaths.h"

NSString *SPLipDataDefaultDirectory(void) {
    return SPAppDataPath(@"lipdata/voiced");
}

const double SPLipDataMinDurationSec = 1.0;
const double SPLipDataMaxGoodDurationSec = 20.0;
const NSInteger SPLipDataOutputWidth = 1280;
const NSInteger SPLipDataOutputHeight = 720;
const NSInteger SPLipDataAverageBitRate = 1500000;

@implementation SPLipDataPolicy

+ (SPLipClipVerdict)verdictForDictate:(BOOL)isDictate
                               status:(NSString *)status
                            finalText:(NSString *)finalText
                            labelText:(NSString *)labelText
                          durationSec:(double)durationSec
                           clipUsable:(BOOL)clipUsable {
    if (!isDictate || !clipUsable) return SPLipClipVerdictDiscard;
    if (![status isEqualToString:@"ok"]) return SPLipClipVerdictDiscard;
    NSCharacterSet *blank = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    if ([finalText stringByTrimmingCharactersInSet:blank].length == 0) return SPLipClipVerdictDiscard;
    if ([labelText stringByTrimmingCharactersInSet:blank].length == 0) return SPLipClipVerdictDiscard;
    if (!(durationSec >= SPLipDataMinDurationSec)) return SPLipClipVerdictDiscard;
    return durationSec > SPLipDataMaxGoodDurationSec ? SPLipClipVerdictKeepTooLong : SPLipClipVerdictKeep;
}

+ (NSString *)sidecarTextFromRecognizedText:(NSString *)recognized {
    if (recognized.length == 0) return nil;
    // ⟦новая строка⟧ -> новая строка: the words were spoken, only the markers are not.
    NSString *text = [recognized stringByReplacingOccurrencesOfString:@"⟦" withString:@" "];
    text = [text stringByReplacingOccurrencesOfString:@"⟧" withString:@" "];
    NSArray<NSString *> *words = [text componentsSeparatedByCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableArray<NSString *> *kept = [NSMutableArray array];
    for (NSString *word in words) {
        if (word.length > 0) [kept addObject:word];
    }
    NSString *joined = [kept componentsJoinedByString:@" "];
    return joined.length > 0 ? joined : nil;
}

+ (NSDictionary<NSString *, id> *)videoOutputSettingsWithFPS:(NSInteger)fps {
    return @{
        AVVideoCodecKey : AVVideoCodecTypeH264,
        AVVideoWidthKey : @(SPLipDataOutputWidth),
        AVVideoHeightKey : @(SPLipDataOutputHeight),
        // The whole camera frame fits into the output frame; no cropping.
        AVVideoScalingModeKey : AVVideoScalingModeResizeAspect,
        AVVideoCompressionPropertiesKey : @{
            AVVideoAverageBitRateKey : @(SPLipDataAverageBitRate),
            AVVideoExpectedSourceFrameRateKey : @(fps),
            AVVideoMaxKeyFrameIntervalKey : @(fps),
            AVVideoProfileLevelKey : AVVideoProfileLevelH264MainAutoLevel,
            AVVideoAllowFrameReorderingKey : @NO,
        },
    };
}

+ (NSDictionary<NSString *, id> *)sidecarMetadataWithClipId:(long long)clipId
                                                 durationSec:(double)durationSec
                                                         fps:(NSInteger)fps
                                                       width:(NSInteger)width
                                                      height:(NSInteger)height
                                                captureWidth:(NSInteger)captureWidth
                                               captureHeight:(NSInteger)captureHeight
                                                 appBundleId:(NSString *)appBundleId
                                                  outputMode:(NSString *)outputMode
                                                    tooLong:(BOOL)tooLong
                                            firstFrameLagMs:(NSInteger)firstFrameLagMs
                                              droppedFrames:(NSInteger)droppedFrames {
    NSISO8601DateFormatter *iso = [[NSISO8601DateFormatter alloc] init];
    iso.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    NSDate *created = [NSDate dateWithTimeIntervalSince1970:clipId / 1000.0];
    return @{
        @"id" : @(clipId),
        @"created" : [iso stringFromDate:created],
        @"duration_s" : @(round(durationSec * 1000.0) / 1000.0),
        @"fps" : @(fps),
        @"width" : @(width),
        @"height" : @(height),
        @"output_width" : @(width),
        @"output_height" : @(height),
        @"capture_width" : @(captureWidth),
        @"capture_height" : @(captureHeight),
        @"codec" : @"h264",
        @"audio" : @NO,
        @"app_bundle_id" : appBundleId ?: @"",
        @"output_mode" : outputMode ?: @"",
        @"too_long" : @(tooLong),
        @"text_source" : @"asr",
        @"first_frame_lag_ms" : @(firstFrameLagMs),
        @"dropped_frames" : @(droppedFrames),
    };
}

+ (SPLipDataStats)statsForDirectory:(NSString *)dir {
    SPLipDataStats stats = {0, 0};
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *name in [fm contentsOfDirectoryAtPath:dir error:nil]) {
        if (![name.pathExtension isEqualToString:@"json"] || [name hasPrefix:@"."]) continue;
        NSString *base = name.stringByDeletingPathExtension;
        if (![fm fileExistsAtPath:[dir stringByAppendingPathComponent:[base stringByAppendingPathExtension:@"mp4"]]]) {
            continue;
        }
        NSData *data = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:name]];
        id object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![object isKindOfClass:[NSDictionary class]]) continue;
        id duration = ((NSDictionary *)object)[@"duration_s"];
        if (![duration isKindOfClass:[NSNumber class]]) continue;
        stats.clipCount += 1;
        stats.totalSeconds += [duration doubleValue];
    }
    return stats;
}

+ (NSString *)pluralForm:(NSInteger)n forms:(NSArray<NSString *> *)forms {
    NSInteger abs10 = labs(n) % 10;
    NSInteger abs100 = labs(n) % 100;
    if (abs10 == 1 && abs100 != 11) return forms[0];
    if (abs10 >= 2 && abs10 <= 4 && (abs100 < 12 || abs100 > 14)) return forms[1];
    return forms[2];
}

+ (NSString *)counterSummaryForStats:(SPLipDataStats)stats {
    NSString *clips = [NSString stringWithFormat:@"%ld %@", (long)stats.clipCount,
                       [self pluralForm:stats.clipCount forms:@[ @"клип", @"клипа", @"клипов" ]]];
    double minutes = stats.totalSeconds / 60.0;
    NSString *minutesText;
    if (minutes >= 10.0 || minutes == 0.0) {
        NSInteger whole = (NSInteger)llround(minutes);
        minutesText = [NSString stringWithFormat:@"%ld %@", (long)whole,
                       [self pluralForm:whole forms:@[ @"минута", @"минуты", @"минут" ]]];
    } else {
        NSString *number = [[NSString stringWithFormat:@"%.1f", minutes]
            stringByReplacingOccurrencesOfString:@"." withString:@","];
        minutesText = [number stringByAppendingString:@" минуты"];
    }
    return [NSString stringWithFormat:@"Собрано: %@, %@", clips, minutesText];
}

@end
