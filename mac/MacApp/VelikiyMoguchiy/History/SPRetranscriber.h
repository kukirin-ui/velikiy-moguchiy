#import <Foundation/Foundation.h>

/// Posted on the main queue when a re-transcription starts or finishes.
extern NSNotificationName const SPRetranscriptionStateDidChangeNotification;

/// Outcome of one re-transcription run.
@interface SPRetranscriptionResult : NSObject
/// "ok" (text recognized), "empty" (no speech) or "error".
@property (nonatomic, copy) NSString *status;
@property (nonatomic, copy) NSString *text;
/// Stored reason, see +[SPHistoryManager errorReasonWithSummary:providerMessage:].
@property (nonatomic, copy) NSString *error;
@end

/// Re-runs a stored recording through the bundled `velikiy-moguchiy-cli transcribe` (the same
/// Qwen Omni instructions the app uses) off the main thread and writes the
/// outcome back to the history.
@interface SPRetranscriber : NSObject

+ (instancetype)sharedRetranscriber;

- (BOOL)isRunningForSessionId:(int64_t)sessionId;

/// `session` is a history row (`id`, `audio_path`, `app_bundle_id`, `text`).
/// Returns NO when the session is already being re-transcribed. On success the
/// row is updated (a failure only changes a row that has no text of its own)
/// and `completion` runs on the main queue.
- (BOOL)retranscribeSession:(NSDictionary *)session
                 completion:(void (^)(SPRetranscriptionResult *result))completion;

#pragma mark - Pure helpers (unit tested)

/// Whether a dictation that just ended should be re-transcribed automatically:
/// it failed, its recording is at least half a second long and the user allows it.
+ (BOOL)shouldAutoRetryForStatus:(NSString *)status
                      durationMs:(NSInteger)durationMs
                     audioExists:(BOOL)audioExists
                         enabled:(BOOL)enabled;

/// Arguments of `velikiy-moguchiy-cli` for a recording; `--app` only when the bundle id is known.
+ (NSArray<NSString *> *)cliArgumentsForAudioPath:(NSString *)audioPath
                                      appBundleId:(NSString *)appBundleId;

/// `environment` with Homebrew's directories appended to PATH so the CLI finds ffmpeg.
+ (NSDictionary<NSString *, NSString *> *)childEnvironmentFrom:(NSDictionary<NSString *, NSString *> *)environment;

/// Turns the CLI's stderr into (summary, provider message): the last
/// "error: …" line is the provider message, the summary is a short Russian
/// classification of it.
+ (NSString *)errorReasonForCliStderr:(NSString *)stderrText;

/// Short Russian classification of a provider error message.
+ (NSString *)summaryForProviderMessage:(NSString *)message;

@end
