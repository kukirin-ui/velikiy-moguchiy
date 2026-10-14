#import <XCTest/XCTest.h>
#import "SPUpdatePolicy.h"

@interface SPUpdatePolicyTests : XCTestCase
@end

@implementation SPUpdatePolicyTests

- (void)testVersionsCompareNumerically {
    XCTAssertEqual([SPUpdatePolicy compareVersion:@"0.10.0" toVersion:@"0.9.2"], NSOrderedDescending);
    XCTAssertEqual([SPUpdatePolicy compareVersion:@"0.1.0" toVersion:@"0.1.1"], NSOrderedAscending);
    XCTAssertEqual([SPUpdatePolicy compareVersion:@"1.0" toVersion:@"1.0.0"], NSOrderedSame);
    XCTAssertEqual([SPUpdatePolicy compareVersion:@"0.2" toVersion:@"0.1.9"], NSOrderedDescending);
    XCTAssertEqual([SPUpdatePolicy compareVersion:@"0.2.0-beta" toVersion:@"0.2.0"], NSOrderedSame);
}

- (void)testVersionFromTag {
    XCTAssertEqualObjects([SPUpdatePolicy versionFromTag:@"v0.2.0" prefix:@"v"], @"0.2.0");
    XCTAssertEqualObjects([SPUpdatePolicy versionFromTag:@"lips-0.1" prefix:@"lips-"], @"0.1");
    XCTAssertNil([SPUpdatePolicy versionFromTag:@"mac-v0.2.0" prefix:@"v"]);
    XCTAssertNil([SPUpdatePolicy versionFromTag:@"lips-next" prefix:@"lips-"]);
    XCTAssertNil([SPUpdatePolicy versionFromTag:@"lips-" prefix:@"lips-"]);
    XCTAssertNil([SPUpdatePolicy versionFromTag:nil prefix:@"v"]);
}

- (void)testCheckAtMostDaily {
    NSDate *now = [NSDate dateWithTimeIntervalSince1970:1000000];
    XCTAssertTrue([SPUpdatePolicy isCheckDueWithLastCheck:nil now:now]);
    XCTAssertFalse([SPUpdatePolicy isCheckDueWithLastCheck:[now dateByAddingTimeInterval:-3600] now:now]);
    XCTAssertTrue([SPUpdatePolicy isCheckDueWithLastCheck:[now dateByAddingTimeInterval:-86400] now:now]);
    XCTAssertTrue([SPUpdatePolicy isCheckDueWithLastCheck:[now dateByAddingTimeInterval:3600] now:now]);
}

- (void)testNewestPublishedReleaseWins {
    NSArray *releases = @[
        @{@"tag_name" : @"v0.3.0", @"draft" : @YES},
        @{@"tag_name" : @"v0.2.1-rc1", @"prerelease" : @YES},
        @{@"tag_name" : @"v0.2.0"},
        @{@"tag_name" : @"v0.10.0"},
        @{@"tag_name" : @"lips-0.9"},
        @"junk",
    ];
    XCTAssertEqualObjects([SPUpdatePolicy newestReleaseIn:releases tagPrefix:@"v"][@"tag_name"], @"v0.10.0");
    XCTAssertEqualObjects([SPUpdatePolicy newestReleaseIn:releases tagPrefix:@"lips-"][@"tag_name"], @"lips-0.9");
    NSArray *onlyDrafts = @[ @{@"tag_name" : @"v1.0", @"draft" : @YES} ];
    XCTAssertNil([SPUpdatePolicy newestReleaseIn:onlyDrafts tagPrefix:@"v"]);
    NSDictionary *apiError = @{@"message" : @"rate limited"};
    XCTAssertNil([SPUpdatePolicy newestReleaseIn:apiError tagPrefix:@"v"]);
}

@end
