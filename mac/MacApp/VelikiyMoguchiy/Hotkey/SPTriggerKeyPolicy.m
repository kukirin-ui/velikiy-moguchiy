#import "SPTriggerKeyPolicy.h"
#import <AppKit/AppKit.h>

NSInteger SPFnUsageType(void) {
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("AppleFnUsageType"), CFSTR("com.apple.HIToolbox"));
    if (!value) return -1;
    NSInteger type = -1;
    if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        type = [(__bridge NSNumber *)value integerValue];
    }
    CFRelease(value);
    return type;
}

NSString *SPFnUsageConflict(NSInteger usageType) {
    switch (usageType) {
        case 1: return @"переключает раскладку";
        case 2: return @"открывает «Эмодзи и символы»";
        case 3: return @"включает системную диктовку";
        default: return nil;
    }
}

NSString *const SPKeyboardSettingsURL = @"x-apple.systempreferences:com.apple.Keyboard-Settings.extension";

NSString *SPFnConflictExplanation(NSString *conflict) {
    return [NSString stringWithFormat:
        @"Когда вы нажимаете Fn для диктовки, macOS заодно %@. Чтобы не мешало, в Системных настройках → "
        @"Клавиатура выберите «При нажатии клавиши 🌐: Ничего не делать». Или назначьте для диктовки другую "
        @"клавишу, например правый ⌘.",
        conflict];
}

static NSString *const kTypingKeyRefusal =
    @"Эта клавиша нужна для набора текста: назначенная на диктовку, она перестанет печатать. "
    @"Нажмите и отпустите модификатор (например, правый ⌘), нажмите F1–F12 или сочетание с ⌘, ⌥ или ⌃.";

@interface SPRecordedTrigger ()
@property (nonatomic, readwrite, copy) NSString *value;
@property (nonatomic, readwrite, copy) NSString *refusal;
@end

@implementation SPRecordedTrigger

+ (instancetype)acceptedValue:(NSString *)value {
    SPRecordedTrigger *trigger = [[self alloc] init];
    trigger.value = value;
    return trigger;
}

+ (instancetype)refusedWith:(NSString *)reason {
    SPRecordedTrigger *trigger = [[self alloc] init];
    trigger.refusal = reason;
    return trigger;
}

+ (instancetype)triggerForModifierKeyCode:(NSInteger)keyCode {
    switch (keyCode) {
        case 63: return [self acceptedValue:@"fn"];
        case 54: return [self acceptedValue:@"right_command"];
        case 55: return [self acceptedValue:@"left_command"];
        case 58: return [self acceptedValue:@"left_option"];
        case 61: return [self acceptedValue:@"right_option"];
        case 59: return [self acceptedValue:@"left_control"];
        case 62: return [self acceptedValue:@"right_control"];
        case 56:
        case 60:
            return [self refusedWith:@"Shift нужен для заглавных букв. Выберите ⌘, ⌥, ⌃ или Fn."];
        default:
            return [self refusedWith:@"Эту клавишу нельзя назначить. Выберите ⌘, ⌥, ⌃ или Fn."];
    }
}

static BOOL isFunctionKey(NSInteger keyCode) {
    static NSSet<NSNumber *> *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = [NSSet setWithArray:@[ @122, @120, @99, @118, @96, @97, @98, @100, @101, @109, @103, @111,
                                      @105, @107, @113, @106, @64, @79, @80, @90 ]];
    });
    return [keys containsObject:@(keyCode)];
}

+ (instancetype)triggerForKeyCode:(NSInteger)keyCode modifierFlags:(NSUInteger)flags {
    if (keyCode >= 54 && keyCode <= 63) return [self triggerForModifierKeyCode:keyCode];
    BOOL command = (flags & NSEventModifierFlagCommand) != 0;
    BOOL option = (flags & NSEventModifierFlagOption) != 0;
    BOOL control = (flags & NSEventModifierFlagControl) != 0;
    BOOL shift = (flags & NSEventModifierFlagShift) != 0;
    if (!command && !option && !control) {
        // Laptops report F-keys (and arrows) with the Fn flag; a bare F-key is the trigger.
        if (isFunctionKey(keyCode) && !shift) {
            return [self acceptedValue:[NSString stringWithFormat:@"%ld", (long)keyCode]];
        }
        return [self refusedWith:kTypingKeyRefusal];
    }
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (command) [parts addObject:@"command"];
    if (option) [parts addObject:@"option"];
    if (control) [parts addObject:@"control"];
    if (shift) [parts addObject:@"shift"];
    if ((flags & NSEventModifierFlagFunction) != 0 && !isFunctionKey(keyCode)) [parts addObject:@"fn"];
    [parts addObject:[NSString stringWithFormat:@"%ld", (long)keyCode]];
    return [self acceptedValue:[parts componentsJoinedByString:@"+"]];
}

@end
