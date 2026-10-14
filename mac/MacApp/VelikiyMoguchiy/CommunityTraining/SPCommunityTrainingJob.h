#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs federated/client/community.py for «Помочь обучить»: `<federated>/.venv/bin/python -m client.community
/// <command>` in the `federated` folder next to the lipread checkout (`lips.service_dir`, as the lips service).
/// Short commands answer one JSON line; `login` streams its lines; `run` is started in the background with
/// VELIKIY_MOGUCHIY_APP_JOB=help-train and outlives the app, its progress read back through `status`.
/// Every completion runs on the main queue.
@interface SPCommunityTrainingJob : NSObject

+ (instancetype)sharedJob;

@property (nonatomic, readonly) NSString *federatedDirectory;

/// nil when the federated checkout can run the client, else a short note how to set it up.
- (nullable NSString *)setupProblem;

/// A short command (`status`, `consent on|off`, `logout`, `pause`, `resume`, `cancel`, `preview`, `send`,
/// `discard`). `json` is the last JSON line it printed (NSNull for `null`), or nil with a message for the user.
- (void)runCommand:(NSString *)command
             value:(nullable NSString *)value
        completion:(void (^)(id _Nullable json, NSString *_Nullable error))completion;

/// `status`, decoded and checked.
- (void)statusWithCompletion:(void (^)(NSDictionary *_Nullable status, NSString *_Nullable error))completion;

/// GitHub device login. `codeHandler` gets the code to show and the page to open; `completion` gets the result.
/// A login already in progress is cancelled first.
- (void)loginWithCodeHandler:(void (^)(NSString *userCode, NSURL *verificationURL))codeHandler
                  completion:(void (^)(BOOL loggedIn, NSString *_Nullable error))completion;
- (void)cancelLogin;
@property (nonatomic, readonly) BOOL loginInProgress;

/// Starts `run` in the background; the completion gets nil once it is launched, or why it is not.
- (void)startWithCompletion:(void (^)(NSString *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
