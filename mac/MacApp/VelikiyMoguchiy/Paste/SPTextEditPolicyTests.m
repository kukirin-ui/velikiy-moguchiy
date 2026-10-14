#import <XCTest/XCTest.h>
#import "SPTextEditPolicy.h"

@interface SPTextEditPolicyTests : XCTestCase
@end

@implementation SPTextEditPolicyTests

#pragma mark Purpose plumbing

- (void)testPurposeCodesMatchTheRustSide {
    XCTAssertEqual((uint8_t)SPSessionPurposeDictate, 0);
    XCTAssertEqual((uint8_t)SPSessionPurposeTranslate, 1);
    XCTAssertEqual((uint8_t)SPSessionPurposeAsk, 2);
    XCTAssertEqual((uint8_t)SPSessionPurposeEdit, 3);
}

- (void)testEditNeedsASelectionOtherwiseItIsAsk {
    XCTAssertEqual([SPTextEditPolicy effectivePurposeForRequested:SPSessionPurposeEdit selectedText:@"Привет"],
                   SPSessionPurposeEdit);
    XCTAssertEqual([SPTextEditPolicy effectivePurposeForRequested:SPSessionPurposeEdit selectedText:nil],
                   SPSessionPurposeAsk);
    XCTAssertEqual([SPTextEditPolicy effectivePurposeForRequested:SPSessionPurposeEdit selectedText:@""],
                   SPSessionPurposeAsk);
    XCTAssertEqual([SPTextEditPolicy effectivePurposeForRequested:SPSessionPurposeEdit selectedText:@" \n\t "],
                   SPSessionPurposeAsk, @"whitespace is not a selection to rewrite");
}

- (void)testEditRefusesASelectionThatWouldHaveToBeCutOff {
    NSString *atLimit = [@"" stringByPaddingToLength:SPEditMaxSelectionChars withString:@"я" startingAtIndex:0];
    NSString *over = [atLimit stringByAppendingString:@"я"];
    XCTAssertEqual([SPTextEditPolicy effectivePurposeForRequested:SPSessionPurposeEdit selectedText:atLimit],
                   SPSessionPurposeEdit);
    XCTAssertEqual([SPTextEditPolicy effectivePurposeForRequested:SPSessionPurposeEdit selectedText:over],
                   SPSessionPurposeAsk);
}

- (void)testOtherPurposesPassThroughUnchanged {
    for (SPSessionPurpose purpose = SPSessionPurposeDictate; purpose <= SPSessionPurposeAsk; purpose++) {
        XCTAssertEqual([SPTextEditPolicy effectivePurposeForRequested:purpose selectedText:@"текст"], purpose);
        XCTAssertEqual([SPTextEditPolicy effectivePurposeForRequested:purpose selectedText:nil], purpose);
    }
}

- (void)testWhichPurposesInsertAndWhichCountAsDictation {
    XCTAssertTrue([SPTextEditPolicy purposeInsertsText:SPSessionPurposeDictate]);
    XCTAssertTrue([SPTextEditPolicy purposeInsertsText:SPSessionPurposeTranslate]);
    XCTAssertTrue([SPTextEditPolicy purposeInsertsText:SPSessionPurposeEdit]);
    XCTAssertFalse([SPTextEditPolicy purposeInsertsText:SPSessionPurposeAsk], @"an answer goes to the clipboard only");
    XCTAssertTrue([SPTextEditPolicy purposeCountsAsDictation:SPSessionPurposeDictate]);
    XCTAssertTrue([SPTextEditPolicy purposeCountsAsDictation:SPSessionPurposeTranslate]);
    XCTAssertFalse([SPTextEditPolicy purposeCountsAsDictation:SPSessionPurposeAsk]);
    XCTAssertFalse([SPTextEditPolicy purposeCountsAsDictation:SPSessionPurposeEdit]);
}

#pragma mark Applying an edit

- (void)testApplyPlanFollowsTheSelectionState {
    XCTAssertEqual([SPTextEditPolicy planWithSelectionUnchanged:YES textSettable:YES], SPEditApplyPlanInPlace);
    XCTAssertEqual([SPTextEditPolicy planWithSelectionUnchanged:YES textSettable:NO],
                   SPEditApplyPlanPasteOverSelection);
    XCTAssertEqual([SPTextEditPolicy planWithSelectionUnchanged:NO textSettable:YES], SPEditApplyPlanClipboardOnly);
    XCTAssertEqual([SPTextEditPolicy planWithSelectionUnchanged:NO textSettable:NO], SPEditApplyPlanClipboardOnly);
    XCTAssertEqual([SPTextEditPolicy planAfterFailedInPlaceWithSelectionUnchanged:YES],
                   SPEditApplyPlanPasteOverSelection);
    XCTAssertEqual([SPTextEditPolicy planAfterFailedInPlaceWithSelectionUnchanged:NO], SPEditApplyPlanClipboardOnly);
}

