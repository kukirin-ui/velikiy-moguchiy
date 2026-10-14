#import "SPErrorExplainer.h"

@interface SPErrorExplanation ()
@property (nonatomic, readwrite) SPErrorKind kind;
@property (nonatomic, readwrite, copy) NSString *shortText;
@property (nonatomic, readwrite, copy) NSString *detail;
@property (nonatomic, readwrite, copy) NSString *code;
@property (nonatomic, readwrite) SPErrorAction action;
@end

@implementation SPErrorExplanation
@end

static BOOL containsAny(NSString *text, NSArray<NSString *> *markers) {
    for (NSString *marker in markers) {
        if ([text containsString:marker]) return YES;
    }
    return NO;
}

static BOOL mentionsHttpStatus(NSString *text, NSString *alternatives) {
    NSString *pattern = [NSString stringWithFormat:@"\\b(%@)\\b", alternatives];
    return [text rangeOfString:pattern options:NSRegularExpressionSearch].location != NSNotFound;
}

/// FNV-1a over the UTF-8 bytes, folded to 16 bits: stable across runs and Macs.
static NSString *codeForMessage(NSString *message) {
    uint32_t hash = 2166136261u;
    for (const char *p = message.UTF8String ?: ""; *p; p++) {
        hash = (hash ^ (uint8_t)*p) * 16777619u;
    }
    return [NSString stringWithFormat:@"%04X", (hash ^ (hash >> 16)) & 0xFFFF];
}

static SPErrorExplanation *makeExplanation(SPErrorKind kind, NSString *shortText, NSString *detail,
                                           SPErrorAction action, NSString *message) {
    SPErrorExplanation *explanation = [[SPErrorExplanation alloc] init];
    explanation.kind = kind;
    explanation.shortText = shortText;
    explanation.detail = detail;
    explanation.action = action;
    explanation.code = codeForMessage(message ?: @"");
    return explanation;
}

@implementation SPErrorExplainer

+ (SPErrorKind)kindForMessage:(NSString *)message {
    NSString *lower = message.lowercaseString;
    if (lower.length == 0) return SPErrorKindUnknown;
    // Checked before the network markers: "ASR connection failed: HTTP error: 401" is about the key.
    if (containsAny(lower, @[ @"api_key is required", @"api key is required", @"no api key", @"missing api key" ])) {
        return SPErrorKindNoKey;
    }
    if (containsAny(lower, @[ @"invalidapikey", @"invalid_api_key", @"invalid api-key", @"invalid api key",
                              @"incorrect api key", @"invalid api_key", @"unauthorized", @"not authorized",
                              @"credential" ]) ||
        mentionsHttpStatus(lower, @"401")) {
        return SPErrorKindBadKey;
    }
    if (containsAny(lower, @[ @"arrearage", @"overdue", @"good standing", @"budgetlimit", @"freetieronly",
                              @"insufficient balance", @"out_of_service" ])) {
        return SPErrorKindNoBalance;
    }
    if (containsAny(lower, @[ @"throttl", @"rate limit", @"request limit", @"limit_requests", @"limit_burst",
                              @"too many requests", @"quota" ]) ||
        mentionsHttpStatus(lower, @"429")) {
        return SPErrorKindRateLimit;
    }
    if (containsAny(lower, @[ @"accessdenied", @"access denied", @"model_not_found", @"model not exist",
                              @"modelnotfound", @"does not exist" ]) ||
        mentionsHttpStatus(lower, @"403")) {
        return SPErrorKindAccessDenied;
    }
    if (containsAny(lower, @[ @"model not found", @"tokens.txt", @"read model dir" ])) {
        return SPErrorKindLocalModel;
    }
    if (containsAny(lower, @[ @"microphone", @"audio device", @"audio capture", @"audio buffer" ])) {
        return SPErrorKindMicrophone;
    }
    if (containsAny(lower, @[ @"timed out", @"timeout" ])) return SPErrorKindTimeout;
    if (containsAny(lower, @[ @"serviceoverloaded", @"service unavailable", @"internalerror", @"internal server",
                              @"bad gateway" ]) ||
        mentionsHttpStatus(lower, @"500|502|503|504")) {
        return SPErrorKindService;
    }
    if (containsAny(lower, @[ @"connect", @"websocket", @"network", @"dns", @"lookup", @"tls", @"closed",
                              @"reset", @"refused", @"unreachable", @"os error" ])) {
        return SPErrorKindNetwork;
    }
    return SPErrorKindUnknown;
}

