#import <XCTest/XCTest.h>
#import "SPLocalAsrPolicy.h"

@interface SPLocalAsrPolicyTests : XCTestCase
@end

@implementation SPLocalAsrPolicyTests

- (void)expectOffer:(BOOL)expected asr:(NSDictionary *)asr supported:(NSArray *)supported {
    BOOL offer = [SPLocalAsrPolicy shouldOfferLocalAsrWithAsrConfig:asr supportedLocalProviders:supported];
    XCTAssertEqual(offer, expected, @"%@ with %@", asr, supported);
}

- (void)testNoKeyOffersTheLocalModel {
    NSArray *supported = @[ @"apple-speech", @"sherpa-onnx" ];
    [self expectOffer:YES asr:@{@"provider" : @"qwen", @"qwen" : @{@"api_key" : @""}} supported:supported];
    // A fresh config without a provider means the default, qwen.
    [self expectOffer:YES asr:@{} supported:supported];
    [self expectOffer:YES asr:nil supported:supported];
    NSDictionary *choice = [SPLocalAsrPolicy localChoiceForSupportedProviders:supported];
    XCTAssertEqualObjects(choice[@"provider"], @"sherpa-onnx");
    XCTAssertEqualObjects(choice[@"model"], @"sherpa-onnx/ru-vosk-small");
}

- (void)testAKeyIsNeverOverridden {
    NSArray *supported = @[ @"sherpa-onnx" ];
    [self expectOffer:NO asr:@{@"provider" : @"qwen", @"qwen" : @{@"api_key" : @"k"}} supported:supported];
    [self expectOffer:NO
                  asr:@{@"provider" : @"qwen", @"qwen" : @{@"api_key" : @"", @"api_keys" : @[ @"", @"k2" ]}}
            supported:supported];
    [self expectOffer:NO asr:@{@"provider" : @"doubao", @"doubao" : @{@"app_key" : @"a", @"access_key" : @"b"}}
            supported:supported];
    [self expectOffer:YES asr:@{@"provider" : @"doubao", @"doubao" : @{@"app_key" : @"a"}} supported:supported];
    [self expectOffer:NO asr:@{@"provider" : @"glm", @"glm" : @{@"api_key" : @"g"}} supported:supported];
    [self expectOffer:YES asr:@{@"provider" : @"mimo", @"mimo" : @{@"api_key" : @"  "}} supported:supported];
    // A key given as ${VAR} counts as a key.
    [self expectOffer:NO asr:@{@"provider" : @"qwen", @"qwen" : @{@"api_key" : @"${DASHSCOPE_API_KEY}"}}
            supported:supported];
}

- (void)testLocalOrUnknownProvidersAreLeftAlone {
    for (NSString *provider in @[ @"apple-speech", @"mlx", @"sherpa-onnx", @"wetype", @"something-new" ]) {
        [self expectOffer:NO asr:@{@"provider" : provider} supported:@[ @"sherpa-onnx" ]];
    }
}

- (void)testNothingToOfferWithoutALocalModel {
    [self expectOffer:NO asr:@{} supported:@[ @"apple-speech" ]];
    XCTAssertNil([SPLocalAsrPolicy localChoiceForSupportedProviders:nil]);
    NSDictionary *choice = [SPLocalAsrPolicy localChoiceForSupportedProviders:@[ @"sherpa-onnx", @"mlx" ]];
    XCTAssertEqualObjects(choice[@"provider"], @"mlx");
}

@end