- (void)testSelectionUnchangedChecksFocusTextAndRange {
    NSRange r = NSMakeRange(5, 6);
    NSRange none = NSMakeRange(NSNotFound, 0);
    XCTAssertTrue([SPTextEditPolicy selectionUnchangedSameFocus:YES currentText:@"абв" expectedText:@"абв"
                                                   currentRange:r expectedRange:r]);
    XCTAssertFalse([SPTextEditPolicy selectionUnchangedSameFocus:NO currentText:@"абв" expectedText:@"абв"
                                                    currentRange:r expectedRange:r], @"focus moved");
    XCTAssertFalse([SPTextEditPolicy selectionUnchangedSameFocus:YES currentText:@"абг" expectedText:@"абв"
                                                    currentRange:r expectedRange:r], @"other text selected");
    XCTAssertFalse([SPTextEditPolicy selectionUnchangedSameFocus:YES currentText:@"абв" expectedText:@"абв"
                                                    currentRange:NSMakeRange(6, 6) expectedRange:r],
                   @"same words selected elsewhere");
    XCTAssertTrue([SPTextEditPolicy selectionUnchangedSameFocus:YES currentText:@"абв" expectedText:@"абв"
                                                   currentRange:none expectedRange:r],
                  @"an unreadable range falls back to the text");
    XCTAssertFalse([SPTextEditPolicy selectionUnchangedSameFocus:YES currentText:nil expectedText:@"абв"
                                                    currentRange:r expectedRange:r]);
    XCTAssertFalse([SPTextEditPolicy selectionUnchangedSameFocus:YES currentText:@"" expectedText:@""
                                                    currentRange:r expectedRange:r], @"nothing selected is not a selection");
}

#pragma mark Undo

- (void)testCaretTextMatchUsesUtf16Offsets {
    // "😀" is two UTF-16 units: the caret offset after "a😀" is 3.
    NSString *value = @"a😀 хвост";
    XCTAssertTrue([SPTextEditPolicy caretTextInValue:value selection:NSMakeRange(3, 0) matchesInsertedText:@"a😀"]);
    XCTAssertTrue([SPTextEditPolicy caretTextInValue:value selection:NSMakeRange(3, 0) matchesInsertedText:@"😀"]);
    XCTAssertFalse([SPTextEditPolicy caretTextInValue:value selection:NSMakeRange(2, 0) matchesInsertedText:@"😀"],
                   @"the caret in the middle of a surrogate pair");
    XCTAssertTrue([SPTextEditPolicy caretTextInValue:@"Привет, мир" selection:NSMakeRange(11, 0)
                                  matchesInsertedText:@"Привет, мир"]);
    XCTAssertTrue([SPTextEditPolicy caretTextInValue:@"Привет, мир" selection:NSMakeRange(7, 0)
                                  matchesInsertedText:@"Привет,"]);
}

- (void)testCaretTextMismatchesAreRefused {
    NSString *value = @"Привет, мир";
    XCTAssertFalse([SPTextEditPolicy caretTextInValue:value selection:NSMakeRange(11, 0) matchesInsertedText:@"Мир"],
                   @"case differs");
    XCTAssertFalse([SPTextEditPolicy caretTextInValue:value selection:NSMakeRange(11, 3) matchesInsertedText:@"мир"],
                   @"a selection is not a caret");
    XCTAssertFalse([SPTextEditPolicy caretTextInValue:value selection:NSMakeRange(2, 0) matchesInsertedText:@"Привет, мир"],
                   @"the caret is before the end of the text");
    XCTAssertFalse([SPTextEditPolicy caretTextInValue:value selection:NSMakeRange(99, 0) matchesInsertedText:@"мир"],
                   @"caret beyond the value");
    XCTAssertFalse([SPTextEditPolicy caretTextInValue:value selection:NSMakeRange(NSNotFound, 0) matchesInsertedText:@"мир"]);
    XCTAssertFalse([SPTextEditPolicy caretTextInValue:nil selection:NSMakeRange(0, 0) matchesInsertedText:@"мир"]);
    XCTAssertFalse([SPTextEditPolicy caretTextInValue:value selection:NSMakeRange(11, 0) matchesInsertedText:@""],
                   @"an empty insertion has nothing to undo");
    XCTAssertFalse([SPTextEditPolicy caretTextInValue:value selection:NSMakeRange(11, 0) matchesInsertedText:nil]);
    // The user typed after the insertion: the text before the caret differs.
    XCTAssertFalse([SPTextEditPolicy caretTextInValue:@"Привет, мир!" selection:NSMakeRange(12, 0)
                                    matchesInsertedText:@"Привет, мир"]);
}

