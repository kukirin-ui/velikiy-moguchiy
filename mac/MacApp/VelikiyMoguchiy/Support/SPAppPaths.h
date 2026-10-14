#import <Foundation/Foundation.h>

/// The app's data directory (config.yaml, keys, history, recordings, models):
/// ~/.velikiy-moguchiy, or ~/.koe from before the rename while only that one
/// exists, so existing settings and API keys survive. Must agree with
/// velikiy_moguchiy_asr::app_dir in the Rust core, which reads the same config.
/// Never create the new directory by hand: that would hide the legacy one.
static inline NSString *SPAppDataDirectoryInHome(NSString *home) {
    NSString *current = [home stringByAppendingPathComponent:@".velikiy-moguchiy"];
    NSString *legacy = [home stringByAppendingPathComponent:@".koe"];
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL legacyIsDirectory = NO;
    if (![fm fileExistsAtPath:current] &&
        [fm fileExistsAtPath:legacy isDirectory:&legacyIsDirectory] && legacyIsDirectory) {
        return legacy;
    }
    return current;
}

static inline NSString *SPAppDataDirectory(void) {
    return SPAppDataDirectoryInHome(NSHomeDirectory());
}

/// A file or folder inside SPAppDataDirectory().
static inline NSString *SPAppDataPath(NSString *relativePath) {
    return [SPAppDataDirectory() stringByAppendingPathComponent:relativePath];
}
