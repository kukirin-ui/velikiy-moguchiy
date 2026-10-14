#import "SPHotkeyNames.h"

NSString *SPHotkeyShortName(NSString *configValue) {
    NSString *value = [[configValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        lowercaseString];
    NSDictionary<NSString *, NSString *> *names = @{
        @"fn" : @"Fn",
        @"left_option" : @"левый ⌥",
        @"right_option" : @"правый ⌥",
        @"left_command" : @"левый ⌘",
        @"right_command" : @"правый ⌘",
        @"left_control" : @"левый ⌃",
        @"right_control" : @"правый ⌃",
    };
    if (names[value]) return names[value];
    // Function keys by macOS keycode, the ones a trigger is usually put on.
    NSDictionary<NSString *, NSString *> *functionKeys = @{
        @"122" : @"F1", @"120" : @"F2", @"99" : @"F3", @"118" : @"F4", @"96" : @"F5", @"97" : @"F6",
        @"98" : @"F7", @"100" : @"F8", @"101" : @"F9", @"109" : @"F10", @"103" : @"F11", @"111" : @"F12",
        @"105" : @"F13", @"107" : @"F14", @"113" : @"F15",
    };
    return functionKeys[value];
}
