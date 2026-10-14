#import <XCTest/XCTest.h>
#import "SPCommunityTrainingPolicy.h"

@interface SPCommunityTrainingPolicyTests : XCTestCase
@end

@implementation SPCommunityTrainingPolicyTests

- (NSDictionary *)statusWithJob:(NSDictionary *)job {
    return [SPCommunityTrainingPolicy statusFromJSON:@{
        @"consent" : @YES,
        @"logged_in" : @YES,
        @"server_configured" : @YES,
        @"credit_public" : @YES,
        @"has_outbox" : @NO,
        @"job" : job ?: @{},
    }];
}

- (NSDictionary *)status:(NSDictionary *)status with:(NSDictionary *)changes {
    NSMutableDictionary *copy = [status mutableCopy];
    [copy addEntriesFromDictionary:changes];
    return copy;
}

- (NSDictionary *)samplePreview {
    return @{
        @"manifest" : @{@"manifest" : @{@"base_version" : @3, @"num_examples" : @150}, @"signature" : @"sig"},
        @"contribution" : @{
            @"contribution" : @{
                @"base_version" : @3,
                @"data_seconds" : @2880.0,
                @"training_steps" : @600,
                @"num_clips" : @150,
                @"credit_public" : @YES,
            },
            @"signature" : @"sig2",
        },
        @"payload" : @{
            @"format" : @"safetensors",
            @"dtype" : @"float16",
            @"bytes" : @2516582,
            @"sha256" : @"ab12",
            @"tensors" : @96,
            @"parameters" : @1228800,
            @"examples" : @[ @"a.lora_A", @"a.lora_B" ],
        },
        @"total_bytes" : @2520000,
        @"not_sent" : @[ @"видео", @"звук" ],
    };
}

#pragma mark Process

- (void)testArguments {
    XCTAssertEqualObjects([SPCommunityTrainingPolicy argumentsForCommand:@"status" value:nil],
                          (@[ @"-m", @"client.community", @"status" ]));
    XCTAssertEqualObjects([SPCommunityTrainingPolicy argumentsForCommand:@"consent" value:@"on"],
                          (@[ @"-m", @"client.community", @"consent", @"on" ]));
}

- (void)testSetupProblem {
    XCTAssertNil([SPCommunityTrainingPolicy setupProblemForFederatedDirectory:@"/f" pythonExists:YES scriptExists:YES]);
    NSString *noVenv = [SPCommunityTrainingPolicy setupProblemForFederatedDirectory:@"/f" pythonExists:NO scriptExists:YES];
    XCTAssertTrue([noVenv containsString:@"./setup.sh"]);
    XCTAssertTrue([[SPCommunityTrainingPolicy installNote] containsString:@"«Установить»"]);
    NSString *noCheckout = [SPCommunityTrainingPolicy setupProblemForFederatedDirectory:@"/f" pythonExists:NO scriptExists:NO];
    XCTAssertTrue([noCheckout hasPrefix:@"Не найдена папка federated"]);
}

- (void)testJSONLinesSkipNoiseAndKeepNull {
    NSData *output = [@"warning: something\n{\"user_code\": \"ABCD-1234\"}\n\nnull\n{\"logged_in\": true}\n"
        dataUsingEncoding:NSUTF8StringEncoding];
    NSArray *values = [SPCommunityTrainingPolicy JSONValuesInOutput:output];
    XCTAssertEqual(values.count, 3u);
    XCTAssertEqualObjects(values[1], [NSNull null]);
    XCTAssertEqualObjects([SPCommunityTrainingPolicy lastJSONValueInOutput:output], @{@"logged_in" : @YES});
    XCTAssertEqualObjects([SPCommunityTrainingPolicy JSONValuesInOutput:nil], @[]);
}

