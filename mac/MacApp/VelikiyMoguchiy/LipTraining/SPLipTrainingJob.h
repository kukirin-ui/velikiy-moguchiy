#import <Foundation/Foundation.h>
#import "SPLipTrainingPolicy.h"

NS_ASSUME_NONNULL_BEGIN

/// Runs lipread/train_on_me.py for «Обучить на мне»: short commands (scan,
/// cancel, rollback) and the long background job. The job is a Python process
/// of the lipread checkout (`lips.service_dir`, as the lips service); it loads
/// no model itself and runs every model step under tools/mem_guard.py. It is
/// started with VELIKIY_MOGUCHIY_APP_JOB=train-on-me, the one allowance R11
/// makes for ML on the Mac, so only this user-initiated job gets it. The job
/// outlives the app; its progress is lips_training/status.json in the app's
/// data directory, which -readStatus reads again after a relaunch.
@interface SPLipTrainingJob : NSObject

+ (instancetype)sharedJob;

/// Runs `scan` off the main thread. The completion runs on the main queue with
/// the decoded JSON, or with nil and a short message for the user.
- (void)scanWithCompletion:(void (^)(NSDictionary *_Nullable scan, NSString *_Nullable error))completion;

/// Starts the background job; the completion (main queue) gets nil once it is
/// launched, or a message why it is not.
- (void)startMode:(SPLipTrainingMode)mode completion:(void (^)(NSString *_Nullable error))completion;

/// Asks the running job to stop (it stops the current step through the guard
/// and installs nothing).
- (void)cancelWithCompletion:(void (^)(NSString *_Nullable error))completion;

/// «Вернуть прежнюю модель»: swaps the installed and the previous model.
- (void)rollbackWithCompletion:(void (^)(NSDictionary *_Nullable reply, NSString *_Nullable error))completion;

/// lips_training/status.json, with a dead "running" job read as failed. Small
/// file, read on the calling thread; nil when no job ever ran.
- (nullable NSDictionary *)readStatus;

@end

NS_ASSUME_NONNULL_END
