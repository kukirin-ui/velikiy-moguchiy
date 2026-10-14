#import "SPSelectionEditor.h"
#import <ApplicationServices/ApplicationServices.h>

static const float kAXTimeoutSeconds = 1.5f;

#pragma mark - AX helpers

static AXUIElementRef copyFocusedElement(void) {
    AXUIElementRef systemWide = AXUIElementCreateSystemWide();
    if (!systemWide) return NULL;
    AXUIElementSetMessagingTimeout(systemWide, kAXTimeoutSeconds);
    CFTypeRef focused = NULL;
    AXError err = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute, &focused);
    CFRelease(systemWide);
    if (err != kAXErrorSuccess || !focused) return NULL;
    return (AXUIElementRef)focused;
}

static NSString *copyStringAttribute(AXUIElementRef element, CFStringRef attribute) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, attribute, &value) != kAXErrorSuccess || !value) return nil;
    if (CFGetTypeID(value) != CFStringGetTypeID()) {
        CFRelease(value);
        return nil;
    }
    return (__bridge_transfer NSString *)value;
}

static NSRange copySelectedRange(AXUIElementRef element) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute, &value) != kAXErrorSuccess || !value) {
        return NSMakeRange(NSNotFound, 0);
    }
    CFRange range;
    BOOL ok = CFGetTypeID(value) == AXValueGetTypeID() && AXValueGetValue((AXValueRef)value, kAXValueTypeCFRange, &range);
    CFRelease(value);
    if (!ok || range.location < 0 || range.length < 0) return NSMakeRange(NSNotFound, 0);
    return NSMakeRange((NSUInteger)range.location, (NSUInteger)range.length);
}

static BOOL setSelectedRange(AXUIElementRef element, NSRange range) {
    CFRange cfRange = CFRangeMake((CFIndex)range.location, (CFIndex)range.length);
    AXValueRef value = AXValueCreate(kAXValueTypeCFRange, &cfRange);
    if (!value) return NO;
    AXError err = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute, value);
    CFRelease(value);
    return err == kAXErrorSuccess;
}

static BOOL setSelectedText(AXUIElementRef element, NSString *text) {
    return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute, (__bridge CFTypeRef)text) == kAXErrorSuccess;
}

static BOOL isAttributeSettable(AXUIElementRef element, CFStringRef attribute) {
    Boolean settable = false;
    if (AXUIElementIsAttributeSettable(element, attribute, &settable) != kAXErrorSuccess) return NO;
    return settable;
}

static BOOL documentHasTextAt(AXUIElementRef element, NSString *text, NSUInteger location) {
    NSString *value = copyStringAttribute(element, kAXValueAttribute);
    if (!value || location + text.length > value.length) return NO;
    return [[value substringWithRange:NSMakeRange(location, text.length)] isEqualToString:text];
}

#pragma mark - SPSelectionAnchor

@interface SPSelectionAnchor () {
    AXUIElementRef _element;
}
@property (nonatomic, copy, readwrite) NSString *selectedText;
@property (nonatomic, assign, readwrite) NSRange selectedRange;
@property (nonatomic, assign, readwrite) BOOL textSettable;
@property (nonatomic, assign, readwrite) pid_t pid;
- (AXUIElementRef)element;
@end

@implementation SPSelectionAnchor

- (void)dealloc {
    if (_element) CFRelease(_element);
}

- (AXUIElementRef)element {
    return _element;
}

+ (instancetype)captureFocused {
    AXUIElementRef element = copyFocusedElement();
    if (!element) return nil;
    AXUIElementSetMessagingTimeout(element, kAXTimeoutSeconds);
    NSString *selected = copyStringAttribute(element, kAXSelectedTextAttribute);
    if (selected.length == 0) {
        CFRelease(element);
        return nil;
    }
    SPSelectionAnchor *anchor = [[SPSelectionAnchor alloc] init];
    anchor->_element = element;
    anchor.selectedText = selected;
    anchor.selectedRange = copySelectedRange(element);
    anchor.textSettable = isAttributeSettable(element, kAXSelectedTextAttribute);
    pid_t pid = 0;
    AXUIElementGetPid(element, &pid);
    anchor.pid = pid;
    return anchor;
}

- (BOOL)selectionStillUnchanged {
    AXUIElementRef current = copyFocusedElement();
    if (!current) return NO;
    BOOL same = CFEqual(current, _element);
    NSString *text = same ? copyStringAttribute(current, kAXSelectedTextAttribute) : nil;
    NSRange range = same ? copySelectedRange(current) : NSMakeRange(NSNotFound, 0);
    CFRelease(current);
    return [SPTextEditPolicy selectionUnchangedSameFocus:same
                                             currentText:text
                                            expectedText:self.selectedText
                                            currentRange:range
                                           expectedRange:self.selectedRange];
}

