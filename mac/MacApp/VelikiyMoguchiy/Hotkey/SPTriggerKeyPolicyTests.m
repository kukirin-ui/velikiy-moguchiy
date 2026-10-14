#import <AppKit/AppKit.h>
#import <XCTest/XCTest.h>
#import "SPTriggerKeyPolicy.h"

@interface SPTriggerKeyPolicyTests : XCTestCase
@end

@implementation SPTriggerKeyPolicyTests

- (void)testFnUsageConflicts {
    XCTAssertNil(SPFnUsageConflict(0));
    XCTAssertNil(SPFnUsageConflict(-1));
    XCTAssertEqualObjects(SPFnUsageConflict(1), @"переключает раскладку");
    XCTAssertNotNil(SPFnUsageConflict(2));
    XCTAssertNotNil(SPFnUsageConflict(3));
}

- (void)testModifiersPressedAlone {
    XCTAssertEqualObjects([SPRecordedTrigger triggerForModifierKeyCode:54].value, @"right_command");
    XCTAssertEqualObjects([SPRecordedTrigger triggerForModifierKeyCode:61].value, @"right_option");
    XCTAssertEqualObjects([SPRecordedTrigger triggerForModifierKeyCode:63].value, @"fn");
    XCTAssertNil([SPRecordedTrigger triggerForModifierKeyCode:56].value);
    XCTAssertNotNil([SPRecordedTrigger triggerForModifierKeyCode:60].refusal);
}

- (void)testTypingKeysAreRefused {
    // "a", space, return, an arrow (reported with Fn) and Shift+"a".
    for (NSNumber *code in @[ @0, @49, @36, @123 ]) {
        SPRecordedTrigger *trigger = [SPRecordedTrigger triggerForKeyCode:code.integerValue
                                                           modifierFlags:NSEventModifierFlagFunction];
        XCTAssertNil(trigger.value, @"%@", code);
        XCTAssertGreaterThan(trigger.refusal.length, 0u);
    }
    XCTAssertNil([SPRecordedTrigger triggerForKeyCode:0 modifierFlags:NSEventModifierFlagShift].value);
}

- (void)testFunctionKeysAndCombos {
    XCTAssertEqualObjects([SPRecordedTrigger triggerForKeyCode:96 modifierFlags:NSEventModifierFlagFunction].value,
                          @"96");
    XCTAssertEqualObjects([SPRecordedTrigger triggerForKeyCode:49
                                                  modifierFlags:NSEventModifierFlagCommand |
                                                                NSEventModifierFlagShift].value,
                          @"command+shift+49");
    XCTAssertEqualObjects([SPRecordedTrigger triggerForKeyCode:2 modifierFlags:NSEventModifierFlagControl].value,
                          @"control+2");
}

@end
