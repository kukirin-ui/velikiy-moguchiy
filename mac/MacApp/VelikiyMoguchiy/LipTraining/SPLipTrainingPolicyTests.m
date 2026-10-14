#import <XCTest/XCTest.h>
#import "SPLipTrainingPolicy.h"

@interface SPLipTrainingPolicyTests : XCTestCase
@end

@implementation SPLipTrainingPolicyTests

- (NSDictionary *)scanWithUsable:(NSInteger)usable total:(NSInteger)total {
    return @{
        @"usable" : @(usable),
        @"total" : @(total),
        @"usable_minutes" : @9.5,
        @"min_clips" : @100,
        @"ready" : @(usable >= 100),
        @"setup_problems" : @[],
        @"estimates" : @{@"light" : @420, @"full" : @6800},
        @"model" : @{@"kind" : @"factory", @"label" : @"Исходная модель", @"info" : @{}},
        @"rollback" : @{@"available" : @NO, @"to" : [NSNull null]},
        @"job" : [NSNull null],
    };
}

- (void)testRunArguments {
    NSArray *run = [SPLipTrainingPolicy argumentsWithScript:@"/l/train_on_me.py"
                                                    command:@"run"
                                                       mode:SPLipTrainingModeFull
                                                    appData:@"/u/.velikiy-moguchiy"
                                                   clipsDir:@"/u/.velikiy-moguchiy/lipdata/voiced"];
    XCTAssertEqualObjects(run, (@[ @"/l/train_on_me.py", @"run", @"--app-data", @"/u/.velikiy-moguchiy",
                                   @"--clips-dir", @"/u/.velikiy-moguchiy/lipdata/voiced", @"--mode", @"full" ]));
    NSArray *scan = [SPLipTrainingPolicy argumentsWithScript:@"/l/train_on_me.py"
                                                     command:@"scan"
                                                        mode:SPLipTrainingModeLight
                                                     appData:@"/a"
                                                    clipsDir:@"/c"];
    XCTAssertEqualObjects(scan, (@[ @"/l/train_on_me.py", @"scan", @"--app-data", @"/a", @"--clips-dir", @"/c" ]));
}

- (void)testButtonNeedsEnoughClipsAndNoRunningJob {
    NSDictionary *few = [self scanWithUsable:63 total:70];
    XCTAssertFalse([SPLipTrainingPolicy canStartWithScan:few status:nil]);
    XCTAssertTrue([[SPLipTrainingPolicy blockerForScan:few] hasPrefix:@"Нужно ещё 37 клипов (минимум 100)"]);
    XCTAssertTrue([[SPLipTrainingPolicy blockerForScan:[self scanWithUsable:99 total:99]]
        hasPrefix:@"Нужно ещё 1 клип "]);

    NSDictionary *enough = [self scanWithUsable:143 total:160];
    XCTAssertNil([SPLipTrainingPolicy blockerForScan:enough]);
    XCTAssertTrue([SPLipTrainingPolicy canStartWithScan:enough status:nil]);
    XCTAssertTrue([SPLipTrainingPolicy canStartWithScan:enough status:@{@"state" : @"done"}]);
    XCTAssertFalse([SPLipTrainingPolicy canStartWithScan:enough status:@{@"state" : @"running"}]);

    NSMutableDictionary *broken = [enough mutableCopy];
    broken[@"setup_problems"] = @[ @"нет весов MultiVSR (запустите lipread/download_weights.sh)" ];
    XCTAssertFalse([SPLipTrainingPolicy canStartWithScan:broken status:nil]);
    XCTAssertTrue([[SPLipTrainingPolicy blockerForScan:broken] hasPrefix:@"Не готово: нет весов MultiVSR"]);
    XCTAssertFalse([SPLipTrainingPolicy canStartWithScan:nil status:nil]);
    XCTAssertFalse([SPLipTrainingPolicy canStartWithScan:@{@"error" : @"Нет lipread"} status:nil]);
}

- (void)testClipsLine {
    XCTAssertEqualObjects([SPLipTrainingPolicy clipsLineForScan:[self scanWithUsable:143 total:160]],
                          @"Пригодно для обучения: 143 клипа, 9,5 минуты (из 160 записанных)");
    NSMutableDictionary *scan = [[self scanWithUsable:121 total:121] mutableCopy];
    scan[@"usable_minutes"] = @12.4;
    XCTAssertEqualObjects([SPLipTrainingPolicy clipsLineForScan:scan], @"Пригодно для обучения: 121 клип, 12 минут");
    scan[@"total"] = @131;
    XCTAssertTrue([[SPLipTrainingPolicy clipsLineForScan:scan] hasSuffix:@"(из 131 записанного)"]);
    XCTAssertEqualObjects([SPLipTrainingPolicy clipsLineForScan:nil], @"Считаю клипы…");
}

- (void)testModelAndRollbackLines {
    NSMutableDictionary *scan = [[self scanWithUsable:143 total:160] mutableCopy];
    XCTAssertEqualObjects([SPLipTrainingPolicy modelLineForScan:scan], @"Сейчас: Исходная модель");
    XCTAssertNil([SPLipTrainingPolicy rollbackHintForScan:scan]);
    scan[@"model"] = @{
        @"kind" : @"personal",
        @"label" : @"Ваша модель от 14.10.2026 (лёгкий режим)",
        @"info" : @{@"new_wer" : @0.702, @"old_wer" : @0.741},
    };
    scan[@"rollback"] = @{@"available" : @YES, @"to" : @{@"label" : @"Исходная модель"}};
    XCTAssertEqualObjects([SPLipTrainingPolicy modelLineForScan:scan],
                          @"Сейчас: Ваша модель от 14.10.2026 (лёгкий режим), ошибка 70,2% (была 74,1%)");
    XCTAssertEqualObjects([SPLipTrainingPolicy rollbackHintForScan:scan], @"Прежняя: Исходная модель");
}