- (BOOL)replaceSelectionWithText:(NSString *)text {
    if (text.length == 0 || !self.textSettable) return NO;
    NSRange range = self.selectedRange;
    if (range.location == NSNotFound) {
        // Without a known place the result cannot be verified.
        NSLog(@"[VelikiyMoguchiy] Edit: the selection range is unknown — no in-place replacement");
        return NO;
    }
    if (!setSelectedText(_element, text)) {
        NSLog(@"[VelikiyMoguchiy] Edit: the field refused the AXSelectedText write");
        return NO;
    }
    if (!documentHasTextAt(_element, text, range.location)) {
        NSLog(@"[VelikiyMoguchiy] Edit: the replacement could not be verified in the document");
        return NO;
    }
    setSelectedRange(_element, NSMakeRange(range.location + text.length, 0));
    NSLog(@"[VelikiyMoguchiy] Edit: replaced %lu chars with %lu chars in place",
          (unsigned long)range.length, (unsigned long)text.length);
    return YES;
}

@end

#pragma mark - SPInsertionRecord

@interface SPInsertionRecord () {
    AXUIElementRef _element;
}
@property (nonatomic, copy, readwrite) NSString *text;
@property (nonatomic, copy, readwrite) NSString *originalText;
@property (nonatomic, strong, readwrite) NSDate *insertedAt;
- (AXUIElementRef)element;
@end

@implementation SPInsertionRecord

- (void)dealloc {
    if (_element) CFRelease(_element);
}

- (AXUIElementRef)element {
    return _element;
}

+ (instancetype)recordWithText:(NSString *)text original:(NSString *)original element:(AXUIElementRef)element {
    if (text.length == 0 || !element) {
        if (element) CFRelease(element);
        return nil;
    }
    SPInsertionRecord *record = [[SPInsertionRecord alloc] init];
    record->_element = element;
    record.text = text;
    record.originalText = original.length > 0 ? original : nil;
    record.insertedAt = [NSDate date];
    return record;
}

+ (instancetype)recordInsertedText:(NSString *)text originalText:(NSString *)originalText {
    return [self recordWithText:text original:originalText element:copyFocusedElement()];
}

+ (instancetype)recordInsertedText:(NSString *)text
                      originalText:(NSString *)originalText
                            anchor:(SPSelectionAnchor *)anchor {
    AXUIElementRef element = [anchor element];
    if (element) CFRetain(element);
    return [self recordWithText:text original:originalText element:element];
}

@end

#pragma mark - SPSelectionEditor

@implementation SPSelectionEditor

+ (BOOL)focusMatchesRecord:(SPInsertionRecord *)record {
    AXUIElementRef current = copyFocusedElement();
    if (!current) return NO;
    BOOL same = [record element] && CFEqual(current, [record element]);
    CFRelease(current);
    return same;
}

+ (SPUndoOutcome)undoInsertion:(SPInsertionRecord *)record
                           now:(NSDate *)now
                       verdict:(SPUndoVerdict *)verdict
                 rangeSelected:(BOOL *)rangeSelected {
    *rangeSelected = NO;
    AXUIElementRef current = record ? copyFocusedElement() : NULL;
    BOOL sameFocus = current && [record element] && CFEqual(current, [record element]);
    NSString *value = sameFocus ? copyStringAttribute(current, kAXValueAttribute) : nil;
    NSRange selection = sameFocus ? copySelectedRange(current) : NSMakeRange(NSNotFound, 0);
    BOOL caretMatches = [SPTextEditPolicy caretTextInValue:value
                                                 selection:selection
                                       matchesInsertedText:record.text];
    *verdict = [SPTextEditPolicy undoVerdictForRecordExists:record != nil
                                                 insertedAt:record.insertedAt
                                                        now:now
                                                  sameFocus:sameFocus
                                           caretTextMatches:caretMatches];
    if (*verdict != SPUndoVerdictAllowed) {
        if (current) CFRelease(current);
        return SPUndoOutcomeNothing;
    }

    NSString *replacement = [SPTextEditPolicy undoReplacementForOriginalText:record.originalText];
    NSRange inserted = NSMakeRange(selection.location - record.text.length, record.text.length);
    SPUndoOutcome outcome = SPUndoOutcomeNeedsKeys;
    if (setSelectedRange(current, inserted)) {
        *rangeSelected = NSEqualRanges(copySelectedRange(current), inserted);
        if (*rangeSelected && setSelectedText(current, replacement)) {
            NSString *after = copyStringAttribute(current, kAXValueAttribute);
            BOOL verified = after && after.length == value.length - inserted.length + replacement.length &&
                            [[after substringToIndex:inserted.location] isEqualToString:[value substringToIndex:inserted.location]] &&
                            (replacement.length == 0 || documentHasTextAt(current, replacement, inserted.location));
            if (verified) {
                setSelectedRange(current, NSMakeRange(inserted.location + replacement.length, 0));
                outcome = SPUndoOutcomeDone;
                *rangeSelected = NO;
            } else if (after && ![after isEqualToString:value]) {
                // The write went through but not as expected: never stack key
                // presses on a document we no longer understand.
                NSLog(@"[VelikiyMoguchiy] Undo: the document changed unexpectedly; leaving it as it is");
                outcome = SPUndoOutcomeDone;
                *rangeSelected = NO;
            } else {
                NSLog(@"[VelikiyMoguchiy] Undo: the AX write left the document unchanged; using key presses");
            }
        }
    }
    CFRelease(current);
    return outcome;
}

@end
