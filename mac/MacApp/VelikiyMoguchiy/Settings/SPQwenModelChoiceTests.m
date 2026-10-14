#import <XCTest/XCTest.h>
#import "SPQwenModelChoice.h"

@interface SPQwenModelChoiceTests : XCTestCase
@end

@implementation SPQwenModelChoiceTests

- (void)testOmniIsTheDefaultAndListedFirst {
    XCTAssertEqualObjects(SPQwenModelChoice.defaultModel, @"qwen3.8-omni-flash-realtime");
    XCTAssertEqualObjects(SPQwenModelChoice.presetModels.firstObject, SPQwenModelChoice.defaultModel);
    XCTAssertTrue([SPQwenModelChoice isPresetModel:@"qwen3-asr-flash-realtime"]);
}

- (void)testOnlyModelsOfTheRealtimeProtocolAreOffered {
    XCTAssertFalse([SPQwenModelChoice isPresetModel:@"fun-asr-realtime"]);
    XCTAssertFalse([SPQwenModelChoice isPresetModel:@"paraformer-realtime-v2"]);
}

- (void)testTitlesExplainTheTradeOff {
    XCTAssertEqualObjects([SPQwenModelChoice titleForPresetModel:@"qwen3.8-omni-flash-realtime"],
                          @"qwen3.8-omni-flash-realtime — умная, точнее (по умолчанию)");
    XCTAssertEqualObjects([SPQwenModelChoice titleForPresetModel:@"qwen3-asr-flash-realtime"],
                          @"qwen3-asr-flash-realtime — дословная");
}

- (void)testAMissingConfigValueMeansTheDefault {
    XCTAssertEqualObjects([SPQwenModelChoice effectiveModelForConfigValue:nil], SPQwenModelChoice.defaultModel);
    XCTAssertEqualObjects([SPQwenModelChoice effectiveModelForConfigValue:@"  "], SPQwenModelChoice.defaultModel);
    XCTAssertEqualObjects([SPQwenModelChoice effectiveModelForConfigValue:@"qwen3.5-omni-flash-realtime"],
                          @"qwen3.5-omni-flash-realtime");
}

- (void)testSaveTakesThePresetOrTheTrimmedCustomModel {
    XCTAssertEqualObjects([SPQwenModelChoice modelToSaveForPreset:@"qwen3-asr-flash-realtime" customText:@"x"],
                          @"qwen3-asr-flash-realtime");
    XCTAssertEqualObjects([SPQwenModelChoice modelToSaveForPreset:nil customText:@" qwen3.5-omni-flash-realtime\n"],
                          @"qwen3.5-omni-flash-realtime");
}

- (void)testAnEmptyCustomModelIsNeverSaved {
    XCTAssertNil([SPQwenModelChoice modelToSaveForPreset:nil customText:@"   "]);
    XCTAssertNil([SPQwenModelChoice modelToSaveForPreset:nil customText:nil]);
}

@end
