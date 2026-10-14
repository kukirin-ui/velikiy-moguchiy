#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Pure decisions of the experimental lips mode (experimental.lips), kept
/// apart from the camera and the service process so they can be unit tested.
@interface SPLipsPolicy : NSObject

/// The text to insert for a /transcribe reply of lipread/lips_service.py,
/// or nil when there is nothing to insert. The first letter is capitalized
/// like the start of a dictated sentence: the model writes lower case.
+ (nullable NSString *)insertableTextFromServiceReply:(nullable NSDictionary *)reply;

/// Arguments for the service process.
+ (NSArray<NSString *> *)serviceArgumentsWithScript:(NSString *)scriptPath
                                               port:(NSInteger)port
                                        idleMinutes:(double)idleMinutes
                                          parentPid:(pid_t)parentPid;

/// `lips.port` when it is a usable TCP port, else 8766.
+ (NSInteger)portFromConfigValue:(nullable NSString *)value;

/// `lips.idle_minutes` when positive, else 10.
+ (double)idleMinutesFromConfigValue:(nullable NSString *)value;

@end

NS_ASSUME_NONNULL_END
