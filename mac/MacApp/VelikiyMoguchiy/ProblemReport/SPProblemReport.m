#import "SPProblemReport.h"

static NSString *const kIssueBase = @"https://github.com/zigansh1n/velikiy-moguchiy/issues/new";
static NSString *const kTemplate = @"problem.yml";
/// An option label of the form's "product" dropdown, verbatim.
static NSString *const kProduct = @"Диктовка для macOS (mac/)";

static NSString *replace(NSString *text, NSString *pattern, NSString *templ) {
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                           options:NSRegularExpressionCaseInsensitive
                                                                             error:nil];
    return [regex stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:templ];
}

@implementation SPProblemReport

+ (NSUInteger)maxURLLength {
    return 7500;
}

+ (NSString *)redactedLog:(NSString *)log homeDirectory:(NSString *)homeDirectory {
    NSString *text = log ?: @"";
    // Order matters: secrets inside quotes and key=value pairs go before the
    // quoted-text rule, so a key is never shown as «текст».
    text = replace(text, @"(authorization|bearer|x-api-key)([\"']?\\s*[:=]?\\s*)(bearer\\s+)?[^\\s\"',;}]+",
                   @"$1$2[скрыто]");
    text = replace(text, @"((?:api|access|app|secret|private)[_-]?keys?|token|secret|password|passwd)"
                         @"([\"']?\\s*[:=]\\s*\\[?\\s*[\"']?)[^\\s\"',;\\]}]+",
                   @"$1$2[скрыто]");
    text = replace(text, @"\\b(sk|pk|rk)-[A-Za-z0-9_\\-]{12,}", @"[ключ]");
    text = replace(text, @"\\b[A-Za-z0-9_\\-]{32,}\\b", @"[ключ]");
    text = replace(text, @"[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}", @"[почта]");
    if (homeDirectory.length > 1) {
        text = [text stringByReplacingOccurrencesOfString:homeDirectory withString:@"~"];
    }
    text = replace(text, @"/Users/[^/\\s\"']+", @"/Users/[имя]");
    text = replace(text, @"((?:final text|interim|received|asr_text|said|text|transcript|hypothesis)\\s*[:=]\\s*+)"
                         @"(?![\\[\\d])[^\\n]+",
                   @"$1[текст]");
    text = replace(text, @"«[^»\\n]*»", @"«[текст]»");
    text = replace(text, @"\"[^\"\\n]*\"", @"\"[текст]\"");
    return text;
}

+ (NSURL *)urlWithItems:(NSArray<NSURLQueryItem *> *)items {
    // Encoded by hand: NSURLComponents leaves '+' and '&' in values alone, and a
    // log line must never add parameters.
    NSMutableCharacterSet *allowed = [NSCharacterSet.URLQueryAllowedCharacterSet mutableCopy];
    [allowed removeCharactersInString:@"&=+?#"];
    NSMutableArray<NSString *> *pairs = [NSMutableArray array];
    for (NSURLQueryItem *item in items) {
        [pairs addObject:[NSString stringWithFormat:@"%@=%@", item.name,
                          [item.value stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @""]];
    }
    return [NSURL URLWithString:[NSString stringWithFormat:@"%@?%@", kIssueBase, [pairs componentsJoinedByString:@"&"]]];
}

+ (NSURL *)issueURLWithAppVersion:(NSString *)appVersion
                           system:(NSString *)system
                         provider:(NSString *)provider
                              log:(NSString *)log {
    NSMutableArray<NSString *> *lines = [[(log ?: @"") componentsSeparatedByString:@"\n"] mutableCopy];
    BOOL trimmed = NO;
    while (YES) {
        NSString *body = [lines componentsJoinedByString:@"\n"];
        if (trimmed) body = [@"… (начало лога не поместилось)\n" stringByAppendingString:body];
        NSURL *url = [self urlWithItems:@[
            [NSURLQueryItem queryItemWithName:@"template" value:kTemplate],
            [NSURLQueryItem queryItemWithName:@"product" value:kProduct],
            [NSURLQueryItem queryItemWithName:@"version" value:appVersion ?: @""],
            [NSURLQueryItem queryItemWithName:@"system" value:system ?: @""],
            [NSURLQueryItem queryItemWithName:@"provider" value:provider ?: @""],
            [NSURLQueryItem queryItemWithName:@"log" value:body],
        ]];
        if (url.absoluteString.length <= self.maxURLLength || lines.count == 0) return url;
        [lines removeObjectAtIndex:0];
        trimmed = YES;
    }
}

@end
