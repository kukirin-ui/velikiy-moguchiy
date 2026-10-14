#import <Foundation/Foundation.h>

/// What to call a trigger in a sentence ("Держите %@ и говорите") for a
/// `hotkey.*_key` config value: "Fn", "правый ⌘", "F5". Nil for a value it
/// cannot name (a recorded combo, an unknown key).
NSString *SPHotkeyShortName(NSString *configValue);
