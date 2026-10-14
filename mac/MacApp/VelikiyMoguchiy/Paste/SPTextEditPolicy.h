#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// What a dictation session is for. The raw values are the codes of
/// sp_core_set_next_session_purpose (velikiy-moguchiy-core modes::SessionPurpose).
typedef NS_ENUM(uint8_t, SPSessionPurpose) {
    SPSessionPurposeDictate = 0,
    SPSessionPurposeTranslate = 1,
    SPSessionPurposeAsk = 2,
    SPSessionPurposeEdit = 3,
};

/// A selection longer than this is not edited (a cut-off text would replace the
/// whole original); the session behaves like Ask instead.
extern const NSUInteger SPEditMaxSelectionChars;

/// "Отменить последнюю вставку" works only this long after the insertion.
extern const NSTimeInterval SPUndoWindowSeconds;

/// How the result of a voice edit reaches the field.
typedef NS_ENUM(NSInteger, SPEditApplyPlan) {
    /// Set kAXSelectedTextAttribute of the unchanged selection.
    SPEditApplyPlanInPlace = 0,
    /// Cmd+V over the still-active, unchanged selection.
    SPEditApplyPlanPasteOverSelection,
    /// The selection changed or cannot be checked: the clipboard only.
    SPEditApplyPlanClipboardOnly,
};

typedef NS_ENUM(NSInteger, SPUndoVerdict) {
    SPUndoVerdictAllowed = 0,
    SPUndoVerdictNothingRecorded,
    SPUndoVerdictExpired,
    SPUndoVerdictFocusChanged,
    SPUndoVerdictTextMismatch,
};

/// Pure rules of the voice edit, "undo last insertion" and "paste last again"
/// features (no Accessibility, no UI), so they can be unit-tested.
@interface SPTextEditPolicy : NSObject

#pragma mark Purpose

/// The purpose a session really gets. Edit needs a selection that is not blank
/// and not longer than SPEditMaxSelectionChars; without one it is an Ask (the
/// answer goes to the clipboard, nothing is ever pasted). Other purposes pass
/// through.
+ (SPSessionPurpose)effectivePurposeForRequested:(SPSessionPurpose)requested
                                    selectedText:(nullable NSString *)selectedText;

/// Whether the purpose ends with text inserted into the field (an Ask answer
/// goes to the clipboard only).
+ (BOOL)purposeInsertsText:(SPSessionPurpose)purpose;

/// Whether the purpose's text counts as "the last dictation" for re-pasting.
+ (BOOL)purposeCountsAsDictation:(SPSessionPurpose)purpose;

#pragma mark Applying an edit

/// In place when the selection is unchanged and its text can be set; a paste
/// over it when unchanged but not settable; otherwise the clipboard.
+ (SPEditApplyPlan)planWithSelectionUnchanged:(BOOL)unchanged textSettable:(BOOL)textSettable;

/// The plan after the in-place write failed or could not be verified.
+ (SPEditApplyPlan)planAfterFailedInPlaceWithSelectionUnchanged:(BOOL)unchanged;

/// The selection is the one captured at the trigger: same focused element, the
/// same selected text and, when both ranges are known (location != NSNotFound),
/// the same range.
+ (BOOL)selectionUnchangedSameFocus:(BOOL)sameFocus
                       currentText:(nullable NSString *)currentText
                      expectedText:(nullable NSString *)expectedText
                      currentRange:(NSRange)currentRange
                     expectedRange:(NSRange)expectedRange;

#pragma mark Undo

/// The text right before the caret (UTF-16 offsets, as Accessibility reports
/// them) is exactly `inserted` and nothing is selected.
+ (BOOL)caretTextInValue:(nullable NSString *)value
               selection:(NSRange)selection
           matchesInsertedText:(nullable NSString *)inserted;

/// Whether the insertion made at `insertedAt` can still be taken back at `now`.
/// The checks run in order: a record exists, it is at most SPUndoWindowSeconds
/// old, the focus is on the same element, the caret text matches.
+ (SPUndoVerdict)undoVerdictForRecordExists:(BOOL)exists
                                 insertedAt:(nullable NSDate *)insertedAt
                                        now:(NSDate *)now
                                  sameFocus:(BOOL)sameFocus
                           caretTextMatches:(BOOL)caretTextMatches;

/// What takes the inserted text's place on undo: the original selection for an
/// edit, nothing for a dictation.
+ (NSString *)undoReplacementForOriginalText:(nullable NSString *)originalText;

/// Number of key presses that delete `text` with Backspace (one per user-
/// perceived character, so an emoji or a combined letter counts once).
+ (NSUInteger)backspaceCountForText:(NSString *)text;

#pragma mark Re-paste

/// The text "Вставить последнюю диктовку" pastes: the last dictation of this run
/// when there is one, otherwise the newest successful, non-empty row of the
/// history (`status == "ok"`), otherwise nil. Whitespace-only texts do not count.
+ (nullable NSString *)repasteTextWithLastDictation:(nullable NSString *)lastDictation
                                        historyRows:(nullable NSArray<NSDictionary *> *)historyRows;

@end

NS_ASSUME_NONNULL_END
