#import <XCTest/XCTest.h>
#import "SPOutputModes.h"

@interface SPOutputModesTests : XCTestCase
@end

@implementation SPOutputModesTests

- (void)testCycleGoesRawLightStructuredFormalAndBack {
    XCTAssertEqualObjects(SPNextOutputMode(@"raw"), @"light");
    XCTAssertEqualObjects(SPNextOutputMode(@"light"), @"structured");
    XCTAssertEqualObjects(SPNextOutputMode(@"structured"), @"formal");
    XCTAssertEqualObjects(SPNextOutputMode(@"formal"), @"raw");
}

- (void)testUnknownOrMissingModeCountsAsRaw {
    XCTAssertEqualObjects(SPNextOutputMode(nil), @"light");
    XCTAssertEqualObjects(SPNextOutputMode(@""), @"light");
    XCTAssertEqualObjects(SPNextOutputMode(@"bogus"), @"light");
    XCTAssertEqualObjects(SPNormalizedOutputMode(@"  Formal\n"), @"formal");
    XCTAssertEqualObjects(SPNormalizedOutputMode(@"nope"), @"raw");
}

- (void)testTitlesAndLettersCoverEveryMode {
    NSArray *titles = @[ @"Как сказал", @"Лёгкая правка", @"Структура", @"Деловой стиль" ];
    NSArray *letters = @[ @"R", @"L", @"S", @"F" ];
    NSArray *ids = SPOutputModeIds();
    XCTAssertEqual(ids.count, 4u);
    for (NSUInteger i = 0; i < ids.count; i++) {
        XCTAssertEqualObjects(SPOutputModeTitle(ids[i]), titles[i]);
        XCTAssertEqualObjects(SPOutputModeLetter(ids[i]), letters[i]);
    }
    XCTAssertEqualObjects(SPOutputModeTitle(@"x"), @"Как сказал");
    XCTAssertEqualObjects(SPOutputModeLetter(nil), @"R");
}

@end