- (void)testUndoVerdictOrderAndTimeWindow {
    NSDate *now = [NSDate dateWithTimeIntervalSince1970:1000000];
    NSDate *(^ago)(NSTimeInterval) = ^NSDate *(NSTimeInterval s) { return [now dateByAddingTimeInterval:-s]; };
    XCTAssertEqual([SPTextEditPolicy undoVerdictForRecordExists:YES insertedAt:ago(5) now:now sameFocus:YES caretTextMatches:YES],
                   SPUndoVerdictAllowed);
    XCTAssertEqual([SPTextEditPolicy undoVerdictForRecordExists:YES insertedAt:ago(120) now:now sameFocus:YES caretTextMatches:YES],
                   SPUndoVerdictAllowed, @"the window is inclusive: exactly two minutes");
    XCTAssertEqual([SPTextEditPolicy undoVerdictForRecordExists:YES insertedAt:ago(120.5) now:now sameFocus:YES caretTextMatches:YES],
                   SPUndoVerdictExpired);
    XCTAssertEqual([SPTextEditPolicy undoVerdictForRecordExists:YES insertedAt:ago(-30) now:now sameFocus:YES caretTextMatches:YES],
                   SPUndoVerdictExpired, @"an insertion dated in the future (clock change) is not trusted");
    XCTAssertEqual([SPTextEditPolicy undoVerdictForRecordExists:YES insertedAt:ago(5) now:now sameFocus:NO caretTextMatches:YES],
                   SPUndoVerdictFocusChanged);
    XCTAssertEqual([SPTextEditPolicy undoVerdictForRecordExists:YES insertedAt:ago(5) now:now sameFocus:YES caretTextMatches:NO],
                   SPUndoVerdictTextMismatch);
    XCTAssertEqual([SPTextEditPolicy undoVerdictForRecordExists:NO insertedAt:nil now:now sameFocus:YES caretTextMatches:YES],
                   SPUndoVerdictNothingRecorded);
    XCTAssertEqual([SPTextEditPolicy undoVerdictForRecordExists:YES insertedAt:nil now:now sameFocus:YES caretTextMatches:YES],
                   SPUndoVerdictNothingRecorded);
    // Expiry wins over a moved focus, focus wins over the text.
    XCTAssertEqual([SPTextEditPolicy undoVerdictForRecordExists:YES insertedAt:ago(500) now:now sameFocus:NO caretTextMatches:NO],
                   SPUndoVerdictExpired);
    XCTAssertEqual([SPTextEditPolicy undoVerdictForRecordExists:YES insertedAt:ago(5) now:now sameFocus:NO caretTextMatches:NO],
                   SPUndoVerdictFocusChanged);
    XCTAssertEqual(SPUndoWindowSeconds, 120.0);
}

- (void)testUndoReplacementIsTheOriginalOfAnEditElseNothing {
    XCTAssertEqualObjects([SPTextEditPolicy undoReplacementForOriginalText:nil], @"");
    XCTAssertEqualObjects([SPTextEditPolicy undoReplacementForOriginalText:@""], @"");
    XCTAssertEqualObjects([SPTextEditPolicy undoReplacementForOriginalText:@"Исходный текст"], @"Исходный текст");
}

- (void)testBackspaceCountIsPerPerceivedCharacter {
    XCTAssertEqual([SPTextEditPolicy backspaceCountForText:@"привет"], 6u);
    XCTAssertEqual([SPTextEditPolicy backspaceCountForText:@""], 0u);
    XCTAssertEqual([SPTextEditPolicy backspaceCountForText:@"a😀"], 2u, @"3 UTF-16 units, 2 key presses");
    XCTAssertEqual([SPTextEditPolicy backspaceCountForText:@"👨‍👩‍👧"], 1u, @"a ZWJ family is one character");
    XCTAssertEqual([SPTextEditPolicy backspaceCountForText:@"е́"], 1u, @"a combining accent");
    XCTAssertEqual([SPTextEditPolicy backspaceCountForText:@"a\nb"], 3u);
}

#pragma mark Re-paste

- (void)testRepastePrefersTheLastDictationOfThisRun {
    NSArray *history = @[ @{@"status" : @"ok", @"text" : @"из истории"} ];
    XCTAssertEqualObjects([SPTextEditPolicy repasteTextWithLastDictation:@"только что" historyRows:history],
                          @"только что");
}

- (void)testRepasteFallsBackToTheNewestSuccessfulHistoryRow {
    NSArray *history = @[
        @{@"status" : @"error", @"text" : @""},
        @{@"status" : @"cancelled", @"text" : @"отменено"},
        @{@"status" : @"ok", @"text" : @"  \n "},
        @{@"status" : @"ok", @"text" : @"вторая"},
        @{@"status" : @"ok", @"text" : @"третья"},
    ];
    XCTAssertEqualObjects([SPTextEditPolicy repasteTextWithLastDictation:nil historyRows:history], @"вторая");
    XCTAssertEqualObjects([SPTextEditPolicy repasteTextWithLastDictation:@"" historyRows:history], @"вторая");
    XCTAssertEqualObjects([SPTextEditPolicy repasteTextWithLastDictation:@"  " historyRows:history], @"вторая");
}

- (void)testRepasteWithNothingToPaste {
    XCTAssertNil([SPTextEditPolicy repasteTextWithLastDictation:nil historyRows:nil]);
    XCTAssertNil([SPTextEditPolicy repasteTextWithLastDictation:nil historyRows:@[]]);
    XCTAssertNil([SPTextEditPolicy repasteTextWithLastDictation:nil historyRows:@[ @{@"status" : @"error"} ]]);
    XCTAssertNil([SPTextEditPolicy repasteTextWithLastDictation:nil historyRows:@[ @{@"text" : @"без статуса"} ]]);
}

@end
