#import <XCTest/XCTest.h>
#import <AppKit/AppKit.h>
#import "SPClipboardManager.h"

/// Pure-logic tests; none of them touches the real pasteboard.
@interface SPClipboardManagerTests : XCTestCase
@end

@implementation SPClipboardManagerTests

- (void)testConcealedTypeMarksAnItemAsConcealed {
    NSArray *types = @[ @"public.utf8-plain-text", @"org.nspasteboard.ConcealedType" ];
    XCTAssertTrue([SPClipboardManager typesContainConcealed:types]);
    XCTAssertFalse([SPClipboardManager typesContainConcealed:@[ @"public.utf8-plain-text" ]]);
    // Transient/auto-generated are not "concealed": a normal copy from an app
    // that merely hides itself from history is still restorable.
    XCTAssertFalse([SPClipboardManager typesContainConcealed:@[ @"org.nspasteboard.TransientType" ]]);
}

- (void)testAnyConcealedItemMakesTheWholeClipboardConcealed {
    NSPasteboardItem *plain = [[NSPasteboardItem alloc] init];
    [plain setString:@"hello" forType:NSPasteboardTypeString];
    NSPasteboardItem *secret = [[NSPasteboardItem alloc] init];
    [secret setString:@"hunter2" forType:NSPasteboardTypeString];
    [secret setData:[NSData data] forType:@"org.nspasteboard.ConcealedType"];

    NSArray<NSPasteboardItem *> *onlyPlain = @[ plain ];
    NSArray<NSPasteboardItem *> *mixed = @[ plain, secret ];
    XCTAssertFalse([SPClipboardManager itemsContainConcealed:onlyPlain]);
    XCTAssertTrue([SPClipboardManager itemsContainConcealed:mixed]);
    XCTAssertFalse([SPClipboardManager itemsContainConcealed:@[]]);
}

- (void)testOnlyTextRtfHtmlPngAndFileUrlsAreBackedUp {
    NSArray *kept = @[ @"public.utf8-plain-text", @"public.rtf", @"public.html", @"public.png",
                       @"public.file-url" ];
    for (NSString *type in kept) {
        XCTAssertTrue([SPClipboardManager isBackupType:type], @"%@", type);
    }
    NSArray *skipped = @[
        @"com.apple.pasteboard.promised-file-url",
        @"com.apple.pasteboard.promised-file-content-type",
        @"NSFilesPromisePboardType",
        @"com.apple.NSFilePromiseItemMetaData",
        @"com.apple.pasteboard.promised-suggested-file-name",
        @"public.tiff",
        @"com.adobe.pdf",
        @"dyn.ah62d4rv4gu8zs3pcnzme2",
        @"org.nspasteboard.ConcealedType",
        @"com.microsoft.Excel.Link",
    ];
    for (NSString *type in skipped) {
        XCTAssertFalse([SPClipboardManager isBackupType:type], @"%@", type);
    }
}

- (void)testBackupTypesKeepOrderAndDropEverythingElse {
    NSArray *types = @[ @"com.apple.pasteboard.promised-file-url", @"public.html",
                        @"public.tiff", @"public.utf8-plain-text", @"public.png" ];
    NSArray *expected = @[ @"public.html", @"public.utf8-plain-text", @"public.png" ];
    XCTAssertEqualObjects([SPClipboardManager backupTypesFromTypes:types], expected);
    XCTAssertEqual([SPClipboardManager backupTypesFromTypes:@[]].count, (NSUInteger)0);
}

- (void)testBackupBudgetIsSixteenMebibytesInclusive {
    XCTAssertEqual(SPClipboardBackupMaxBytes, (NSUInteger)(16 * 1024 * 1024));
    XCTAssertTrue([SPClipboardManager totalBytesWithinBudget:0]);
    XCTAssertTrue([SPClipboardManager totalBytesWithinBudget:SPClipboardBackupMaxBytes]);
    XCTAssertFalse([SPClipboardManager totalBytesWithinBudget:SPClipboardBackupMaxBytes + 1]);
}

- (void)testSnapshotChildIsOnlyTriggeredByItsExactArguments {
    const char *normal[] = { "VelikiyMoguchiy" };
    XCTAssertEqual([SPClipboardManager runSnapshotChildIfRequestedWithArgc:1 argv:normal], -1);
    const char *wrongFlag[] = { "VelikiyMoguchiy", "--other", "x" };
    XCTAssertEqual([SPClipboardManager runSnapshotChildIfRequestedWithArgc:3 argv:wrongFlag], -1);
    const char *noName[] = { "VelikiyMoguchiy", "--velikiy-moguchiy-pb-snapshot" };
    XCTAssertEqual([SPClipboardManager runSnapshotChildIfRequestedWithArgc:2 argv:noName], -1);
}

@end
