#import <XCTest/XCTest.h>
#import "SPRetranscriber.h"

@interface SPRetranscriberTests : XCTestCase
@end

@implementation SPRetranscriberTests

- (void)testAutoRetryOnlyForFailedRecordingsOfHalfASecondWhenEnabled {
    XCTAssertTrue([SPRetranscriber shouldAutoRetryForStatus:@"error" durationMs:500 audioExists:YES enabled:YES]);
    XCTAssertTrue([SPRetranscriber shouldAutoRetryForStatus:@"error" durationMs:12552 audioExists:YES enabled:YES]);
    XCTAssertFalse([SPRetranscriber shouldAutoRetryForStatus:@"error" durationMs:499 audioExists:YES enabled:YES]);
    XCTAssertFalse([SPRetranscriber shouldAutoRetryForStatus:@"error" durationMs:5000 audioExists:NO enabled:YES]);
    XCTAssertFalse([SPRetranscriber shouldAutoRetryForStatus:@"error" durationMs:5000 audioExists:YES enabled:NO]);
    for (NSString *status in @[ @"ok", @"cancelled", @"empty", @"" ]) {
        XCTAssertFalse([SPRetranscriber shouldAutoRetryForStatus:status durationMs:5000 audioExists:YES enabled:YES],
                       @"%@", status);
    }
}

- (void)testCliArgumentsPassAppOnlyWhenKnown {
    NSArray *plain = [SPRetranscriber cliArgumentsForAudioPath:@"/r/1.m4a" appBundleId:nil];
    XCTAssertEqualObjects(plain, (@[ @"transcribe", @"/r/1.m4a", @"-p", @"qwen" ]));
    NSArray *empty = [SPRetranscriber cliArgumentsForAudioPath:@"/r/1.m4a" appBundleId:@""];
    XCTAssertEqualObjects(empty, plain);
    NSArray *withApp = [SPRetranscriber cliArgumentsForAudioPath:@"/r/1.m4a" appBundleId:@"com.apple.Notes"];
    XCTAssertEqualObjects(withApp, (@[ @"transcribe", @"/r/1.m4a", @"-p", @"qwen", @"--app", @"com.apple.Notes" ]));
}

- (void)testChildEnvironmentFindsHomebrewWithoutDuplicatingPaths {
    NSDictionary *env = [SPRetranscriber childEnvironmentFrom:@{ @"PATH" : @"/usr/bin:/custom/bin", @"HOME" : @"/h" }];
    NSArray *paths = [env[@"PATH"] componentsSeparatedByString:@":"];
    XCTAssertEqualObjects(paths.firstObject, @"/usr/bin");
    XCTAssertTrue([paths containsObject:@"/custom/bin"]);
    XCTAssertTrue([paths containsObject:@"/opt/homebrew/bin"]);
    XCTAssertTrue([paths containsObject:@"/usr/local/bin"]);
    XCTAssertEqual([paths filteredArrayUsingPredicate:
        [NSPredicate predicateWithFormat:@"SELF == '/usr/bin'"]].count, 1u);
    XCTAssertEqualObjects(env[@"HOME"], @"/h");

    NSDictionary *bare = [SPRetranscriber childEnvironmentFrom:@{}];
    XCTAssertTrue([bare[@"PATH"] containsString:@"/opt/homebrew/bin"]);
}

- (void)testCliStderrBecomesSummaryAndProviderMessage {
    NSString *stderrText = @"Decoding /r/1.m4a ...\nAudio: 12.5s, 400000 bytes PCM\nConnecting to qwen ASR...\n"
                           @"error: connect: connection timed out\n";
    NSString *reason = [SPRetranscriber errorReasonForCliStderr:stderrText];
    XCTAssertEqualObjects(reason, @"сервис распознавания не ответил вовремя\nconnect: connection timed out");

    NSString *keyReason = [SPRetranscriber errorReasonForCliStderr:@"error: ASR error: Incorrect API key sk-LEAKED99\n"];
    XCTAssertTrue([keyReason hasPrefix:@"проблема с API-ключом\n"]);
    XCTAssertFalse([keyReason containsString:@"LEAKED99"]);

    XCTAssertEqualObjects([SPRetranscriber errorReasonForCliStderr:@""], @"ошибка распознавания");
}

- (void)testSummaryClassifiesProviderMessages {
    XCTAssertEqualObjects([SPRetranscriber summaryForProviderMessage:@"HTTP error: 429 Too Many Requests"],
                          @"лимит или баланс ключа исчерпан");
    XCTAssertEqualObjects([SPRetranscriber summaryForProviderMessage:@"ffmpeg not found."],
                          @"не удалось декодировать запись (ffmpeg)");
    XCTAssertEqualObjects([SPRetranscriber summaryForProviderMessage:@"WebSocket error: connection reset"],
                          @"нет связи с сервисом распознавания");
    XCTAssertEqualObjects([SPRetranscriber summaryForProviderMessage:@"something odd 14012"],
                          @"ошибка распознавания");
}

@end
