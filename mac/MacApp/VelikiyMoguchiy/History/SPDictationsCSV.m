#import "SPDictationsCSV.h"

@implementation SPDictationsCSV

+ (NSString *)headerLine {
    return @"date;duration_s;status;text;file\r\n";
}

+ (NSString *)quotedField:(NSString *)value {
    return [NSString stringWithFormat:@"\"%@\"",
            [(value ?: @"") stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""]];
}

+ (NSString *)rowWithDate:(NSString *)date
               durationMs:(double)durationMs
                   status:(NSString *)status
                     text:(NSString *)text
                     file:(NSString *)file {
    // %.1f always uses '.' (no locale), so swap in the decimal comma by hand.
    NSString *seconds = [[NSString stringWithFormat:@"%.1f", durationMs / 1000.0]
        stringByReplacingOccurrencesOfString:@"." withString:@","];
    return [NSString stringWithFormat:@"%@;%@;%@;%@;%@\r\n",
            [self quotedField:date],
            [self quotedField:seconds],
            [self quotedField:status],
            [self quotedField:text],
            [self quotedField:file]];
}

@end
