#import <Foundation/Foundation.h>

/// What the 🌐 / Fn key does besides dictation (System Settings → Keyboard →
/// "Press 🌐 key to"), read from com.apple.HIToolbox AppleFnUsageType: 0 does
/// nothing, 1 changes the input source, 2 shows Emoji & Symbols, 3 starts
/// Dictation. -1 when the Mac has never stored a choice.
NSInteger SPFnUsageType(void);

/// "переключает раскладку" for a usage type that fires together with an Fn
/// trigger; nil when the key does nothing else or the choice is unknown.
NSString *SPFnUsageConflict(NSInteger usageType);

/// The explanation for an Fn trigger whose key also `conflict`s ("переключает раскладку").
NSString *SPFnConflictExplanation(NSString *conflict);

/// System Settings → Keyboard, where "Press 🌐 key to" is chosen.
extern NSString *const SPKeyboardSettingsURL;

/// The trigger the recorder takes from one key press, or a reason it refuses it.
@interface SPRecordedTrigger : NSObject
/// A `hotkey.trigger_key` value ("right_command", "96", "command+shift+49"); nil when refused.
@property (nonatomic, readonly, copy) NSString *value;
/// Why the key cannot start dictation, in Russian; nil when accepted.
@property (nonatomic, readonly, copy) NSString *refusal;

/// A modifier pressed and released alone (keyCode of the FlagsChanged event).
+ (instancetype)triggerForModifierKeyCode:(NSInteger)keyCode;

/// A key-down: function keys are taken as they are, any other key only with
/// ⌘, ⌥ or ⌃, because a trigger swallows its key and a typing key would stop typing.
+ (instancetype)triggerForKeyCode:(NSInteger)keyCode modifierFlags:(NSUInteger)flags;
@end