- (void)testStatusParsingNormalisesJob {
    NSData *output = [@"{\"consent\": false, \"logged_in\": false, \"server_configured\": false, \"credit_public\": true, "
                      @"\"job\": {}, \"has_outbox\": false}"
        dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *status = [SPCommunityTrainingPolicy statusFromJSON:[SPCommunityTrainingPolicy lastJSONValueInOutput:output]];
    XCTAssertNotNil(status);
    XCTAssertEqual([SPCommunityTrainingPolicy stateOfStatus:status], SPCommunityJobStateIdle);
    NSDictionary *nullJob = [SPCommunityTrainingPolicy statusFromJSON:@{@"consent" : @NO, @"logged_in" : @NO, @"job" : [NSNull null]}];
    XCTAssertEqualObjects(nullJob[@"job"], @{});
    XCTAssertNil([SPCommunityTrainingPolicy statusFromJSON:@{@"signalled" : @YES}]);
    XCTAssertNil([SPCommunityTrainingPolicy statusFromJSON:@[]]);
    XCTAssertNil([SPCommunityTrainingPolicy statusFromJSON:nil]);
}

#pragma mark Login

- (void)testLoginCodeAcceptsOnlyGitHub {
    NSDictionary *code = [SPCommunityTrainingPolicy
        loginCodeFromJSON:@{@"user_code" : @"WDJB-MJHT", @"verification_uri" : @"https://github.com/login/device", @"expires_in" : @900}];
    XCTAssertEqualObjects(code[@"user_code"], @"WDJB-MJHT");
    XCTAssertEqualObjects(code[@"verification_uri"], @"https://github.com/login/device");
    XCTAssertNil(([SPCommunityTrainingPolicy loginCodeFromJSON:@{@"user_code" : @"WDJB-MJHT", @"verification_uri" : @"http://github.com/login/device"}]));
    XCTAssertNil(([SPCommunityTrainingPolicy loginCodeFromJSON:@{@"user_code" : @"WDJB-MJHT", @"verification_uri" : @"https://evil.example/github.com"}]));
    XCTAssertNil(([SPCommunityTrainingPolicy loginCodeFromJSON:@{@"user_code" : @"<script>", @"verification_uri" : @"https://github.com/login/device"}]));
    XCTAssertNil([SPCommunityTrainingPolicy loginCodeFromJSON:@{@"logged_in" : @YES}]);
}

- (void)testLoginResult {
    NSString *error = @"stale";
    XCTAssertEqualObjects([SPCommunityTrainingPolicy loginResultFromJSON:@{@"logged_in" : @YES} error:&error], @YES);
    XCTAssertNil(error);
    XCTAssertEqualObjects(([SPCommunityTrainingPolicy loginResultFromJSON:@{@"logged_in" : @NO, @"error" : @"код истёк"} error:&error]), @NO);
    XCTAssertEqualObjects(error, @"код истёк");
    XCTAssertNil([SPCommunityTrainingPolicy loginResultFromJSON:@{@"user_code" : @"X"} error:&error]);
}

#pragma mark Button

- (void)testButtonNeedsConsentLoginServerAndNoJob {
    NSDictionary *ready = [self statusWithJob:@{}];
    XCTAssertTrue([SPCommunityTrainingPolicy canStartWithStatus:ready]);
    XCTAssertNil([SPCommunityTrainingPolicy blockerForStatus:ready]);

    NSDictionary *noServer = [self status:ready with:@{@"server_configured" : @NO}];
    XCTAssertFalse([SPCommunityTrainingPolicy canStartWithStatus:noServer]);
    XCTAssertEqualObjects([SPCommunityTrainingPolicy blockerForStatus:noServer], @"Сервер обучения ещё не настроен");
    XCTAssertFalse([SPCommunityTrainingPolicy canLoginWithStatus:[self status:noServer with:@{@"logged_in" : @NO}]]);

    NSDictionary *noConsent = [self status:ready with:@{@"consent" : @NO}];
    XCTAssertFalse([SPCommunityTrainingPolicy canStartWithStatus:noConsent]);
    XCTAssertTrue([[SPCommunityTrainingPolicy blockerForStatus:noConsent] containsString:@"согласие"]);

    NSDictionary *loggedOut = [self status:ready with:@{@"logged_in" : @NO}];
    XCTAssertFalse([SPCommunityTrainingPolicy canStartWithStatus:loggedOut]);
    XCTAssertTrue([[SPCommunityTrainingPolicy blockerForStatus:loggedOut] hasPrefix:@"Войдите через GitHub"]);
    XCTAssertTrue([SPCommunityTrainingPolicy canLoginWithStatus:loggedOut]);
    XCTAssertFalse([SPCommunityTrainingPolicy canLoginWithStatus:ready]);

    NSDictionary *outbox = [self status:ready with:@{@"has_outbox" : @YES}];
    XCTAssertFalse([SPCommunityTrainingPolicy canStartWithStatus:outbox]);
    XCTAssertTrue([SPCommunityTrainingPolicy showsPreviewForStatus:outbox]);

    for (NSString *state in @[ @"running", @"sending" ]) {
        NSDictionary *active = [self statusWithJob:@{@"state" : state}];
        XCTAssertTrue([SPCommunityTrainingPolicy isActiveStatus:active]);
        XCTAssertFalse([SPCommunityTrainingPolicy canStartWithStatus:active]);
        XCTAssertNil([SPCommunityTrainingPolicy blockerForStatus:active]);
        XCTAssertFalse([SPCommunityTrainingPolicy showsPreviewForStatus:[self status:active with:@{@"has_outbox" : @YES}]]);
    }
    for (NSString *state in @[ @"done", @"error", @"cancelled", @"idle" ]) {
        XCTAssertTrue([SPCommunityTrainingPolicy canStartWithStatus:[self statusWithJob:@{@"state" : state}]], @"%@", state);
    }
    XCTAssertFalse([SPCommunityTrainingPolicy canStartWithStatus:nil]);
    XCTAssertNil([SPCommunityTrainingPolicy blockerForStatus:nil]);
}

- (void)testPreviewFallsBackToStateWithoutOutboxFlag {
    NSMutableDictionary *status = [[self statusWithJob:@{@"state" : @"ready_to_send"}] mutableCopy];
    XCTAssertFalse([SPCommunityTrainingPolicy showsPreviewForStatus:status]);  // has_outbox says the files are gone
    [status removeObjectForKey:@"has_outbox"];
    XCTAssertTrue([SPCommunityTrainingPolicy showsPreviewForStatus:status]);
}

#pragma mark Progress

- (void)testProgressLine {
    NSDictionary *training = [self statusWithJob:@{
        @"state" : @"running", @"stage" : @"train", @"stage_label" : @"Обучение", @"progress" : @0.424, @"paused" : @NO
    }];
    XCTAssertEqualObjects([SPCommunityTrainingPolicy progressLineForStatus:training paused:NO], @"Обучение — 42%");
    XCTAssertEqualObjects([SPCommunityTrainingPolicy progressLineForStatus:training paused:YES], @"Обучение — 42% · на паузе");
    XCTAssertEqualWithAccuracy([SPCommunityTrainingPolicy progressForStatus:training], 0.424, 1e-9);

    NSDictionary *task = [self statusWithJob:@{@"state" : @"running", @"stage" : @"task", @"stage_label" : @"Задание"}];
    XCTAssertEqualObjects([SPCommunityTrainingPolicy progressLineForStatus:task paused:NO], @"Задание…");
    NSDictionary *sending = [self statusWithJob:@{@"state" : @"sending", @"stage" : @"send"}];
    XCTAssertEqualObjects([SPCommunityTrainingPolicy progressLineForStatus:sending paused:NO], @"Отправка обновления…");
    NSDictionary *wild = [self statusWithJob:@{@"progress" : @7}];
    XCTAssertEqual([SPCommunityTrainingPolicy progressForStatus:wild], 1.0);
}

- (void)testPausedOverrideWinsUntilStatusCatchesUp {
    NSDictionary *running = [self statusWithJob:@{@"state" : @"running", @"paused" : @NO}];
    XCTAssertFalse([SPCommunityTrainingPolicy isPausedStatus:running override:nil]);
    XCTAssertTrue([SPCommunityTrainingPolicy isPausedStatus:running override:@YES]);
    NSDictionary *paused = [self statusWithJob:@{@"state" : @"running", @"paused" : @YES}];
    XCTAssertTrue([SPCommunityTrainingPolicy isPausedStatus:paused override:nil]);
    XCTAssertFalse([SPCommunityTrainingPolicy isPausedStatus:paused override:@NO]);
}

- (void)testDetailLine {
    NSDictionary *status = [self statusWithJob:@{
        @"task" : @{@"videos" : @5, @"segments" : @140},
        @"counts" : @{@"videos_ok" : @3, @"videos_failed" : @1, @"clips" : @1200, @"with_face" : @98},
    }];
    XCTAssertEqualObjects([SPCommunityTrainingPolicy detailLineForStatus:status],
                          @"Роликов в задании: 5 · скачано: 3 · не скачалось: 1 · отрезков: 1 200 · с лицом: 98");
    NSDictionary *noFailures = [self statusWithJob:@{@"counts" : @{@"videos_ok" : @2, @"videos_failed" : @0}}];
    XCTAssertEqualObjects([SPCommunityTrainingPolicy detailLineForStatus:noFailures], @"Скачано: 2");
    XCTAssertEqualObjects([SPCommunityTrainingPolicy detailLineForStatus:[self statusWithJob:@{}]], @"");
}

- (void)testResultMessages {
    XCTAssertEqualObjects(([SPCommunityTrainingPolicy resultMessageForStatus:[self statusWithJob:@{@"state" : @"error", @"message" : @"Нет сети"}]]),
                          @"Нет сети");
    XCTAssertEqualObjects([SPCommunityTrainingPolicy resultMessageForStatus:[self statusWithJob:@{@"state" : @"cancelled"}]],
                          @"Обучение отменено, ничего не отправлено");
    XCTAssertNotNil([SPCommunityTrainingPolicy resultMessageForStatus:[self statusWithJob:@{@"state" : @"done"}]]);
    XCTAssertNil([SPCommunityTrainingPolicy resultMessageForStatus:[self statusWithJob:@{}]]);
    XCTAssertNil(([SPCommunityTrainingPolicy resultMessageForStatus:[self statusWithJob:@{@"state" : @"running", @"message" : @"x"}]]));
}

#pragma mark Preview

- (void)testPreviewSummary {
    NSString *summary = [SPCommunityTrainingPolicy previewSummaryForPreview:[self samplePreview]];
    XCTAssertTrue([summary containsString:@"всего 2 460,9 КБ"], @"%@", summary);
    XCTAssertTrue([summary containsString:@"Обновление весов: 2 457,6 КБ, тензоров: 96, параметров: 1 228 800, float16 (safetensors)"],
                  @"%@", summary);
    XCTAssertTrue([summary containsString:@"Видео с лицом в обучении: 48 мин, шагов обучения: 600, отрезков: 150"], @"%@", summary);
    XCTAssertTrue([summary containsString:@"от которой шло обучение: 3."], @"%@", summary);
    XCTAssertTrue([summary containsString:@"появится в публичной таблице"], @"%@", summary);
    XCTAssertTrue([summary containsString:@"SHA-256 обновления весов: ab12"], @"%@", summary);
}

- (void)testPreviewSummaryToleratesMissingFields {
    NSString *summary = [SPCommunityTrainingPolicy previewSummaryForPreview:@{}];
    XCTAssertTrue([summary containsString:@"всего —"], @"%@", summary);
    XCTAssertFalse([summary containsString:@"таблице"]);
}

- (void)testPreviewTextHasFullJSONAndNotSent {
    NSString *text = [SPCommunityTrainingPolicy previewTextForPreview:[self samplePreview]];
    XCTAssertTrue([text containsString:@"Манифест (уходит целиком):\n{"]);
    XCTAssertTrue([text containsString:@"\"signature\" : \"sig2\""], @"%@", text);
    XCTAssertTrue([text containsString:@"\"training_steps\" : 600"], @"%@", text);
    XCTAssertTrue([text hasSuffix:@"Не отправляется: видео, звук."]);
    XCTAssertTrue([[SPCommunityTrainingPolicy previewTextForPreview:nil] containsString:@"«Не отправлять»"]);
}

#pragma mark Formatting

- (void)testNumbers {
    XCTAssertEqualObjects([SPCommunityTrainingPolicy groupedInteger:0], @"0");
    XCTAssertEqualObjects([SPCommunityTrainingPolicy groupedInteger:999], @"999");
    XCTAssertEqualObjects([SPCommunityTrainingPolicy groupedInteger:1234567], @"1 234 567");
    XCTAssertEqualObjects([SPCommunityTrainingPolicy groupedInteger:-1000], @"-1 000");
    XCTAssertEqualObjects([SPCommunityTrainingPolicy kilobytesText:524288], @"512,0 КБ");
    XCTAssertEqualObjects([SPCommunityTrainingPolicy kilobytesText:100], @"0,1 КБ");
    XCTAssertEqualObjects([SPCommunityTrainingPolicy durationText:2880], @"48 мин");
    XCTAssertEqualObjects([SPCommunityTrainingPolicy durationText:5400], @"1,5 ч");
    XCTAssertEqualObjects([SPCommunityTrainingPolicy durationText:-3], @"0 мин");
}

- (void)testPlural {
    NSString *(^videos)(long long) = ^NSString *(long long n) {
        return [SPCommunityTrainingPolicy count:n one:@"ролик" few:@"ролика" many:@"роликов"];
    };
    XCTAssertEqualObjects(videos(1), @"1 ролик");
    XCTAssertEqualObjects(videos(3), @"3 ролика");
    XCTAssertEqualObjects(videos(5), @"5 роликов");
    XCTAssertEqualObjects(videos(11), @"11 роликов");
    XCTAssertEqualObjects(videos(12), @"12 роликов");
    XCTAssertEqualObjects(videos(21), @"21 ролик");
    XCTAssertEqualObjects(videos(22), @"22 ролика");
}

- (void)testConsentTextNamesWhatLeaves {
    NSString *text = [SPCommunityTrainingPolicy consentAlertText];
    for (NSString *needle in @[ @"YouTube", @"интернет-адреса", @"охранником памяти", @"обновление весов", @"логин GitHub",
                                @"публичной таблице", @"никогда не используются", @"в любой момент" ]) {
        XCTAssertTrue([text containsString:needle], @"%@", needle);
    }
}

- (void)testPrettyJSON {
    XCTAssertEqualObjects([SPCommunityTrainingPolicy prettyJSON:nil], @"null");
    XCTAssertEqualObjects([SPCommunityTrainingPolicy prettyJSON:[NSNull null]], @"null");
    NSString *json = [SPCommunityTrainingPolicy prettyJSON:@{@"b" : @1, @"a" : @"https://x/y"}];
    XCTAssertTrue([json rangeOfString:@"\"a\""].location < [json rangeOfString:@"\"b\""].location);
    XCTAssertTrue([json containsString:@"https://x/y"]);
}

@end
