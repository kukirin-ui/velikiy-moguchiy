#import <Foundation/Foundation.h>

/// CSV in the dialect Russian-locale Excel opens without the import wizard:
/// `;` between fields (the list separator there; a comma would leave everything
/// in one column) and a decimal comma in numbers.
@interface SPDictationsCSV : NSObject

+ (NSString *)headerLine;

/// One CRLF-terminated row. `durationMs` is written in seconds with one decimal
/// and a comma as the decimal mark.
+ (NSString *)rowWithDate:(NSString *)date
               durationMs:(double)durationMs
                   status:(NSString *)status
                     text:(NSString *)text
                     file:(NSString *)file;

/// Quote a field: wrapped in double quotes, inner quotes doubled.
+ (NSString *)quotedField:(NSString *)value;

@end
