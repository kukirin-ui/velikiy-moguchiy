#import <Foundation/Foundation.h>
#import "SPTextEditPolicy.h"

NS_ASSUME_NONNULL_BEGIN

/// The focused element and its selection at the moment a voice edit was
/// triggered. Holds a retained AXUIElement.
@interface SPSelectionAnchor : NSObject
@property (nonatomic, copy, readonly) NSString *selectedText;
/// location == NSNotFound when the element does not report its selection range.
@property (nonatomic, assign, readonly) NSRange selectedRange;
@property (nonatomic, assign, readonly) BOOL textSettable;
@property (nonatomic, assign, readonly) pid_t pid;

/// nil when nothing is focused or nothing is selected.
+ (nullable instancetype)captureFocused;

/// Whether the focused element and its selection are still the captured ones
/// (same element, same selected text and, when known, the same range).
- (BOOL)selectionStillUnchanged;

/// Set the selection's text to `text` through Accessibility and verify the
/// document now holds it at the selection's place; the caret ends after it.
/// Call only after selectionStillUnchanged. NO when the write failed or could
/// not be verified (the document may be unchanged).
- (BOOL)replaceSelectionWithText:(NSString *)text;
@end

/// The text the app inserted last, with the field it went into.
@interface SPInsertionRecord : NSObject
@property (nonatomic, copy, readonly) NSString *text;
/// For a voice edit: the text that was selected before (restored on undo).
@property (nonatomic, copy, readonly, nullable) NSString *originalText;
@property (nonatomic, strong, readonly) NSDate *insertedAt;

/// Records `text` as inserted into the element focused right now; nil when
/// nothing is focused.
+ (nullable instancetype)recordInsertedText:(NSString *)text originalText:(nullable NSString *)originalText;
/// Same, for an element that is known (the anchor's element after an edit).
+ (nullable instancetype)recordInsertedText:(NSString *)text
                               originalText:(nullable NSString *)originalText
                                     anchor:(SPSelectionAnchor *)anchor;
@end

typedef NS_ENUM(NSInteger, SPUndoOutcome) {
    /// The inserted text is gone (the original restored for an edit).
    SPUndoOutcomeDone = 0,
    /// Not eligible (see the verdict); nothing was touched.
    SPUndoOutcomeNothing,
    /// Eligible, but Accessibility refused to write: the caller falls back to
    /// key presses. `rangeSelected` tells whether the insertion is selected.
    SPUndoOutcomeNeedsKeys,
};

@interface SPSelectionEditor : NSObject

/// Checks eligibility (age, same element, caret text) and undoes the insertion
/// by replacing its range through Accessibility.
+ (SPUndoOutcome)undoInsertion:(nullable SPInsertionRecord *)record
                           now:(NSDate *)now
                       verdict:(SPUndoVerdict *)verdict
                 rangeSelected:(BOOL *)rangeSelected;

/// Whether the element focused now is the record's (for guarding key presses).
+ (BOOL)focusMatchesRecord:(SPInsertionRecord *)record;
@end

NS_ASSUME_NONNULL_END
