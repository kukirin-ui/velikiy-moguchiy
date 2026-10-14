#import <XCTest/XCTest.h>
#import "SPLipsPolicy.h"

@interface SPLipsPolicyTests : XCTestCase
@end

@implementation SPLipsPolicyTests

- (void)testModelGuessGetsACapitalFirstLetter {
    NSDictionary *reply = @{@"text" : @" привет как дела сегодня ", @"rescored" : @NO};
    XCTAssertEqualObjects([SPLipsPolicy insertableTextFromServiceReply:reply], @"Привет как дела сегодня");
}

- (void)testRescoredTextKeepsItsPunctuation {
    NSDictionary *reply = @{@"text" : @"привет, как у тебя дела сегодня?", @"rescored" : @YES};
    XCTAssertEqualObjects([SPLipsPolicy insertableTextFromServiceReply:reply], @"Привет, как у тебя дела сегодня?");
}

- (void)testNothingToInsert {
    XCTAssertNil([SPLipsPolicy insertableTextFromServiceReply:nil]);
    XCTAssertNil([SPLipsPolicy insertableTextFromServiceReply:@{}]);
    XCTAssertNil([SPLipsPolicy insertableTextFromServiceReply:@{@"text" : @"  \n"}]);
    XCTAssertNil([SPLipsPolicy insertableTextFromServiceReply:@{@"text" : @42}]);
    XCTAssertNil([SPLipsPolicy insertableTextFromServiceReply:(NSDictionary *)@[ @"text" ]]);
}

- (void)testServiceArguments {
    NSArray *args = [SPLipsPolicy serviceArgumentsWithScript:@"/x/lips_service.py" port:8766 idleMinutes:2.5 parentPid:42];
    XCTAssertEqualObjects(args, (@[ @"/x/lips_service.py", @"--port", @"8766", @"--idle-sec", @"150",
                                    @"--parent-pid", @"42" ]));
}

- (void)testConfigValuesFallBackToDefaults {
    XCTAssertEqual([SPLipsPolicy portFromConfigValue:@"9000"], 9000);
    XCTAssertEqual([SPLipsPolicy portFromConfigValue:@""], 8766);
    XCTAssertEqual([SPLipsPolicy portFromConfigValue:@"80"], 8766);
    XCTAssertEqual([SPLipsPolicy portFromConfigValue:@"9000x"], 8766);
    XCTAssertEqual([SPLipsPolicy portFromConfigValue:nil], 8766);
    XCTAssertEqual([SPLipsPolicy idleMinutesFromConfigValue:@"0.5"], 0.5);
    XCTAssertEqual([SPLipsPolicy idleMinutesFromConfigValue:@"0"], 10.0);
    XCTAssertEqual([SPLipsPolicy idleMinutesFromConfigValue:@"soon"], 10.0);
}

@end
