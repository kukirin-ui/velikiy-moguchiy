#import <XCTest/XCTest.h>
#import "SPErrorExplainer.h"

@interface SPErrorExplainerTests : XCTestCase
@end

@implementation SPErrorExplainerTests

- (void)testCoreMessagesMapToKinds {
    NSDictionary<NSString *, NSNumber *> *cases = @{
        @"ASR connection failed: api_key is required" : @(SPErrorKindNoKey),
        @"ASR connection failed: HTTP error: 401 Unauthorized" : @(SPErrorKindBadKey),
        @"ASR connection failed: Invalid API-key provided." : @(SPErrorKindBadKey),
        @"ASR protocol error: Arrearage: Access denied, please make sure your account is in good standing." :
            @(SPErrorKindNoBalance),
        @"ASR protocol error: AllocationQuota.FreeTierOnly" : @(SPErrorKindNoBalance),
        @"ASR connection failed: HTTP error: 429 Too Many Requests" : @(SPErrorKindRateLimit),
        @"ASR protocol error: Throttling.RateQuota" : @(SPErrorKindRateLimit),
        @"ASR connection failed: HTTP error: 403 Forbidden" : @(SPErrorKindAccessDenied),
        @"ASR connection failed: model not found: models/vosk-ru" : @(SPErrorKindLocalModel),
        @"audio buffer error: overflow" : @(SPErrorKindMicrophone),
        @"ASR connection failed: connection timed out" : @(SPErrorKindTimeout),
        @"ASR result timed out" : @(SPErrorKindTimeout),
        @"ASR connection failed: HTTP error: 503 Service Unavailable" : @(SPErrorKindService),
        @"ASR connection failed: IO error: failed to lookup address information" : @(SPErrorKindNetwork),
        @"ASR connection failed: WebSocket error: connection reset" : @(SPErrorKindNetwork),
        @"something odd 14012" : @(SPErrorKindUnknown),
        @"" : @(SPErrorKindUnknown),
    };
    [cases enumerateKeysAndObjectsUsingBlock:^(NSString *message, NSNumber *kind, BOOL *stop) {
        XCTAssertEqual([SPErrorExplainer kindForMessage:message], kind.integerValue, @"%@", message);
    }];
}

- (void)testExplanationsAreRussianWithoutProviderText {
    NSArray<NSString *> *messages = @[
        @"ASR connection failed: api_key is required",
        @"ASR connection failed: Invalid API-key provided.",
        @"ASR protocol error: Arrearage",
        @"ASR connection failed: connection timed out",
        @"something odd 14012",
    ];
    NSCharacterSet *latin = [NSCharacterSet characterSetWithCharactersInString:
                                                @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"];
    for (NSString *message in messages) {
        SPErrorExplanation *explanation = [SPErrorExplainer explanationForMessage:message recordingKept:YES];
        XCTAssertGreaterThan(explanation.shortText.length, 0u);
        XCTAssertLessThanOrEqual(explanation.shortText.length, 26u, @"%@", explanation.shortText);
        XCTAssertFalse([explanation.detail containsString:message], @"%@", message);
        NSString *withoutBrands = [[[explanation.detail stringByReplacingOccurrencesOfString:@"DashScope" withString:@""]
            stringByReplacingOccurrencesOfString:@"Alibaba Cloud" withString:@""]
            stringByReplacingOccurrencesOfString:@"VPN" withString:@""];
        withoutBrands = [withoutBrands stringByReplacingOccurrencesOfString:@"Mac" withString:@""];
        XCTAssertEqual([withoutBrands rangeOfCharacterFromSet:latin].location, (NSUInteger)NSNotFound,
                       @"%@", explanation.detail);
    }
}

- (void)testActionsLeadToTheFix {
    XCTAssertEqual([SPErrorExplainer explanationForMessage:@"api_key is required" recordingKept:YES].action, SPErrorActionAsrSettings);
    XCTAssertEqual([SPErrorExplainer explanationForMessage:@"microphone is busy" recordingKept:YES].action,
                   SPErrorActionMicrophonePrivacy);
    XCTAssertEqual([SPErrorExplainer explanationForMessage:@"connection timed out" recordingKept:YES].action,
                   SPErrorActionRecentDictations);
    SPErrorExplanation *unsaved = [SPErrorExplainer explanationForMessage:@"connection timed out" recordingKept:NO];
    XCTAssertEqual(unsaved.action, SPErrorActionNone);
    XCTAssertFalse([unsaved.detail containsString:@"Последних диктовках"]);
}

- (void)testCodeIsStableAndOnlyShownForUnknownErrors {
    SPErrorExplanation *first = [SPErrorExplainer explanationForMessage:@"something odd 14012" recordingKept:YES];
    SPErrorExplanation *again = [SPErrorExplainer explanationForMessage:@"something odd 14012" recordingKept:YES];
    XCTAssertEqualObjects(first.code, again.code);
    XCTAssertEqual(first.code.length, 4u);
    XCTAssertTrue([[SPErrorExplainer notificationBodyForExplanation:first] containsString:first.code]);

    SPErrorExplanation *known = [SPErrorExplainer explanationForMessage:@"api_key is required" recordingKept:YES];
    XCTAssertFalse([[SPErrorExplainer notificationBodyForExplanation:known] containsString:@"Код"]);
}

- (void)testWarnings {
    SPErrorExplanation *llm = [SPErrorExplainer explanationForWarning:@"LLM correction failed: API key is required"];
    XCTAssertEqualObjects(llm.shortText, @"Вставлено без правки");
    XCTAssertEqual(llm.action, SPErrorActionLlmSettings);
    XCTAssertTrue([llm.detail containsString:@"Языковая модель"]);
    XCTAssertNotNil([SPErrorExplainer explanationForWarning:@"Rewrite failed: timeout"]);
    XCTAssertNil([SPErrorExplainer explanationForWarning:@"something else"]);
}

@end
