#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// What a failed dictation was about, read from the provider's (English) message.
typedef NS_ENUM(NSInteger, SPErrorKind) {
    SPErrorKindUnknown,
    SPErrorKindNoKey,
    SPErrorKindBadKey,
    SPErrorKindNoBalance,
    SPErrorKindRateLimit,
    SPErrorKindAccessDenied,
    SPErrorKindLocalModel,
    SPErrorKindMicrophone,
    SPErrorKindTimeout,
    SPErrorKindService,
    SPErrorKindNetwork,
};

/// Where a click on the error notification leads.
typedef NS_ENUM(NSInteger, SPErrorAction) {
    SPErrorActionNone,
    /// Settings → Распознавание.
    SPErrorActionAsrSettings,
    /// Settings → Языковая модель.
    SPErrorActionLlmSettings,
    /// System Settings → Privacy → Microphone.
    SPErrorActionMicrophonePrivacy,
    /// «Последние диктовки», where the recording waits.
    SPErrorActionRecentDictations,
};

/// One error put in words for the user: a few words for the pill, a sentence
/// with what to do for the notification, and a code that ties it to the log.
@interface SPErrorExplanation : NSObject
@property (nonatomic, readonly) SPErrorKind kind;
/// Fits the expanded pill: "Ключ не подходит".
@property (nonatomic, readonly, copy) NSString *shortText;
/// What happened and what to do, in Russian, with no provider text in it.
@property (nonatomic, readonly, copy) NSString *detail;
/// Four hex digits from the provider message: the same message, the same code.
@property (nonatomic, readonly, copy) NSString *code;
@property (nonatomic, readonly) SPErrorAction action;
@end

@interface SPErrorExplainer : NSObject

+ (SPErrorKind)kindForMessage:(nullable NSString *)message;

/// A dictation that failed with the core's error `message`. `recordingKept`:
/// its recording is in «Последние диктовки», so the text may point there.
+ (SPErrorExplanation *)explanationForMessage:(nullable NSString *)message recordingKept:(BOOL)recordingKept;

/// A warning of the core ("LLM correction failed: …"): the dictation went
/// through, only a step on top of it did not. Nil for a warning that needs no words.
+ (nullable SPErrorExplanation *)explanationForWarning:(nullable NSString *)message;

/// An explanation the app words itself (a capture failure, a stuck session).
+ (SPErrorExplanation *)explanationWithKind:(SPErrorKind)kind
                                  shortText:(NSString *)shortText
                                     detail:(NSString *)detail
                                     action:(SPErrorAction)action;

/// The microphone could not be used; `shortText` says how ("Аудиоустройство отключено").
+ (SPErrorExplanation *)microphoneExplanationWithShortText:(NSString *)shortText;

/// The notification body: the detail, plus the code when the kind is unknown.
+ (NSString *)notificationBodyForExplanation:(SPErrorExplanation *)explanation;

@end

NS_ASSUME_NONNULL_END
