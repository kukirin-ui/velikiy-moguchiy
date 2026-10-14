#import "SPLipTrainingPolicy.h"
#import "SPLipDataPolicy.h"

static NSDictionary *asDictionary(id object) {
    return [object isKindOfClass:[NSDictionary class]] ? object : nil;
}

static NSString *asString(id object) {
    return [object isKindOfClass:[NSString class]] ? object : nil;
}

static NSNumber *asNumber(id object) {
    return [object isKindOfClass:[NSNumber class]] ? object : nil;
}

static BOOL asBool(id object) {
    return [object isKindOfClass:[NSNumber class]] && [object boolValue];
}

static NSString *plural(NSInteger n, NSString *one, NSString *few, NSString *many) {
    return [SPLipDataPolicy pluralForm:n forms:@[ one, few, many ]];
}

/// As SPLipDataPolicy's counter: whole minutes from 10 on, one decimal below.
static NSString *minutesText(double minutes) {
    if (minutes >= 10.0 || minutes <= 0.0) {
        NSInteger whole = (NSInteger)llround(MAX(minutes, 0.0));
        return [NSString stringWithFormat:@"%ld %@", (long)whole, plural(whole, @"минута", @"минуты", @"минут")];
    }
    NSString *number = [[NSString stringWithFormat:@"%.1f", minutes] stringByReplacingOccurrencesOfString:@"."
                                                                                              withString:@","];
    return [number stringByAppendingString:@" минуты"];
}

@implementation SPLipTrainingPolicy

+ (NSString *)modeArgument:(SPLipTrainingMode)mode {
    return mode == SPLipTrainingModeFull ? @"full" : @"light";
}

+ (NSArray<NSString *> *)argumentsWithScript:(NSString *)scriptPath
                                     command:(NSString *)command
                                        mode:(SPLipTrainingMode)mode
                                     appData:(NSString *)appDataDirectory
                                    clipsDir:(NSString *)clipsDirectory {
    NSMutableArray<NSString *> *args = [NSMutableArray arrayWithObjects:scriptPath, command, @"--app-data",
                                                                        appDataDirectory, @"--clips-dir",
                                                                        clipsDirectory, nil];
    if ([command isEqualToString:@"run"]) {
        [args addObjectsFromArray:@[ @"--mode", [self modeArgument:mode] ]];
    }
    return args;
}

+ (NSDictionary *)effectiveStatus:(NSDictionary *)status processAlive:(BOOL)alive {
    if (!asDictionary(status)) return nil;
    if (![self isRunningStatus:status] || alive) return status;
    NSMutableDictionary *dead = [status mutableCopy];
    dead[@"state"] = @"failed";
    dead[@"paused"] = @NO;
    dead[@"eta_sec"] = [NSNull null];
    dead[@"message"] = @"Обучение прервалось: процесс завершился, не дописав итог";
    return dead;
}

+ (BOOL)isRunningStatus:(NSDictionary *)status {
    return [asString(asDictionary(status)[@"state"]) isEqualToString:@"running"];
}

+ (BOOL)canStartWithScan:(NSDictionary *)scan status:(NSDictionary *)status {
    if (!asDictionary(scan) || [self blockerForScan:scan]) return NO;
    if ([self isRunningStatus:status] || [self isRunningStatus:asDictionary(scan[@"job"])]) return NO;
    return asBool(scan[@"ready"]);
}

+ (NSString *)blockerForScan:(NSDictionary *)scan {
    if (!asDictionary(scan)) return @"Считаю клипы…";
    NSString *error = asString(scan[@"error"]);
    if (error.length > 0) return error;
    NSArray *problems = [scan[@"setup_problems"] isKindOfClass:[NSArray class]] ? scan[@"setup_problems"] : @[];
    if (problems.count > 0) {
        return [@"Не готово: " stringByAppendingString:[problems componentsJoinedByString:@"; "]];
    }
    NSInteger usable = asNumber(scan[@"usable"]).integerValue;
    NSInteger minimum = asNumber(scan[@"min_clips"]).integerValue;
    if (usable < minimum) {
        NSInteger need = minimum - usable;
        return [NSString stringWithFormat:@"Нужно ещё %ld %@ (минимум %ld). Включите «Снимать камеру во время "
                                          @"диктовки» выше и диктуйте как обычно.",
                                          (long)need, plural(need, @"клип", @"клипа", @"клипов"), (long)minimum];
    }
    return nil;
}

+ (NSString *)clipsLineForScan:(NSDictionary *)scan {
    if (!asDictionary(scan)) return @"Считаю клипы…";
    NSInteger usable = asNumber(scan[@"usable"]).integerValue;
    NSInteger total = asNumber(scan[@"total"]).integerValue;
    double minutes = asNumber(scan[@"usable_minutes"]).doubleValue;
    NSString *line = [NSString stringWithFormat:@"Пригодно для обучения: %ld %@, %@", (long)usable,
                                                plural(usable, @"клип", @"клипа", @"клипов"), minutesText(minutes)];
    if (total > usable) {
        line = [line stringByAppendingFormat:@" (из %ld %@)", (long)total,
                                             plural(total, @"записанного", @"записанных", @"записанных")];
    }
    return line;
}

