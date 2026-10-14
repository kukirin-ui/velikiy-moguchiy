#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Client of the local lip-reading service (lipread/lips_service.py) for
/// the experimental lips mode. The service is a Python process that keeps the
/// model loaded; it is started on demand and exits by itself after
/// `lips.idle_minutes` without clips, which is what frees its memory.
@interface SPLipsService : NSObject

+ (instancetype)sharedService;

/// The lipread checkout the service and «Обучить на мне» run from: `lips.service_dir`,
/// else ~/velikiy-moguchiy/lipread (or an older ~/velikiy-moguchiy/lipread-ru).
+ (NSString *)lipreadDirectory;

/// Starts the process when it is not running and asks it to load the model,
/// so a clip recorded meanwhile does not wait for the load. Non-blocking.
- (void)warmUp;

/// Reads the clip by the lips. `context` is a hint for the rescoring (the
/// app being dictated into). The completion runs on the main queue with the
/// service's reply, or with a short message for the user.
- (void)transcribeClipAtPath:(NSString *)path
                     context:(nullable NSString *)context
                  completion:(void (^)(NSDictionary *_Nullable reply, NSString *_Nullable errorMessage))completion;

/// Stops a process this app started (app quitting).
- (void)shutdown;

@end

NS_ASSUME_NONNULL_END
