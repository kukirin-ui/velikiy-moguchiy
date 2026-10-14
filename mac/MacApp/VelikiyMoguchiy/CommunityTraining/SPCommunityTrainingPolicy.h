#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SPCommunityJobState) {
    SPCommunityJobStateIdle = 0,
    SPCommunityJobStateRunning,
    SPCommunityJobStateSending,
    SPCommunityJobStateReadyToSend,
    SPCommunityJobStateDone,
    SPCommunityJobStateError,
    SPCommunityJobStateCancelled,
};

/// Pure decisions and Russian texts of «Помочь обучить» (federated/client/community.py),
/// apart from the processes and the view so they can be unit tested. `status` is the
/// JSON object of `python -m client.community status`; its "job" is the job's status.json.
@interface SPCommunityTrainingPolicy : NSObject

#pragma mark Process

/// `-m client.community <command> [value]`.
+ (NSArray<NSString *> *)argumentsForCommand:(NSString *)command value:(nullable NSString *)value;

/// Shown on an app-only install before the lips environment is set up.
+ (NSString *)installNote;

/// nil when the federated checkout can run the client, else how to set it up.
+ (nullable NSString *)setupProblemForFederatedDirectory:(NSString *)federatedDirectory
                                            pythonExists:(BOOL)pythonExists
                                            scriptExists:(BOOL)scriptExists;

/// Every line of `output` that is JSON, in order; a JSON `null` line is NSNull.
+ (NSArray *)JSONValuesInOutput:(nullable NSData *)output;
+ (nullable id)lastJSONValueInOutput:(nullable NSData *)output;

/// The status object when `json` looks like one (a dictionary with the flags); "job" is
/// always a dictionary in the result.
+ (nullable NSDictionary *)statusFromJSON:(nullable id)json;

#pragma mark Login

/// {"user_code", "verification_uri"} from the first login line, nil unless the address is
/// https on github.com and the code looks like a device code.
+ (nullable NSDictionary<NSString *, NSString *> *)loginCodeFromJSON:(nullable id)json;

/// @YES / @NO from a login result line ({"logged_in": …}), nil for other lines.
+ (nullable NSNumber *)loginResultFromJSON:(nullable id)json error:(NSString *_Nullable *_Nullable)error;

#pragma mark State

+ (NSDictionary *)jobOfStatus:(nullable NSDictionary *)status;
+ (SPCommunityJobState)stateOfStatus:(nullable NSDictionary *)status;
/// running or sending.
+ (BOOL)isActiveStatus:(nullable NSDictionary *)status;
+ (BOOL)flag:(NSString *)key inStatus:(nullable NSDictionary *)status;

/// «Помочь обучить» is enabled: consent, logged in, server configured, no job running, no outbox.
+ (BOOL)canStartWithStatus:(nullable NSDictionary *)status;
/// Why the button is disabled; nil when it is enabled, while a job runs, or without a status.
+ (nullable NSString *)blockerForStatus:(nullable NSDictionary *)status;
/// Login needs the server (it tells the GitHub client id) and is pointless while logged in.
+ (BOOL)canLoginWithStatus:(nullable NSDictionary *)status;

/// The «Что будет отправлено» block is shown: an update waits in the outbox.
+ (BOOL)showsPreviewForStatus:(nullable NSDictionary *)status;
+ (nullable NSDictionary *)previewOfStatus:(nullable NSDictionary *)status;

/// The paused flag: a recent pause/resume the app signalled wins over a status that has
/// not been rewritten since.
+ (BOOL)isPausedStatus:(nullable NSDictionary *)status override:(nullable NSNumber *)override;
+ (double)progressForStatus:(nullable NSDictionary *)status;
/// "Скачивание роликов — 40%", " · на паузе" when paused, "Отправка…" while sending.
+ (NSString *)progressLineForStatus:(nullable NSDictionary *)status paused:(BOOL)paused;
/// "Роликов в задании: 5 · скачано: 3 · отрезков: 120 · с лицом: 98", empty without numbers.
+ (NSString *)detailLineForStatus:(nullable NSDictionary *)status;
/// The job's message for done / error / cancelled / idle (after discard); nil otherwise.
+ (nullable NSString *)resultMessageForStatus:(nullable NSDictionary *)status;

#pragma mark Preview

/// The human summary that opens «Что будет отправлено».
+ (NSString *)previewSummaryForPreview:(NSDictionary *)preview;
/// Summary, then the manifest and the contribution as pretty JSON, then what is not sent.
+ (NSString *)previewTextForPreview:(nullable NSDictionary *)preview;

#pragma mark Texts

+ (NSString *)consentAlertTitle;
+ (NSString *)consentAlertText;

/// "512,0 КБ" (always kilobytes, one decimal, grouped thousands).
+ (NSString *)kilobytesText:(long long)bytes;
/// "1 234 567" with non-breaking spaces.
+ (NSString *)groupedInteger:(long long)value;
/// "48 мин" under an hour, else "1,5 ч".
+ (NSString *)durationText:(double)seconds;
/// "1 ролик", "3 ролика", "5 роликов".
+ (NSString *)count:(long long)n one:(NSString *)one few:(NSString *)few many:(NSString *)many;
+ (NSString *)prettyJSON:(nullable id)object;

@end

NS_ASSUME_NONNULL_END
