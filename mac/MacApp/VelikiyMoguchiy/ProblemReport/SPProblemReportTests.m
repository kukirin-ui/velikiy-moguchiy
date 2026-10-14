#import <XCTest/XCTest.h>
#import "SPProblemReport.h"

@interface SPProblemReportTests : XCTestCase
@end

@implementation SPProblemReportTests

- (NSString *)redact:(NSString *)log {
    return [SPProblemReport redactedLog:log homeDirectory:@"/Users/user"];
}

- (void)testKeysAndTokensAreHidden {
    NSString *out = [self redact:@"api_key: sk-test-abcdefghijklmnopqrstu\n"
                                 @"Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload\n"
                                 @"{\"api_keys\": [\"k-1234\"], \"token\"=abc123}\n"
                                 @"key a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8 in use"];
    XCTAssertFalse([out containsString:@"sk-test-abcdef"], @"%@", out);
    XCTAssertFalse([out containsString:@"eyJhbGci"], @"%@", out);
    XCTAssertFalse([out containsString:@"k-1234"], @"%@", out);
    XCTAssertFalse([out containsString:@"abc123"], @"%@", out);
    XCTAssertFalse([out containsString:@"a1b2c3d4e5f6a7b8"], @"%@", out);
}

- (void)testPathsAndMailAreHidden {
    NSString *out = [self redact:@"open /Users/user/.velikiy-moguchiy/config.yaml; /Users/name/x; mail you@example.org"];
    XCTAssertEqualObjects(out, @"open ~/.velikiy-moguchiy/config.yaml; /Users/[имя]/x; mail [почта]");
}

- (void)testDictatedTextIsHidden {
    NSString *out = [self redact:@"[MiMo ASR] Final text: привет мир\n"
                                 @"lips: model said \"секретная фраза\"\n"
                                 @"Interim: как дела\n"
                                 @"LLM request — asr_text: «тайна»\n"
                                 @"ASR final text: 15 chars"];
    for (NSString *secret in @[ @"привет мир", @"секретная фраза", @"как дела", @"тайна" ]) {
        XCTAssertFalse([out containsString:secret], @"%@ in %@", secret, out);
    }
    XCTAssertTrue([out containsString:@"ASR final text: 15 chars"], @"%@", out);
}

- (void)testOrdinaryLinesSurvive {
    NSString *line = @"12:00:01 [VelikiyMoguchiy] Permissions — mic:1 accessibility:1 inputMonitoring:0";
    XCTAssertEqualObjects([self redact:line], line);
}

- (void)testIssueURLIsPrefilledAndBounded {
    NSURL *url = [SPProblemReport issueURLWithAppVersion:@"0.2.0 (5)" system:@"macOS 26.1" provider:@"qwen"
                                                     log:@"a & b = c\nline two"];
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    XCTAssertEqualObjects(components.host, @"github.com");
    XCTAssertEqualObjects(components.path, @"/zigansh1n/velikiy-moguchiy/issues/new");
    NSMutableDictionary *items = [NSMutableDictionary dictionary];
    for (NSURLQueryItem *item in components.queryItems) items[item.name] = item.value;
    XCTAssertEqualObjects(items[@"version"], @"0.2.0 (5)");
    XCTAssertEqualObjects(items[@"provider"], @"qwen");
    XCTAssertEqualObjects(items[@"log"], @"a & b = c\nline two");
    XCTAssertEqualObjects(items[@"product"], @"Диктовка для macOS (mac/)");
    XCTAssertEqual(items.count, 6u);

    NSMutableArray *lines = [NSMutableArray array];
    for (int i = 0; i < 2000; i++) [lines addObject:[NSString stringWithFormat:@"line %d of a long log", i]];
    NSURL *longURL = [SPProblemReport issueURLWithAppVersion:@"1" system:@"s" provider:@"p"
                                                         log:[lines componentsJoinedByString:@"\n"]];
    XCTAssertLessThanOrEqual(longURL.absoluteString.length, SPProblemReport.maxURLLength);
    XCTAssertTrue([longURL.absoluteString containsString:@"line%201999%20of"], @"the newest lines are kept");
}

@end
