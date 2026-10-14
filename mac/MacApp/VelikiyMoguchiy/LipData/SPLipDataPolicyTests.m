#import <XCTest/XCTest.h>
#import "SPLipDataPolicy.h"

@interface SPLipDataPolicyTests : XCTestCase
@end

@implementation SPLipDataPolicyTests

- (SPLipClipVerdict)verdictDictate:(BOOL)dictate
                            status:(NSString *)status
                              text:(NSString *)text
                             label:(NSString *)label
                          duration:(double)duration
                            usable:(BOOL)usable {
    return [SPLipDataPolicy verdictForDictate:dictate
                                       status:status
                                    finalText:text
                                    labelText:label
                                  durationSec:duration
                                   clipUsable:usable];
}

- (void)testKeepsOrdinaryDictation {
    XCTAssertEqual([self verdictDictate:YES status:@"ok" text:@"привет" label:@"привет" duration:3.4 usable:YES],
                   SPLipClipVerdictKeep);
}

- (void)testOnlyDictatePurposeIsKept {
    XCTAssertEqual([self verdictDictate:NO status:@"ok" text:@"hello" label:@"hello" duration:3 usable:YES],
                   SPLipClipVerdictDiscard);
}

- (void)testOnlyOkStatusIsKept {
    for (NSString *status in @[ @"cancelled", @"error", @"empty", @"" ]) {
        XCTAssertEqual([self verdictDictate:YES status:status text:@"привет" label:@"привет" duration:3 usable:YES],
                       SPLipClipVerdictDiscard, @"%@", status);
    }
    XCTAssertEqual([self verdictDictate:YES status:nil text:@"привет" label:@"привет" duration:3 usable:YES],
                   SPLipClipVerdictDiscard);
}

- (void)testEmptyTextIsDiscarded {
    XCTAssertEqual([self verdictDictate:YES status:@"ok" text:@"" label:@"привет" duration:3 usable:YES],
                   SPLipClipVerdictDiscard);
    XCTAssertEqual([self verdictDictate:YES status:@"ok" text:@" \n" label:@"привет" duration:3 usable:YES],
                   SPLipClipVerdictDiscard);
    XCTAssertEqual([self verdictDictate:YES status:@"ok" text:nil label:@"привет" duration:3 usable:YES],
                   SPLipClipVerdictDiscard);
    XCTAssertEqual([self verdictDictate:YES status:@"ok" text:@"привет" label:nil duration:3 usable:YES],
                   SPLipClipVerdictDiscard);
}

- (void)testDurationBounds {
    XCTAssertEqual([self verdictDictate:YES status:@"ok" text:@"a" label:@"a" duration:0.96 usable:YES],
                   SPLipClipVerdictDiscard);
    XCTAssertEqual([self verdictDictate:YES status:@"ok" text:@"a" label:@"a" duration:1.0 usable:YES],
                   SPLipClipVerdictKeep);
    XCTAssertEqual([self verdictDictate:YES status:@"ok" text:@"a" label:@"a" duration:20.0 usable:YES],
                   SPLipClipVerdictKeep);
    XCTAssertEqual([self verdictDictate:YES status:@"ok" text:@"a" label:@"a" duration:20.04 usable:YES],
                   SPLipClipVerdictKeepTooLong);
    XCTAssertEqual([self verdictDictate:YES status:@"ok" text:@"a" label:@"a" duration:95 usable:YES],
                   SPLipClipVerdictKeepTooLong);
    XCTAssertEqual([self verdictDictate:YES status:@"ok" text:@"a" label:@"a" duration:0 usable:YES],
                   SPLipClipVerdictDiscard);
    XCTAssertEqual([self verdictDictate:YES status:@"ok" text:@"a" label:@"a" duration:NAN usable:YES],
                   SPLipClipVerdictDiscard);
}

- (void)testBrokenCameraClipIsDiscarded {
    XCTAssertEqual([self verdictDictate:YES status:@"ok" text:@"привет" label:@"привет" duration:3 usable:NO],
                   SPLipClipVerdictDiscard);
}

