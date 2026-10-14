#import <XCTest/XCTest.h>
#import "SPHotkeyNames.h"

@interface SPHotkeyNamesTests : XCTestCase
@end

@implementation SPHotkeyNamesTests

- (void)testNamesForSentences {
    XCTAssertEqualObjects(SPHotkeyShortName(@"fn"), @"Fn");
    XCTAssertEqualObjects(SPHotkeyShortName(@" right_command "), @"правый ⌘");
    XCTAssertEqualObjects(SPHotkeyShortName(@"left_option"), @"левый ⌥");
    XCTAssertEqualObjects(SPHotkeyShortName(@"96"), @"F5");
    XCTAssertNil(SPHotkeyShortName(@"cmd+shift+49"));
    XCTAssertNil(SPHotkeyShortName(@""));
}

@end