+ (SPErrorExplanation *)explanationForMessage:(NSString *)message recordingKept:(BOOL)recordingKept {
    SPErrorKind kind = [self kindForMessage:message];
    // What is left to do after a passing failure: the recording waits for another try.
    NSString *saved = recordingKept ? @" Запись сохранена в «Последних диктовках»." : @"";
    SPErrorAction later = recordingKept ? SPErrorActionRecentDictations : SPErrorActionNone;
    switch (kind) {
        case SPErrorKindNoKey:
            return makeExplanation(kind, @"Нет ключа DashScope",
                                   @"Вставьте ключ: Настройки → Распознавание. Без ключа там же можно "
                                   @"выбрать распознавание на этом Mac.",
                                   SPErrorActionAsrSettings, message);
        case SPErrorKindBadKey:
            return makeExplanation(kind, @"Ключ не подходит",
                                   @"Сервис не принял ключ. Проверьте ключ и регион (Китай или международный): "
                                   @"Настройки → Распознавание → «Проверить ключ».",
                                   SPErrorActionAsrSettings, message);
        case SPErrorKindNoBalance:
            return makeExplanation(kind, @"Закончился баланс ключа",
                                   @"У ключа закончились деньги или бесплатный лимит. Пополните счёт в консоли "
                                   @"Alibaba Cloud или вставьте другой ключ: Настройки → Распознавание.",
                                   SPErrorActionAsrSettings, message);
        case SPErrorKindRateLimit:
            return makeExplanation(kind, @"Слишком много запросов",
                                   [@"Сервис временно ограничил ключ. Подождите минуту и повторите."
                                       stringByAppendingString:saved],
                                   later, message);
        case SPErrorKindAccessDenied:
            return makeExplanation(kind, @"Нет доступа к модели",
                                   @"Ключ не может пользоваться выбранной моделью. Выберите другую модель "
                                   @"или проверьте ключ: Настройки → Распознавание.",
                                   SPErrorActionAsrSettings, message);
        case SPErrorKindLocalModel:
            return makeExplanation(kind, @"Нет локальной модели",
                                   @"Модель для распознавания на этом Mac не найдена. Скачайте её заново: "
                                   @"Настройки → Распознавание.",
                                   SPErrorActionAsrSettings, message);
        case SPErrorKindMicrophone:
            return [self microphoneExplanationWithShortText:@"Микрофон недоступен"];
        case SPErrorKindTimeout:
            return makeExplanation(kind, @"Сервис не ответил",
                                   [@"Сервис распознавания не ответил вовремя. Проверьте интернет или VPN."
                                       stringByAppendingString:saved],
                                   later, message);
        case SPErrorKindService:
            return makeExplanation(kind, @"Сбой у сервиса",
                                   [@"Сервис распознавания сейчас не работает. Повторите позже."
                                       stringByAppendingString:saved],
                                   later, message);
        case SPErrorKindNetwork:
            return makeExplanation(kind, @"Нет связи с сервисом",
                                   [@"Проверьте интернет или VPN." stringByAppendingString:saved],
                                   later, message);
        case SPErrorKindUnknown:
            break;
    }
    return makeExplanation(SPErrorKindUnknown, @"Не удалось распознать",
                           [@"Если повторяется, напишите нам: меню значка → «Сообщить о проблеме…»."
                               stringByAppendingString:saved],
                           later, message);
}

+ (SPErrorExplanation *)explanationForWarning:(NSString *)message {
    NSString *reason = nil;
    NSString *shortText = nil;
    NSString *head = nil;
    if ([message hasPrefix:@"LLM correction failed:"]) {
        reason = [message substringFromIndex:@"LLM correction failed:".length];
        shortText = @"Вставлено без правки";
        head = @"Текст вставлен как распознан: языковая модель его не поправила.";
    } else if ([message hasPrefix:@"Rewrite failed:"]) {
        reason = [message substringFromIndex:@"Rewrite failed:".length];
        shortText = @"Не удалось переписать";
        head = @"Текст оставлен как распознан: языковая модель его не переписала.";
    } else {
        return nil;
    }
    NSString *hint;
    switch ([self kindForMessage:reason]) {
        case SPErrorKindNoKey:
            hint = @"Нет ключа для правки: Настройки → Языковая модель, или выключите правку там же.";
            break;
        case SPErrorKindBadKey:
        case SPErrorKindAccessDenied:
            hint = @"Сервис не принял ключ правки: Настройки → Языковая модель.";
            break;
        case SPErrorKindNoBalance:
        case SPErrorKindRateLimit:
            hint = @"У ключа правки закончился лимит или баланс.";
            break;
        case SPErrorKindTimeout:
        case SPErrorKindNetwork:
        case SPErrorKindService:
            hint = @"Сервис правки не ответил.";
            break;
        default:
            hint = @"";
            break;
    }
    NSString *detail = hint.length > 0 ? [NSString stringWithFormat:@"%@ %@", head, hint] : head;
    SPErrorExplanation *explanation =
        makeExplanation([self kindForMessage:reason], shortText, detail, SPErrorActionLlmSettings, message);
    return explanation;
}

+ (SPErrorExplanation *)microphoneExplanationWithShortText:(NSString *)shortText {
    return makeExplanation(SPErrorKindMicrophone, shortText,
                           @"Проверьте, какой микрофон выбран (меню значка → Микрофон) и есть ли у "
                           @"приложения доступ: Системные настройки → Конфиденциальность → Микрофон.",
                           SPErrorActionMicrophonePrivacy, shortText);
}

+ (SPErrorExplanation *)explanationWithKind:(SPErrorKind)kind
                                  shortText:(NSString *)shortText
                                     detail:(NSString *)detail
                                     action:(SPErrorAction)action {
    return makeExplanation(kind, shortText, detail, action, shortText);
}

+ (NSString *)notificationBodyForExplanation:(SPErrorExplanation *)explanation {
    if (explanation.kind != SPErrorKindUnknown) return explanation.detail;
    return [NSString stringWithFormat:@"%@ Код: %@.", explanation.detail, explanation.code];
}

@end