- (void)testSidecarTextUnwrapsCommandMarkers {
    XCTAssertEqualObjects([SPLipDataPolicy sidecarTextFromRecognizedText:@"привет ⟦запятая⟧ как дела"],
                          @"привет запятая как дела");
    XCTAssertEqualObjects([SPLipDataPolicy sidecarTextFromRecognizedText:@"⟦новая строка⟧привет"],
                          @"новая строка привет");
    XCTAssertEqualObjects([SPLipDataPolicy sidecarTextFromRecognizedText:@"всё⟦отправь⟧"], @"всё отправь");
}

- (void)testSidecarTextDropsStrayBracketsAndCollapsesWhitespace {
    XCTAssertEqualObjects([SPLipDataPolicy sidecarTextFromRecognizedText:@"  один\n\nдва\t три  ⟦ "],
                          @"один два три");
    XCTAssertNil([SPLipDataPolicy sidecarTextFromRecognizedText:@"⟦⟧"]);
    XCTAssertNil([SPLipDataPolicy sidecarTextFromRecognizedText:@" \n "]);
    XCTAssertNil([SPLipDataPolicy sidecarTextFromRecognizedText:@""]);
    XCTAssertNil([SPLipDataPolicy sidecarTextFromRecognizedText:nil]);
}

- (void)testSnippetTextNeverReachesTheLabel {
    // The delivered text has a snippet expanded; only the recognized words are
    // an input of the label, so the expansion cannot leak into it.
    NSString *recognized = @"вставь мой адрес";
    NSString *delivered = @"г. Тюмень, ул. Республики, д. 1";
    NSString *label = [SPLipDataPolicy sidecarTextFromRecognizedText:recognized];
    XCTAssertEqualObjects(label, @"вставь мой адрес");
    XCTAssertFalse([label containsString:@"Тюмень"]);
    XCTAssertEqual([self verdictDictate:YES status:@"ok" text:delivered label:label duration:2.5 usable:YES],
                   SPLipClipVerdictKeep);
    // No recognized transcript at all: the clip is dropped rather than labelled with the delivered text.
    XCTAssertEqual([self verdictDictate:YES status:@"ok" text:delivered
                                  label:[SPLipDataPolicy sidecarTextFromRecognizedText:nil]
                               duration:2.5 usable:YES],
                   SPLipClipVerdictDiscard);
}

- (void)testVideoOutputSettings {
    NSDictionary *settings = [SPLipDataPolicy videoOutputSettingsWithFPS:25];
    XCTAssertEqualObjects(settings[AVVideoCodecKey], AVVideoCodecTypeH264);
    XCTAssertEqualObjects(settings[AVVideoWidthKey], @1280);
    XCTAssertEqualObjects(settings[AVVideoHeightKey], @720);
    // The full frame is kept: scaled with its aspect ratio, never cropped.
    XCTAssertEqualObjects(settings[AVVideoScalingModeKey], AVVideoScalingModeResizeAspect);
    NSDictionary *compression = settings[AVVideoCompressionPropertiesKey];
    XCTAssertEqualObjects(compression[AVVideoAverageBitRateKey], @1500000);
    XCTAssertEqualObjects(compression[AVVideoMaxKeyFrameIntervalKey], @25, @"one keyframe per second at 25 fps");
    XCTAssertEqualObjects(compression[AVVideoExpectedSourceFrameRateKey], @25);
    XCTAssertEqualObjects(compression[AVVideoAllowFrameReorderingKey], @NO);
    XCTAssertEqualObjects([SPLipDataPolicy videoOutputSettingsWithFPS:30][AVVideoCompressionPropertiesKey][AVVideoMaxKeyFrameIntervalKey], @30);
}