+ (NSString *)modelLineForScan:(NSDictionary *)scan {
    NSDictionary *model = asDictionary(asDictionary(scan)[@"model"]);
    NSString *label = asString(model[@"label"]);
    if (label.length == 0) return @"Сейчас: …";
    NSString *line = [@"Сейчас: " stringByAppendingString:label];
    NSDictionary *info = asDictionary(model[@"info"]);
    NSNumber *newWer = asNumber(info[@"new_wer"]);
    NSNumber *oldWer = asNumber(info[@"old_wer"]);
    if (newWer) {
        line = [line stringByAppendingFormat:@", ошибка %@", [self percentText:newWer.doubleValue]];
        if (oldWer) line = [line stringByAppendingFormat:@" (была %@)", [self percentText:oldWer.doubleValue]];
    }
    return line;
}

+ (NSString *)rollbackHintForScan:(NSDictionary *)scan {
    NSDictionary *rollback = asDictionary(asDictionary(scan)[@"rollback"]);
    if (!asBool(rollback[@"available"])) return nil;
    NSString *label = asString(asDictionary(rollback[@"to"])[@"label"]);
    return [@"Прежняя: " stringByAppendingString:label.length > 0 ? label : @"предыдущая модель"];
}

+ (NSString *)estimateText:(SPLipTrainingMode)mode scan:(NSDictionary *)scan {
    NSNumber *seconds = asNumber(asDictionary(asDictionary(scan)[@"estimates"])[[self modeArgument:mode]]);
    return seconds ? [self durationText:seconds.doubleValue] : nil;
}

+ (NSString *)modeTitle:(SPLipTrainingMode)mode scan:(NSDictionary *)scan {
    NSString *name = mode == SPLipTrainingModeFull ? @"Полный" : @"Лёгкий";
    NSString *estimate = [self estimateText:mode scan:scan];
    return estimate ? [NSString stringWithFormat:@"%@ · %@", name, estimate] : name;
}

+ (NSString *)modeDescription:(SPLipTrainingMode)mode {
    if (mode == SPLipTrainingModeFull) {
        return @"Полный: дообучается и «зрение» модели — часы. Сильнее подстраивается под ваше лицо, свет и "
               @"камеру. Первый запуск начинается с короткого проверочного прогона.";
    }
    return @"Лёгкий: учатся только небольшие адаптеры на готовых признаках губ — минуты. Удобно для регулярной "
           @"подстройки по мере новых диктовок.";
}

+ (double)progressForStatus:(NSDictionary *)status {
    double value = asNumber(asDictionary(status)[@"progress"]).doubleValue;
    return MIN(1.0, MAX(0.0, value));
}

+ (NSString *)progressLineForStatus:(NSDictionary *)status now:(NSDate *)now {
    if (![self isRunningStatus:status]) return @"";
    NSString *label = asString(status[@"stage_label"]);
    if (label.length == 0) label = @"Обучение";
    long percent = lround([self progressForStatus:status] * 100.0);
    if (asBool(status[@"paused"])) {
        return [NSString stringWithFormat:@"%@ — %ld%%. Пауза: не хватает памяти, продолжу сам", label, percent];
    }
    NSNumber *eta = asNumber(status[@"eta_sec"]);
    if (!eta) return [NSString stringWithFormat:@"%@ — %ld%%", label, percent];
    double left = eta.doubleValue;
    NSNumber *updated = asNumber(status[@"updated_at"]);
    if (updated) left -= MAX(0.0, now.timeIntervalSince1970 - updated.doubleValue);
    return [NSString stringWithFormat:@"%@ — %ld%%, осталось %@", label, percent,
                                      [self durationText:MAX(left, 60.0)]];
}

+ (NSString *)resultLineForStatus:(NSDictionary *)status {
    NSString *state = asString(asDictionary(status)[@"state"]);
    NSString *message = asString(status[@"message"]);
    if (message.length == 0) return nil;
    if ([state isEqualToString:@"failed"]) return [@"Не получилось: " stringByAppendingString:message];
    if ([state isEqualToString:@"done"] || [state isEqualToString:@"cancelled"]) return message;
    return nil;
}

+ (BOOL)statusInstalledModel:(NSDictionary *)status {
    return [asString(asDictionary(status)[@"state"]) isEqualToString:@"done"] &&
           asBool(asDictionary(status[@"result"])[@"installed"]);
}

+ (NSString *)durationText:(double)seconds {
    if (seconds < 45.0) return @"меньше минуты";
    if (seconds < 3600.0 - 150.0) {
        long minutes = MAX(1L, lround(seconds / 60.0));
        return [NSString stringWithFormat:@"≈ %ld мин", minutes];
    }
    long minutes = lround(seconds / 600.0) * 10;  // hours to the nearest 10 minutes
    long hours = minutes / 60, rest = minutes % 60;
    return rest == 0 ? [NSString stringWithFormat:@"≈ %ld ч", hours]
                     : [NSString stringWithFormat:@"≈ %ld ч %ld мин", hours, rest];
}

+ (NSString *)percentText:(double)fraction {
    NSString *number = [NSString stringWithFormat:@"%.1f", fraction * 100.0];
    return [[number stringByReplacingOccurrencesOfString:@"." withString:@","] stringByAppendingString:@"%"];
}

@end
