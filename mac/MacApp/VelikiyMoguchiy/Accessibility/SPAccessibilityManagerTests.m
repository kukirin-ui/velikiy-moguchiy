#import <XCTest/XCTest.h>
#import "SPAccessibilityManager.h"

@interface SPAccessibilityManagerTests : XCTestCase
@end

@implementation SPAccessibilityManagerTests

- (void)testPasswordFieldsAreNeverPastedInto {
    XCTAssertEqual(SPPasteTargetForFocus(@"AXSecureTextField", nil, YES, @"com.apple.Safari"), SPPasteTargetSecure);
    XCTAssertEqual(SPPasteTargetForFocus(@"AXTextField", @"AXSecureTextField", YES, @"com.google.Chrome"),
                   SPPasteTargetSecure);
}

- (void)testNoTargetOnlyWhenCertain {
    XCTAssertEqual(SPPasteTargetForFocus(nil, nil, NO, @"com.apple.finder"), SPPasteTargetNone);
    XCTAssertEqual(SPPasteTargetForFocus(@"AXOutline", nil, NO, @"com.apple.finder"), SPPasteTargetNone);
    XCTAssertEqual(SPPasteTargetForFocus(@"AXButton", nil, NO, @"com.example.app"), SPPasteTargetNone);
    // Apps that report no focus, and anything unknown, keep pasting.
    XCTAssertEqual(SPPasteTargetForFocus(nil, nil, NO, @"com.example.game"), SPPasteTargetPaste);
    XCTAssertEqual(SPPasteTargetForFocus(@"AXGroup", nil, NO, @"com.tinyspeck.slackmacgap"), SPPasteTargetPaste);
    XCTAssertEqual(SPPasteTargetForFocus(@"AXCell", nil, NO, @"com.microsoft.Excel"), SPPasteTargetPaste);
    XCTAssertEqual(SPPasteTargetForFocus(@"AXTextArea", nil, YES, @"com.apple.Terminal"), SPPasteTargetPaste);
    XCTAssertEqual(SPPasteTargetForFocus(@"AXList", nil, YES, @"com.example.app"), SPPasteTargetPaste);
}

@end
