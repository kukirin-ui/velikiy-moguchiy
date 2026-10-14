#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The four Omni output modes in cycling order: raw, light, structured, formal.
NSArray<NSString *> *SPOutputModeIds(void);

/// The mode after `mode` in the cycle; an unknown or empty value counts as raw.
NSString *SPNextOutputMode(NSString *_Nullable mode);

/// A known mode id, defaulting to raw.
NSString *SPNormalizedOutputMode(NSString *_Nullable mode);

/// Russian name shown in menus and notifications.
NSString *SPOutputModeTitle(NSString *_Nullable mode);

/// One letter for the overlay pill: R, L, S, F.
NSString *SPOutputModeLetter(NSString *_Nullable mode);

NS_ASSUME_NONNULL_END
