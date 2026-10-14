#import <XCTest/XCTest.h>
#import "SPAppPaths.h"

@interface SPAppPathsTests : XCTestCase
@property (nonatomic, copy) NSString *home;
@end

@implementation SPAppPathsTests

- (void)setUp {
    self.home = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [[NSFileManager defaultManager] createDirectoryAtPath:self.home withIntermediateDirectories:YES attributes:nil error:nil];
}

- (void)tearDown {
    [[NSFileManager defaultManager] removeItemAtPath:self.home error:nil];
}

- (void)testNewFolderByDefault {
    XCTAssertEqualObjects(SPAppDataDirectoryInHome(self.home), [self.home stringByAppendingPathComponent:@".velikiy-moguchiy"]);
}

- (void)testLegacyFolderWhileItIsTheOnlyOne {
    NSString *legacy = [self.home stringByAppendingPathComponent:@".koe"];
    [[NSFileManager defaultManager] createDirectoryAtPath:legacy withIntermediateDirectories:YES attributes:nil error:nil];
    XCTAssertEqualObjects(SPAppDataDirectoryInHome(self.home), legacy);
    NSString *current = [self.home stringByAppendingPathComponent:@".velikiy-moguchiy"];
    [[NSFileManager defaultManager] createDirectoryAtPath:current withIntermediateDirectories:YES attributes:nil error:nil];
    XCTAssertEqualObjects(SPAppDataDirectoryInHome(self.home), current);
}

@end