- (void)testSidecarMetadataFields {
    NSDictionary *meta = [SPLipDataPolicy sidecarMetadataWithClipId:1700000000123LL
                                                         durationSec:3.14159
                                                                 fps:25
                                                               width:1280
                                                              height:720
                                                        captureWidth:1920
                                                       captureHeight:1080
                                                         appBundleId:@"com.apple.Notes"
                                                          outputMode:@"light"
                                                             tooLong:YES
                                                     firstFrameLagMs:310
                                                       droppedFrames:2];
    XCTAssertEqualObjects(meta[@"id"], @1700000000123LL);
    XCTAssertEqualObjects(meta[@"duration_s"], @3.142);
    XCTAssertEqualObjects(meta[@"fps"], @25);
    XCTAssertEqualObjects(meta[@"width"], @1280);
    XCTAssertEqualObjects(meta[@"height"], @720);
    XCTAssertEqualObjects(meta[@"output_width"], @1280);
    XCTAssertEqualObjects(meta[@"output_height"], @720);
    XCTAssertEqualObjects(meta[@"capture_width"], @1920);
    XCTAssertEqualObjects(meta[@"capture_height"], @1080);
    XCTAssertEqualObjects(meta[@"app_bundle_id"], @"com.apple.Notes");
    XCTAssertEqualObjects(meta[@"output_mode"], @"light");
    XCTAssertEqualObjects(meta[@"too_long"], @YES);
    XCTAssertEqualObjects(meta[@"audio"], @NO);
    XCTAssertEqualObjects(meta[@"created"], @"2023-11-14T22:13:20.123Z");
    XCTAssertTrue([NSJSONSerialization isValidJSONObject:meta]);

    NSDictionary *minimal = [SPLipDataPolicy sidecarMetadataWithClipId:1LL durationSec:1 fps:25 width:1280
                                                                 height:720 captureWidth:640 captureHeight:480
                                                            appBundleId:nil outputMode:nil
                                                                tooLong:NO firstFrameLagMs:0 droppedFrames:0];
    XCTAssertEqualObjects(minimal[@"app_bundle_id"], @"");
    XCTAssertEqualObjects(minimal[@"too_long"], @NO);
}

- (void)testStatsCountOnlyCompleteClips {
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"lipdata-%@", [[NSUUID UUID] UUIDString]]];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    void (^clip)(NSString *, NSString *, BOOL) = ^(NSString *base, NSString *json, BOOL withVideo) {
        [json writeToFile:[dir stringByAppendingPathComponent:[base stringByAppendingString:@".json"]]
               atomically:YES encoding:NSUTF8StringEncoding error:nil];
        if (withVideo) {
            [@"x" writeToFile:[dir stringByAppendingPathComponent:[base stringByAppendingString:@".mp4"]]
                   atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    };
    clip(@"1", @"{\"duration_s\": 30.0}", YES);
    clip(@"2", @"{\"duration_s\": 15.5}", YES);
    clip(@"3", @"{\"duration_s\": 99}", NO);   // no video: not counted
    clip(@"4", @"not json", YES);              // unreadable sidecar: not counted
    [@"y" writeToFile:[dir stringByAppendingPathComponent:@"5.mp4"] atomically:YES encoding:NSUTF8StringEncoding error:nil];

    SPLipDataStats stats = [SPLipDataPolicy statsForDirectory:dir];
    XCTAssertEqual(stats.clipCount, 2);
    XCTAssertEqualWithAccuracy(stats.totalSeconds, 45.5, 0.001);

    SPLipDataStats none = [SPLipDataPolicy statsForDirectory:[dir stringByAppendingPathComponent:@"missing"]];
    XCTAssertEqual(none.clipCount, 0);
    XCTAssertEqual(none.totalSeconds, 0.0);
    [fm removeItemAtPath:dir error:nil];
}

- (void)testCounterSummaryUsesRussianPlurals {
    SPLipDataStats s1 = {1, 90};
    XCTAssertEqualObjects([SPLipDataPolicy counterSummaryForStats:s1], @"Собрано: 1 клип, 1,5 минуты");
    SPLipDataStats s2 = {3, 12};
    XCTAssertEqualObjects([SPLipDataPolicy counterSummaryForStats:s2], @"Собрано: 3 клипа, 0,2 минуты");
    SPLipDataStats s5 = {12, 25 * 60};
    XCTAssertEqualObjects([SPLipDataPolicy counterSummaryForStats:s5], @"Собрано: 12 клипов, 25 минут");
    SPLipDataStats s21 = {21, 21 * 60};
    XCTAssertEqualObjects([SPLipDataPolicy counterSummaryForStats:s21], @"Собрано: 21 клип, 21 минута");
    SPLipDataStats zero = {0, 0};
    XCTAssertEqualObjects([SPLipDataPolicy counterSummaryForStats:zero], @"Собрано: 0 клипов, 0 минут");
}

@end
