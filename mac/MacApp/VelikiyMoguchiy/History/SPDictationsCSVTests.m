#import <XCTest/XCTest.h>
#import "SPDictationsCSV.h"

@interface SPDictationsCSVTests : XCTestCase
@end

@implementation SPDictationsCSVTests

- (void)testHeaderUsesSemicolons {
    XCTAssertEqualObjects([SPDictationsCSV headerLine], @"date;duration_s;status;text;file\r\n");
}

- (void)testRowUsesSemicolonSeparatorAndDecimalComma {
    NSString *row = [SPDictationsCSV rowWithDate:@"2026-10-12 18:30:00"
                                      durationMs:12345
                                          status:@"ok"
                                            text:@"Привет, мир."
                                            file:@"a.m4a"];
    XCTAssertEqualObjects(row,
        @"\"2026-10-12 18:30:00\";\"12,3\";\"ok\";\"Привет, мир.\";\"a.m4a\"\r\n");
}

- (void)testDurationHasNoDotDecimalMark {
    NSString *row = [SPDictationsCSV rowWithDate:@"d" durationMs:500 status:@"ok" text:@"" file:@""];
    XCTAssertTrue([row containsString:@"\"0,5\""], @"%@", row);
    XCTAssertFalse([row containsString:@"0.5"], @"%@", row);
}

- (void)testQuotesAreDoubledAndSeparatorsInTextStayInsideQuotes {
    NSString *row = [SPDictationsCSV rowWithDate:@"d" durationMs:1000 status:@"ok"
                                            text:@"он сказал \"да\"; потом ушёл"
                                            file:@""];
    XCTAssertTrue([row containsString:@"\"он сказал \"\"да\"\"; потом ушёл\""], @"%@", row);
}

- (void)testNilFieldsBecomeEmptyQuotedFields {
    XCTAssertEqualObjects([SPDictationsCSV quotedField:nil], @"\"\"");
}

@end
