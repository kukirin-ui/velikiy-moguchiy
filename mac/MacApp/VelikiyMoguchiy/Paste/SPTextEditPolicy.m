#import "SPTextEditPolicy.h"

const NSUInteger SPEditMaxSelectionChars = 12000;
const NSTimeInterval SPUndoWindowSeconds = 120.0;

static BOOL isBlank(NSString *text) {
    return [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length == 0;
}

@implementation SPTextEditPolicy

+ (SPSessionPurpose)effectivePurposeForRequested:(SPSessionPurpose)requested
                                    selectedText:(NSString *)selectedText {
    if (requested != SPSessionPurposeEdit) return requested;
    if (selectedText.length == 0 || isBlank(selectedText)) return SPSessionPurposeAsk;
    if (selectedText.length > SPEditMaxSelectionChars) return SPSessionPurposeAsk;
    return SPSessionPurposeEdit;
}

+ (BOOL)purposeInsertsText:(SPSessionPurpose)purpose {
    return purpose != SPSessionPurposeAsk;
}

+ (BOOL)purposeCountsAsDictation:(SPSessionPurpose)purpose {
    return purpose == SPSessionPurposeDictate || purpose == SPSessionPurposeTranslate;
}

+ (SPEditApplyPlan)planWithSelectionUnchanged:(BOOL)unchanged textSettable:(BOOL)textSettable {
    if (!unchanged) return SPEditApplyPlanClipboardOnly;
    return textSettable ? SPEditApplyPlanInPlace : SPEditApplyPlanPasteOverSelection;
}

+ (SPEditApplyPlan)planAfterFailedInPlaceWithSelectionUnchanged:(BOOL)unchanged {
    return unchanged ? SPEditApplyPlanPasteOverSelection : SPEditApplyPlanClipboardOnly;
}

+ (BOOL)selectionUnchangedSameFocus:(BOOL)sameFocus
                       currentText:(NSString *)currentText
                      expectedText:(NSString *)expectedText
                      currentRange:(NSRange)currentRange
                     expectedRange:(NSRange)expectedRange {
    if (!sameFocus) return NO;
    if (expectedText.length == 0 || ![currentText isEqualToString:expectedText]) return NO;
    if (currentRange.location != NSNotFound && expectedRange.location != NSNotFound) {
        return NSEqualRanges(currentRange, expectedRange);
    }
    return YES;
}

+ (BOOL)caretTextInValue:(NSString *)value
               selection:(NSRange)selection
     matchesInsertedText:(NSString *)inserted {
    if (value == nil || inserted.length == 0) return NO;
    if (selection.location == NSNotFound || selection.length != 0) return NO;
    if (selection.location > value.length || selection.location < inserted.length) return NO;
    NSRange before = NSMakeRange(selection.location - inserted.length, inserted.length);
    return [[value substringWithRange:before] isEqualToString:inserted];
}

+ (SPUndoVerdict)undoVerdictForRecordExists:(BOOL)exists
                                 insertedAt:(NSDate *)insertedAt
                                        now:(NSDate *)now
                                  sameFocus:(BOOL)sameFocus
                           caretTextMatches:(BOOL)caretTextMatches {
    if (!exists || !insertedAt) return SPUndoVerdictNothingRecorded;
    NSTimeInterval age = [now timeIntervalSinceDate:insertedAt];
    if (age < 0 || age > SPUndoWindowSeconds) return SPUndoVerdictExpired;
    if (!sameFocus) return SPUndoVerdictFocusChanged;
    if (!caretTextMatches) return SPUndoVerdictTextMismatch;
    return SPUndoVerdictAllowed;
}

+ (NSString *)undoReplacementForOriginalText:(NSString *)originalText {
    return originalText ?: @"";
}

+ (NSUInteger)backspaceCountForText:(NSString *)text {
    __block NSUInteger count = 0;
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                             options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *s, NSRange r, NSRange er, BOOL *stop) {
        count += 1;
    }];
    return count;
}

+ (NSString *)repasteTextWithLastDictation:(NSString *)lastDictation
                               historyRows:(NSArray<NSDictionary *> *)historyRows {
    if (lastDictation.length > 0 && !isBlank(lastDictation)) return lastDictation;
    for (NSDictionary *row in historyRows) {
        NSString *status = row[@"status"];
        NSString *text = row[@"text"];
        if (![status isKindOfClass:[NSString class]] || ![status isEqualToString:@"ok"]) continue;
        if (![text isKindOfClass:[NSString class]] || text.length == 0 || isBlank(text)) continue;
        return text;
    }
    return nil;
}

@end
