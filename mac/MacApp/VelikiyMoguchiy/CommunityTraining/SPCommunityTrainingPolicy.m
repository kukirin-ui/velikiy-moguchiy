#import "SPCommunityTrainingPolicy.h"

static NSString *const kNBSP = @" ";

static NSDictionary *dictionaryValue(id value) {
    return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

static NSString *stringValue(id value) {
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static NSNumber *numberValue(id value) {
    return [value isKindOfClass:[NSNumber class]] ? value : nil;
}

@implementation SPCommunityTrainingPolicy

#pragma mark Process

+ (NSArray<NSString *> *)argumentsForCommand:(NSString *)command value:(NSString *)value {
    NSMutableArray *arguments = [@[ @"-m", @"client.community", command ] mutableCopy];
    if (value.length > 0) [arguments addObject:value];
    return arguments;
}

+ (NSString *)installNote {
    return @"Для «Помочь обучить» нужно то же, что для режима «губы»: модель чтения по губам и библиотеки. "
           @"Нажмите «Установить» — приложение скажет, сколько это займёт места, и всё поставит само.";
}

+ (NSString *)setupProblemForFederatedDirectory:(NSString *)federatedDirectory
                                   pythonExists:(BOOL)pythonExists
                                   scriptExists:(BOOL)scriptExists {
    if (!scriptExists) {
        return [NSString stringWithFormat:@"Не найдена папка federated с клиентом обучения (%@). Она лежит рядом с "
                                          @"папкой lipread, путь к которой задаёт lips.service_dir.",
                                          federatedDirectory];
    }
    if (!pythonExists) {
        return @"Нет окружения Python для обучения: в папке lipread выполните ./setup.sh (uv sync ставит и "
               @"пакеты клиента) или создайте federated/.venv по federated/README.md, раздел «Окружение».";
    }
    return nil;
}

+ (NSArray *)JSONValuesInOutput:(NSData *)output {
    if (output.length == 0) return @[];
    NSString *text = [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding];
    NSMutableArray *values = [NSMutableArray array];
    for (NSString *rawLine in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (line.length == 0) continue;
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        id value = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:nil];
        if (value) [values addObject:value];
    }
    return values;
}

+ (id)lastJSONValueInOutput:(NSData *)output {
    return [self JSONValuesInOutput:output].lastObject;
}

+ (NSDictionary *)statusFromJSON:(id)json {
    NSDictionary *object = dictionaryValue(json);
    if (!object || !numberValue(object[@"consent"]) || !numberValue(object[@"logged_in"])) return nil;
    NSMutableDictionary *status = [object mutableCopy];
    status[@"job"] = dictionaryValue(object[@"job"]) ?: @{};
    return status;
}

#pragma mark Login

+ (NSDictionary<NSString *, NSString *> *)loginCodeFromJSON:(id)json {
    NSDictionary *object = dictionaryValue(json);
    NSString *code = stringValue(object[@"user_code"]);
    NSString *uri = stringValue(object[@"verification_uri"]);
    if (code.length < 4 || code.length > 20 || uri.length == 0) return nil;
    NSCharacterSet *allowed =
        [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-"];
    if ([code rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return nil;
    NSURL *url = [NSURL URLWithString:uri];
    NSString *host = url.host.lowercaseString;
    if (![url.scheme.lowercaseString isEqualToString:@"https"] ||
        !([host isEqualToString:@"github.com"] || [host hasSuffix:@".github.com"])) {
        return nil;
    }
    return @{@"user_code" : code, @"verification_uri" : uri};
}

+ (NSNumber *)loginResultFromJSON:(id)json error:(NSString **)error {
    NSDictionary *object = dictionaryValue(json);
    NSNumber *loggedIn = numberValue(object[@"logged_in"]);
    if (!loggedIn) return nil;
    if (error) *error = loggedIn.boolValue ? nil : (stringValue(object[@"error"]) ?: @"вход не удался");
    return @(loggedIn.boolValue);
}

#pragma mark State

+ (NSDictionary *)jobOfStatus:(NSDictionary *)status {
    return dictionaryValue(status[@"job"]) ?: @{};
}

+ (SPCommunityJobState)stateOfStatus:(NSDictionary *)status {
    NSString *state = stringValue([self jobOfStatus:status][@"state"]);
    static NSDictionary<NSString *, NSNumber *> *states;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        states = @{
            @"running" : @(SPCommunityJobStateRunning),
            @"sending" : @(SPCommunityJobStateSending),
            @"ready_to_send" : @(SPCommunityJobStateReadyToSend),
            @"done" : @(SPCommunityJobStateDone),
            @"error" : @(SPCommunityJobStateError),
            @"cancelled" : @(SPCommunityJobStateCancelled),
        };
    });
    NSNumber *value = state ? states[state] : nil;
    return value ? (SPCommunityJobState)value.integerValue : SPCommunityJobStateIdle;
}

+ (BOOL)isActiveStatus:(NSDictionary *)status {
    SPCommunityJobState state = [self stateOfStatus:status];
    return state == SPCommunityJobStateRunning || state == SPCommunityJobStateSending;
}

+ (BOOL)flag:(NSString *)key inStatus:(NSDictionary *)status {
    return [numberValue(status[key]) boolValue];
}

+ (BOOL)canStartWithStatus:(NSDictionary *)status {
    return status != nil && [self flag:@"consent" inStatus:status] && [self flag:@"logged_in" inStatus:status] &&
           [self flag:@"server_configured" inStatus:status] && ![self isActiveStatus:status] &&
           ![self showsPreviewForStatus:status];
}

+ (NSString *)blockerForStatus:(NSDictionary *)status {
    if (!status || [self isActiveStatus:status]) return nil;
    if (![self flag:@"server_configured" inStatus:status]) return @"Сервер обучения ещё не настроен";
    if (![self flag:@"consent" inStatus:status]) return @"Чтобы начать, отметьте согласие выше";
    if (![self flag:@"logged_in" inStatus:status]) return @"Войдите через GitHub: по логину сервер учитывает ваш вклад";
    if ([self showsPreviewForStatus:status]) return @"Сначала отправьте готовое обновление или откажитесь от него";
    return nil;
}

+ (BOOL)canLoginWithStatus:(NSDictionary *)status {
    return status != nil && [self flag:@"server_configured" inStatus:status] && ![self flag:@"logged_in" inStatus:status];
}

+ (BOOL)showsPreviewForStatus:(NSDictionary *)status {
    if (!status || [self isActiveStatus:status]) return NO;
    if (numberValue(status[@"has_outbox"])) return [self flag:@"has_outbox" inStatus:status];
    return [self stateOfStatus:status] == SPCommunityJobStateReadyToSend;
}

+ (NSDictionary *)previewOfStatus:(NSDictionary *)status {
    return dictionaryValue([self jobOfStatus:status][@"preview"]);
}

+ (BOOL)isPausedStatus:(NSDictionary *)status override:(NSNumber *)override {
    if (override) return override.boolValue;
    return [numberValue([self jobOfStatus:status][@"paused"]) boolValue];
}

+ (double)progressForStatus:(NSDictionary *)status {
    double progress = [numberValue([self jobOfStatus:status][@"progress"]) doubleValue];
    if (isnan(progress)) return 0.0;
    return MIN(1.0, MAX(0.0, progress));
}

+ (NSString *)progressLineForStatus:(NSDictionary *)status paused:(BOOL)paused {
    NSDictionary *job = [self jobOfStatus:status];
    if ([self stateOfStatus:status] == SPCommunityJobStateSending) return @"Отправка обновления…";
    NSString *stage = stringValue(job[@"stage"]);
    NSString *label = stringValue(job[@"stage_label"]);
    if (label.length == 0) label = @"Подготовка";
    NSString *line = label;
    // The task and model stages report no fraction of their own.
    if ([@[ @"download", @"prepare", @"train", @"pack" ] containsObject:stage ?: @""]) {
        line = [NSString stringWithFormat:@"%@ — %ld%%", label, lround([self progressForStatus:status] * 100.0)];
    } else {
        line = [label stringByAppendingString:@"…"];
    }
    return paused ? [line stringByAppendingString:@" · на паузе"] : line;
}

+ (NSString *)detailLineForStatus:(NSDictionary *)status {
    NSDictionary *job = [self jobOfStatus:status];
    NSDictionary *task = dictionaryValue(job[@"task"]);
    NSDictionary *counts = dictionaryValue(job[@"counts"]);
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    void (^add)(NSString *, id) = ^(NSString *title, id value) {
        NSNumber *number = numberValue(value);
        if (number) [parts addObject:[NSString stringWithFormat:@"%@: %@", title, [self groupedInteger:number.longLongValue]]];
    };
    add(@"роликов в задании", task[@"videos"]);
    add(@"скачано", counts[@"videos_ok"]);
    if ([numberValue(counts[@"videos_failed"]) longLongValue] > 0) add(@"не скачалось", counts[@"videos_failed"]);
    add(@"отрезков", counts[@"clips"]);
    add(@"с лицом", counts[@"with_face"]);
    if (parts.count == 0) return @"";
    NSString *line = [parts componentsJoinedByString:@" · "];
    return [[line substringToIndex:1].uppercaseString stringByAppendingString:[line substringFromIndex:1]];
}

+ (NSString *)resultMessageForStatus:(NSDictionary *)status {
    NSString *message = stringValue([self jobOfStatus:status][@"message"]);
    switch ([self stateOfStatus:status]) {
        case SPCommunityJobStateDone:
            return message.length ? message : @"Обновление принято сервером. Спасибо!";
        case SPCommunityJobStateError:
            return message.length ? message : @"Задание завершилось с ошибкой";
        case SPCommunityJobStateCancelled:
            return message.length ? message : @"Обучение отменено, ничего не отправлено";
        case SPCommunityJobStateIdle:
            return message.length ? message : nil;
        default:
            return nil;
    }
}

#pragma mark Preview

+ (NSString *)previewSummaryForPreview:(NSDictionary *)preview {
    NSDictionary *payload = dictionaryValue(preview[@"payload"]) ?: @{};
    NSDictionary *contributionEnvelope = dictionaryValue(preview[@"contribution"]) ?: @{};
    NSDictionary *contribution = dictionaryValue(contributionEnvelope[@"contribution"]) ?: contributionEnvelope;
    NSDictionary *manifestEnvelope = dictionaryValue(preview[@"manifest"]) ?: @{};
    NSDictionary *manifest = dictionaryValue(manifestEnvelope[@"manifest"]) ?: manifestEnvelope;
    NSString *dash = @"—";
    NSString *(^integer)(id) = ^NSString *(id value) {
        NSNumber *number = numberValue(value);
        return number ? [self groupedInteger:number.longLongValue] : dash;
    };
    NSString *(^kilobytes)(id) = ^NSString *(id value) {
        NSNumber *number = numberValue(value);
        return number ? [self kilobytesText:number.longLongValue] : dash;
    };

    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    [lines addObject:[NSString stringWithFormat:@"Уходит на сервер: манифест, обновление весов и сведения о вкладе — "
                                                @"всего %@.",
                                                kilobytes(preview[@"total_bytes"])]];
    NSString *dtype = stringValue(payload[@"dtype"]) ?: dash;
    NSString *format = stringValue(payload[@"format"]) ?: dash;
    [lines addObject:[NSString stringWithFormat:@"• Обновление весов: %@, тензоров: %@, параметров: %@, %@ (%@).",
                                                kilobytes(payload[@"bytes"]), integer(payload[@"tensors"]),
                                                integer(payload[@"parameters"]), dtype, format]];
    NSNumber *seconds = numberValue(contribution[@"data_seconds"]);
    [lines addObject:[NSString stringWithFormat:@"• Видео с лицом в обучении: %@, шагов обучения: %@, отрезков: %@.",
                                                seconds ? [self durationText:seconds.doubleValue] : dash,
                                                integer(contribution[@"training_steps"]),
                                                integer(contribution[@"num_clips"])]];
    id base = contribution[@"base_version"] ?: manifest[@"base_version"];
    [lines addObject:[NSString stringWithFormat:@"• Версия общей модели, от которой шло обучение: %@.", integer(base)]];
    NSNumber *credit = numberValue(contribution[@"credit_public"]);
    if (credit) {
        [lines addObject:credit.boolValue ? @"• Ваш логин GitHub появится в публичной таблице участников."
                                          : @"• Ваш логин GitHub не показывается в таблице участников."];
    }
    NSString *sha = stringValue(payload[@"sha256"]);
    if (sha.length) [lines addObject:[NSString stringWithFormat:@"• SHA-256 обновления весов: %@", sha]];
    NSArray *examples = [payload[@"examples"] isKindOfClass:[NSArray class]] ? payload[@"examples"] : nil;
    if (examples.count) {
        [lines addObject:[NSString stringWithFormat:@"• Первые тензоры: %@ …", [examples componentsJoinedByString:@", "]]];
    }
    return [lines componentsJoinedByString:@"\n"];
}

+ (NSString *)previewTextForPreview:(NSDictionary *)preview {
    if (![preview isKindOfClass:[NSDictionary class]]) {
        return @"Описание обновления не найдено. Его можно выбросить кнопкой «Не отправлять».";
    }
    NSMutableString *text = [[self previewSummaryForPreview:preview] mutableCopy];
    [text appendFormat:@"\n\nМанифест (уходит целиком):\n%@", [self prettyJSON:preview[@"manifest"]]];
    [text appendFormat:@"\n\nСведения о вкладе (уходят целиком):\n%@", [self prettyJSON:preview[@"contribution"]]];
    NSArray *notSent = [preview[@"not_sent"] isKindOfClass:[NSArray class]] ? preview[@"not_sent"] : nil;
    NSMutableArray<NSString *> *items = [NSMutableArray array];
    for (id item in notSent) {
        if ([item isKindOfClass:[NSString class]]) [items addObject:item];
    }
    if (items.count) [text appendFormat:@"\n\nНе отправляется: %@.", [items componentsJoinedByString:@", "]];
    return text;
}

#pragma mark Texts

+ (NSString *)consentAlertTitle {
    return @"Помогать обучать общую модель?";
}

+ (NSString *)consentAlertText {
    return @"Что скачивается: публичные ролики YouTube из задания сервера. Их скачивает этот Mac со своего "
           @"интернет-адреса, только видео без звука; после нарезки ролик сразу удаляется.\n\n"
           @"Что выполняется: нарезка и обучение здесь, на Mac, под охранником памяти. Пока идёт задание, Mac "
           @"может быть занят — от нескольких минут до нескольких часов. Задание можно поставить на паузу или "
           @"отменить.\n\n"
           @"Что отправляется: только обновление весов и числа (часы видео, шаги обучения), а также ваш логин "
           @"GitHub — он появится в публичной таблице участников. Перед отправкой вы увидите всё, что уйдёт, и "
           @"сами нажмёте «Отправить».\n\n"
           @"Ваши диктовки, записи камеры и личная модель никогда не используются.\n\n"
           @"Согласие можно выключить в любой момент этим же флажком.";
}

+ (NSString *)kilobytesText:(long long)bytes {
    long long tenths = llround(MAX(0, bytes) / 1024.0 * 10.0);
    return [NSString stringWithFormat:@"%@,%lld%@КБ", [self groupedInteger:tenths / 10], tenths % 10, kNBSP];
}

+ (NSString *)groupedInteger:(long long)value {
    BOOL negative = value < 0;
    unsigned long long magnitude = negative ? (unsigned long long)(-(value + 1)) + 1 : (unsigned long long)value;
    NSString *digits = [NSString stringWithFormat:@"%llu", magnitude];
    NSMutableString *grouped = [NSMutableString string];
    NSUInteger length = digits.length;
    for (NSUInteger i = 0; i < length; i++) {
        if (i > 0 && (length - i) % 3 == 0) [grouped appendString:kNBSP];
        [grouped appendFormat:@"%C", [digits characterAtIndex:i]];
    }
    return negative ? [@"-" stringByAppendingString:grouped] : grouped;
}

+ (NSString *)durationText:(double)seconds {
    seconds = MAX(0.0, seconds);
    if (seconds < 3600.0) {
        return [NSString stringWithFormat:@"%lld%@мин", (long long)llround(seconds / 60.0), kNBSP];
    }
    long long tenths = llround(seconds / 3600.0 * 10.0);
    return [NSString stringWithFormat:@"%lld,%lld%@ч", tenths / 10, tenths % 10, kNBSP];
}

+ (NSString *)count:(long long)n one:(NSString *)one few:(NSString *)few many:(NSString *)many {
    long long mod10 = llabs(n) % 10, mod100 = llabs(n) % 100;
    NSString *word = many;
    if (mod10 == 1 && mod100 != 11) {
        word = one;
    } else if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
        word = few;
    }
    return [NSString stringWithFormat:@"%@%@%@", [self groupedInteger:n], kNBSP, word];
}

+ (NSString *)prettyJSON:(id)object {
    if (!object || object == [NSNull null]) return @"null";
    if (![NSJSONSerialization isValidJSONObject:object]) return [object description];
    NSJSONWritingOptions options =
        NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys | NSJSONWritingWithoutEscapingSlashes;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:options error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"null";
}

@end
