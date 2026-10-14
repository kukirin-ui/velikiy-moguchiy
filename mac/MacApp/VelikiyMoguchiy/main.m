#import <Cocoa/Cocoa.h>
#import "SPLocalization.h"
#import "SPClipboardManager.h"

/// Bundle identifier of builds from before the rename (inherited from koe).
static NSString *const SPLegacyBundleIdentifier = @"nz.owo.koe";

/// Preferences of builds from before the rename live under the old bundle
/// identifier and partly under old key names. Copy them once, without
/// overwriting anything already set, so the interface language, the chosen
/// microphone and "don't remind again" answers survive the rename.
static void SPImportLegacyPreferences(NSUserDefaults *defaults) {
    NSString *const importedKey = @"SPLegacyPreferencesImported";
    if ([defaults boolForKey:importedKey]) return;
    NSString *bundleIdentifier = [NSBundle mainBundle].bundleIdentifier;
    NSDictionary<NSString *, id> *legacy = [defaults persistentDomainForName:SPLegacyBundleIdentifier];
    NSDictionary<NSString *, id> *current =
        bundleIdentifier.length > 0 ? [defaults persistentDomainForName:bundleIdentifier] : nil;
    NSString *const legacyDontRemindPrefix = @"KoePermissionDontRemind_";
    [legacy enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
        NSString *renamed = key;
        if ([key isEqualToString:@"KoeInterfaceLanguage"]) {
            renamed = SPLocalizationLanguageKey;
        } else if ([key hasPrefix:legacyDontRemindPrefix]) {
            renamed = [@"SPPermissionDontRemind_"
                stringByAppendingString:[key substringFromIndex:legacyDontRemindPrefix.length]];
        }
        if (current[renamed] == nil) [defaults setObject:value forKey:renamed];
    }];
    [defaults setBool:YES forKey:importedKey];
}

int main(int argc, const char *argv[]) {
    // Disposable pasteboard reader (clipboard backup runs in a child of this
    // executable so a stuck promised flavor cannot hang the app). Must come
    // before anything touches AppKit state.
    int childStatus = [SPClipboardManager runSnapshotChildIfRequestedWithArgc:argc argv:argv];
    if (childStatus >= 0) return childStatus;

    @autoreleasepool {
        // Make AppKit's own strings (Edit menu, alert buttons) follow the app language too.
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        SPImportLegacyPreferences(defaults);
        NSString *language = [defaults stringForKey:SPLocalizationLanguageKey];
        if (language.length == 0) language = @"ru";
        if ([language caseInsensitiveCompare:@"system"] == NSOrderedSame) {
            [defaults removeObjectForKey:@"AppleLanguages"];
        } else {
            [defaults setObject:@[language] forKey:@"AppleLanguages"];
        }

        NSApplication *app = [NSApplication sharedApplication];
        // AppDelegate is set via Info.plist NSPrincipalClass + NSMainNibFile,
        // or we set it manually here.
        // Load the delegate class
        Class delegateClass = NSClassFromString(@"SPAppDelegate");
        if (delegateClass) {
            id delegate = [[delegateClass alloc] init];
            [app setDelegate:delegate];
        }
        [app run];
    }
    return 0;
}
