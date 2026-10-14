#import "SPAppUpdateChecker.h"
#import "SPUpdatePolicy.h"

static NSString *const kReleasesAPI = @"https://api.github.com/repos/zigansh1n/velikiy-moguchiy/releases?per_page=20";
static NSString *const kReleasesPage = @"https://github.com/zigansh1n/velikiy-moguchiy/releases/";
static NSString *const kLastCheckKey = @"SPAppUpdateLastCheck";
static NSString *const kVersionKey = @"SPAppUpdateVersion";
static NSString *const kPageKey = @"SPAppUpdatePage";

@implementation SPAppUpdateChecker

+ (NSString *)currentVersion {
    return NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"0";
}

+ (NSString *)knownNewerVersion {
    NSString *version = [NSUserDefaults.standardUserDefaults stringForKey:kVersionKey];
    if (!version) return nil;
    return [SPUpdatePolicy compareVersion:version toVersion:[self currentVersion]] == NSOrderedDescending ? version : nil;
}

+ (NSURL *)knownReleasePage {
    NSString *page = [NSUserDefaults.standardUserDefaults stringForKey:kPageKey];
    return [page hasPrefix:kReleasesPage] ? [NSURL URLWithString:page] : [NSURL URLWithString:kReleasesPage];
}

+ (void)checkIfDueWithHandler:(void (^)(NSString *, NSURL *, BOOL))handler {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *known = [self knownNewerVersion];
    if (known) handler(known, [self knownReleasePage], NO);
    id last = [defaults objectForKey:kLastCheckKey];
    if (![SPUpdatePolicy isCheckDueWithLastCheck:[last isKindOfClass:[NSDate class]] ? last : nil now:[NSDate date]]) {
        return;
    }
    [defaults setObject:[NSDate date] forKey:kLastCheckKey];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kReleasesAPI]];
    request.timeoutInterval = 30;
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"velikiy-moguchiy" forHTTPHeaderField:@"User-Agent"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        if (status != 200 || !data) {
            NSLog(@"[VelikiyMoguchiy] update check: HTTP %ld %@", (long)status, error.localizedDescription ?: @"");
            return;
        }
        id releases = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSDictionary *newest = [SPUpdatePolicy newestReleaseIn:releases tagPrefix:@"v"];
        NSString *version = [SPUpdatePolicy versionFromTag:newest[@"tag_name"] prefix:@"v"];
        NSString *page = [newest[@"html_url"] isKindOfClass:[NSString class]] ? newest[@"html_url"] : nil;
        if (!version || [SPUpdatePolicy compareVersion:version toVersion:[self currentVersion]] != NSOrderedDescending) {
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL isNew = ![[defaults stringForKey:kVersionKey] isEqualToString:version];
            [defaults setObject:version forKey:kVersionKey];
            if ([page hasPrefix:kReleasesPage]) [defaults setObject:page forKey:kPageKey];
            NSLog(@"[VelikiyMoguchiy] update check: %@ is available (this build is %@)", version, [self currentVersion]);
            handler(version, [self knownReleasePage], isNew);
        });
    }] resume];
}

@end