- (void)testModeTitlesCarryTheEstimates {
    NSDictionary *scan = [self scanWithUsable:143 total:160];
    XCTAssertEqualObjects([SPLipTrainingPolicy modeTitle:SPLipTrainingModeLight scan:scan], @"Лёгкий · ≈ 7 мин");
    XCTAssertEqualObjects([SPLipTrainingPolicy modeTitle:SPLipTrainingModeFull scan:scan], @"Полный · ≈ 1 ч 50 мин");
    XCTAssertEqualObjects([SPLipTrainingPolicy modeTitle:SPLipTrainingModeFull scan:nil], @"Полный");
    XCTAssertEqualObjects([SPLipTrainingPolicy estimateText:SPLipTrainingModeFull scan:scan], @"≈ 1 ч 50 мин");
    XCTAssertNil([SPLipTrainingPolicy estimateText:SPLipTrainingModeLight scan:@{}]);
}

- (void)testDurations {
    XCTAssertEqualObjects([SPLipTrainingPolicy durationText:20], @"меньше минуты");
    XCTAssertEqualObjects([SPLipTrainingPolicy durationText:61], @"≈ 1 мин");
    XCTAssertEqualObjects([SPLipTrainingPolicy durationText:12 * 60 + 20], @"≈ 12 мин");
    XCTAssertEqualObjects([SPLipTrainingPolicy durationText:3500], @"≈ 1 ч");
    XCTAssertEqualObjects([SPLipTrainingPolicy durationText:2 * 3600 + 9 * 60], @"≈ 2 ч 10 мин");
    XCTAssertEqualObjects([SPLipTrainingPolicy percentText:0.741], @"74,1%");
}

- (void)testProgressLine {
    NSDate *now = [NSDate dateWithTimeIntervalSince1970:1000];
    NSDictionary *running = @{
        @"state" : @"running",
        @"stage_label" : @"Обучение",
        @"progress" : @0.423,
        @"eta_sec" : @480,
        @"updated_at" : @880,
        @"paused" : @NO,
    };
    XCTAssertEqual([SPLipTrainingPolicy progressForStatus:running], 0.423);
    // the ETA was written 120 s ago
    XCTAssertEqualObjects([SPLipTrainingPolicy progressLineForStatus:running now:now],
                          @"Обучение — 42%, осталось ≈ 6 мин");
    NSMutableDictionary *paused = [running mutableCopy];
    paused[@"paused"] = @YES;
    XCTAssertEqualObjects([SPLipTrainingPolicy progressLineForStatus:paused now:now],
                          @"Обучение — 42%. Пауза: не хватает памяти, продолжу сам");
    NSMutableDictionary *noEta = [running mutableCopy];
    noEta[@"eta_sec"] = [NSNull null];
    XCTAssertEqualObjects([SPLipTrainingPolicy progressLineForStatus:noEta now:now], @"Обучение — 42%");
    XCTAssertEqualObjects([SPLipTrainingPolicy progressLineForStatus:@{@"state" : @"done"} now:now], @"");
    XCTAssertNil([SPLipTrainingPolicy resultLineForStatus:running]);
}

- (void)testResultLines {
    NSDictionary *done = @{
        @"state" : @"done",
        @"message" : @"Новая модель лучше: ошибка в словах 70,2% вместо 74,1% на 14 отложенных клипах. Установлена.",
        @"result" : @{@"installed" : @YES},
    };
    XCTAssertEqualObjects([SPLipTrainingPolicy resultLineForStatus:done], done[@"message"]);
    XCTAssertTrue([SPLipTrainingPolicy statusInstalledModel:done]);
    NSDictionary *kept = @{@"state" : @"done", @"message" : @"Новая модель не лучше", @"result" : @{@"installed" : @NO}};
    XCTAssertFalse([SPLipTrainingPolicy statusInstalledModel:kept]);
    NSDictionary *failed = @{@"state" : @"failed", @"message" : @"Мало клипов"};
    XCTAssertEqualObjects([SPLipTrainingPolicy resultLineForStatus:failed], @"Не получилось: Мало клипов");
    XCTAssertNil([SPLipTrainingPolicy resultLineForStatus:nil]);
}

- (void)testDeadJobReadsAsFailed {
    NSDictionary *running = @{@"state" : @"running", @"pid" : @123, @"progress" : @0.3};
    XCTAssertEqualObjects([SPLipTrainingPolicy effectiveStatus:running processAlive:YES], running);
    NSDictionary *dead = [SPLipTrainingPolicy effectiveStatus:running processAlive:NO];
    XCTAssertEqualObjects(dead[@"state"], @"failed");
    XCTAssertFalse([SPLipTrainingPolicy isRunningStatus:dead]);
    XCTAssertTrue([[SPLipTrainingPolicy resultLineForStatus:dead] containsString:@"прервалось"]);
    XCTAssertNil([SPLipTrainingPolicy effectiveStatus:nil processAlive:NO]);
}

@end
