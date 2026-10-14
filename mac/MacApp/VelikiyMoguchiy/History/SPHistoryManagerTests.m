#import <XCTest/XCTest.h>
#import <sqlite3.h>
#import "SPHistoryManager.h"

@interface SPHistoryManagerTests : XCTestCase
@property (nonatomic, copy) NSString *dbPath;
@end

@implementation SPHistoryManagerTests

- (void)setUp {
    [super setUp];
    NSString *dir = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:@"velikiy-moguchiy-history-tests-%@",
                                        NSUUID.UUID.UUIDString]];
    self.dbPath = [dir stringByAppendingPathComponent:@"history.db"];
}

- (void)tearDown {
    [[NSFileManager defaultManager]
        removeItemAtPath:self.dbPath.stringByDeletingLastPathComponent error:nil];
    [super tearDown];
}

// ─── Helpers ────────────────────────────────────────────────────────

- (void)createLegacySchemaDatabase {
    [[NSFileManager defaultManager]
              createDirectoryAtPath:self.dbPath.stringByDeletingLastPathComponent
        withIntermediateDirectories:YES
                         attributes:nil
                              error:nil];
    sqlite3 *db = NULL;
    XCTAssertEqual(sqlite3_open(self.dbPath.UTF8String, &db), SQLITE_OK);
    const char *sql =
        "CREATE TABLE sessions ("
        "  id INTEGER PRIMARY KEY AUTOINCREMENT,"
        "  timestamp INTEGER NOT NULL,"
        "  duration_ms INTEGER NOT NULL,"
        "  text TEXT NOT NULL,"
        "  char_count INTEGER NOT NULL,"
        "  word_count INTEGER NOT NULL"
        ");"
        "INSERT INTO sessions (timestamp, duration_ms, text, char_count, word_count) "
        "VALUES (1752000000, 1200, 'legacy row', 0, 2);";
    XCTAssertEqual(sqlite3_exec(db, sql, NULL, NULL, NULL), SQLITE_OK);
    sqlite3_close(db);
}

- (NSArray<NSDictionary *> *)allRows {
    sqlite3 *db = NULL;
    XCTAssertEqual(sqlite3_open(self.dbPath.UTF8String, &db), SQLITE_OK);
    NSMutableArray *rows = [NSMutableArray array];
    sqlite3_stmt *stmt = NULL;
    const char *sql = "SELECT text, asr_text, asr_provider, llm_applied, "
                      "processed_for_dictionary FROM sessions ORDER BY id;";
    XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &stmt, NULL), SQLITE_OK);
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        const char *text = (const char *)sqlite3_column_text(stmt, 0);
        const char *asrText = (const char *)sqlite3_column_text(stmt, 1);
        const char *provider = (const char *)sqlite3_column_text(stmt, 2);
        [rows addObject:@{
            @"text" : text ? @(text) : NSNull.null,
            @"asr_text" : asrText ? @(asrText) : NSNull.null,
            @"asr_provider" : provider ? @(provider) : NSNull.null,
            @"llm_applied" : @(sqlite3_column_int(stmt, 3)),
            @"processed_for_dictionary" : @(sqlite3_column_int(stmt, 4)),
        }];
    }
    sqlite3_finalize(stmt);
    sqlite3_close(db);
    return rows;
}

// ─── Tests ──────────────────────────────────────────────────────────

- (void)testFreshDatabaseRecordsSessionWithMetadata {
    SPHistoryManager *manager = [[SPHistoryManager alloc] initWithDatabasePath:self.dbPath];
    [manager recordSessionWithDurationMs:900
                                    text:@"Anthropic released a model"
                                 asrText:@"and tropic released a model"
                             asrProvider:@"qwen"
                              llmApplied:YES];

    NSArray *rows = [self allRows];
    XCTAssertEqual(rows.count, 1u);
    XCTAssertEqualObjects(rows[0][@"text"], @"Anthropic released a model");
    XCTAssertEqualObjects(rows[0][@"asr_text"], @"and tropic released a model");
    XCTAssertEqualObjects(rows[0][@"asr_provider"], @"qwen");
    XCTAssertEqualObjects(rows[0][@"llm_applied"], @1);
    XCTAssertEqualObjects(rows[0][@"processed_for_dictionary"], @0);
}

- (void)testNilMetadataIsStoredAsNull {
    SPHistoryManager *manager = [[SPHistoryManager alloc] initWithDatabasePath:self.dbPath];
    [manager recordSessionWithDurationMs:500
                                    text:@"plain"
                                 asrText:nil
                             asrProvider:nil
                              llmApplied:NO];

    NSArray *rows = [self allRows];
    XCTAssertEqual(rows.count, 1u);
    XCTAssertEqualObjects(rows[0][@"asr_text"], NSNull.null);
    XCTAssertEqualObjects(rows[0][@"asr_provider"], NSNull.null);
    XCTAssertEqualObjects(rows[0][@"llm_applied"], @0);
}

- (void)testLegacyDatabaseIsMigratedInPlace {
    [self createLegacySchemaDatabase];

    SPHistoryManager *manager = [[SPHistoryManager alloc] initWithDatabasePath:self.dbPath];
    [manager recordSessionWithDurationMs:800
                                    text:@"new row"
                                 asrText:@"nu row"
                             asrProvider:@"qwen"
                              llmApplied:YES];

    NSArray *rows = [self allRows];
    XCTAssertEqual(rows.count, 2u);
    // Legacy row survives with NULL/default metadata
    XCTAssertEqualObjects(rows[0][@"text"], @"legacy row");
    XCTAssertEqualObjects(rows[0][@"asr_text"], NSNull.null);
    XCTAssertEqualObjects(rows[0][@"asr_provider"], NSNull.null);
    XCTAssertEqualObjects(rows[0][@"llm_applied"], @0);
    // New row carries full metadata
    XCTAssertEqualObjects(rows[1][@"asr_text"], @"nu row");
    XCTAssertEqualObjects(rows[1][@"asr_provider"], @"qwen");
    XCTAssertEqualObjects(rows[1][@"llm_applied"], @1);
}

- (void)testMigrationIsIdempotent {
    [self createLegacySchemaDatabase];
    (void)[[SPHistoryManager alloc] initWithDatabasePath:self.dbPath];
    // Re-opening an already-migrated database must not fail or duplicate columns
    SPHistoryManager *again = [[SPHistoryManager alloc] initWithDatabasePath:self.dbPath];
    XCTAssertNotNil([again aggregateStats]);
    XCTAssertEqual([self allRows].count, 1u);
}

- (void)testRecordingRowsKeepStatusAndAudioPath {
    [self createLegacySchemaDatabase];
    SPHistoryManager *manager = [[SPHistoryManager alloc] initWithDatabasePath:self.dbPath];
    [manager recordSessionWithDurationMs:700
                                    text:@""
                                 asrText:nil
                             asrProvider:nil
                              llmApplied:NO
                                  status:@"cancelled"
                               audioPath:@"/tmp/velikiy-moguchiy-test/1.m4a"];
    // Empty text without a recording is not worth a row
    [manager recordSessionWithDurationMs:100
                                    text:@""
                                 asrText:nil
                             asrProvider:nil
                              llmApplied:NO
                                  status:@"empty"
                               audioPath:nil];

    NSArray *sessions = [manager recentSessionsWithLimit:10];
    XCTAssertEqual(sessions.count, 2u);
    XCTAssertEqualObjects(sessions[0][@"status"], @"cancelled");
    XCTAssertEqualObjects(sessions[0][@"audio_path"], @"/tmp/velikiy-moguchiy-test/1.m4a");
    XCTAssertEqualObjects(sessions[1][@"status"], @"ok");
    XCTAssertEqualObjects(sessions[1][@"audio_path"], @"");
    XCTAssertEqual([manager aggregateStats].sessionCount, 1);
}

- (void)testDetachAudioPathDropsEmptyRowsAndClearsOthers {
    SPHistoryManager *manager = [[SPHistoryManager alloc] initWithDatabasePath:self.dbPath];
    [manager recordSessionWithDurationMs:700 text:@"" asrText:nil asrProvider:nil llmApplied:NO
                                  status:@"error" audioPath:@"/tmp/velikiy-moguchiy-test/a.m4a"];
    [manager recordSessionWithDurationMs:900 text:@"kept" asrText:nil asrProvider:nil llmApplied:NO
                                  status:@"ok" audioPath:@"/tmp/velikiy-moguchiy-test/b.m4a"];

    [manager detachAudioPath:@"/tmp/velikiy-moguchiy-test/a.m4a"];
    [manager detachAudioPath:@"/tmp/velikiy-moguchiy-test/b.m4a"];

    NSArray *sessions = [manager recentSessionsWithLimit:10];
    XCTAssertEqual(sessions.count, 1u);
    XCTAssertEqualObjects(sessions[0][@"text"], @"kept");
    XCTAssertEqualObjects(sessions[0][@"audio_path"], @"");
}

- (NSSet<NSString *> *)columnNames {
    sqlite3 *db = NULL;
    XCTAssertEqual(sqlite3_open(self.dbPath.UTF8String, &db), SQLITE_OK);
    NSMutableSet *names = [NSMutableSet set];
    sqlite3_stmt *stmt = NULL;
    XCTAssertEqual(sqlite3_prepare_v2(db, "PRAGMA table_info(sessions);", -1, &stmt, NULL), SQLITE_OK);
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        [names addObject:@((const char *)sqlite3_column_text(stmt, 1))];
    }
    sqlite3_finalize(stmt);
    sqlite3_close(db);
    return names;
}

- (void)testMigrationAddsErrorColumnsIdempotently {
    [self createLegacySchemaDatabase];
    (void)[[SPHistoryManager alloc] initWithDatabasePath:self.dbPath];
    NSSet *first = [self columnNames];
    XCTAssertTrue([first containsObject:@"error"]);
    XCTAssertTrue([first containsObject:@"app_bundle_id"]);
    XCTAssertTrue([first containsObject:@"original_text"]);

    SPHistoryManager *again = [[SPHistoryManager alloc] initWithDatabasePath:self.dbPath];
    XCTAssertEqualObjects([self columnNames], first);
    NSDictionary *legacy = [again recentSessionsWithLimit:1][0];
    XCTAssertEqualObjects(legacy[@"error"], @"");
    XCTAssertEqualObjects(legacy[@"app_bundle_id"], @"");
    XCTAssertEqualObjects(legacy[@"original_text"], @"");
}

- (void)testErrorReasonAndAppAreStoredWithSession {
    SPHistoryManager *manager = [[SPHistoryManager alloc] initWithDatabasePath:self.dbPath];
    int64_t identifier = [manager recordSessionWithDurationMs:4000 text:@"" asrText:nil asrProvider:nil
                                                   llmApplied:NO status:@"error"
                                                    audioPath:@"/tmp/velikiy-moguchiy-test/e.m4a"
                                                        error:@"сервис не ответил\ntimed out"
                                                  appBundleId:@"com.apple.Notes"];
    XCTAssertGreaterThan(identifier, 0);

    NSDictionary *row = [manager recentSessionsWithLimit:1][0];
    XCTAssertEqualObjects(row[@"id"], @(identifier));
    XCTAssertEqualObjects(row[@"error"], @"сервис не ответил\ntimed out");
    XCTAssertEqualObjects(row[@"app_bundle_id"], @"com.apple.Notes");
    XCTAssertEqualObjects([SPHistoryManager shortErrorReason:row[@"error"]], @"сервис не ответил");
}

- (void)testUpdateSessionKeepsOriginalTextAndClearsError {
    SPHistoryManager *manager = [[SPHistoryManager alloc] initWithDatabasePath:self.dbPath];
    int64_t identifier = [manager recordSessionWithDurationMs:4000 text:@"old text" asrText:@"old asr"
                                                  asrProvider:@"qwen" llmApplied:NO status:@"ok"
                                                    audioPath:@"/tmp/velikiy-moguchiy-test/u.m4a"
                                                        error:@"stale" appBundleId:nil];
    XCTAssertTrue([manager updateSessionWithId:identifier text:@"new text" status:@"ok" error:nil]);

    NSDictionary *row = [manager recentSessionsWithLimit:1][0];
    XCTAssertEqualObjects(row[@"text"], @"new text");
    XCTAssertEqualObjects(row[@"original_text"], @"old text");
    XCTAssertEqualObjects(row[@"error"], @"");
    XCTAssertEqualObjects(row[@"status"], @"ok");
    NSDictionary *stored = [self allRows][0];
    XCTAssertEqualObjects(stored[@"asr_text"], NSNull.null);

    // A second re-transcription keeps the very first text.
    XCTAssertTrue([manager updateSessionWithId:identifier text:@"newer text" status:nil error:nil]);
    row = [manager recentSessionsWithLimit:1][0];
    XCTAssertEqualObjects(row[@"text"], @"newer text");
    XCTAssertEqualObjects(row[@"original_text"], @"old text");
}

- (void)testVoiceEditKeepsTheReplacedSelectionAsOriginalText {
    SPHistoryManager *manager = [[SPHistoryManager alloc] initWithDatabasePath:self.dbPath];
    int64_t identifier = [manager recordSessionWithDurationMs:3000 text:@"Короткий текст." asrText:nil
                                                  asrProvider:@"qwen" llmApplied:NO status:@"ok"
                                                    audioPath:nil error:nil appBundleId:@"com.apple.Notes"
                                                 originalText:@"Это очень длинный исходный текст."];
    XCTAssertGreaterThan(identifier, 0);
    NSDictionary *row = [manager recentSessionsWithLimit:1][0];
    XCTAssertEqualObjects(row[@"text"], @"Короткий текст.");
    XCTAssertEqualObjects(row[@"original_text"], @"Это очень длинный исходный текст.");

    // A plain session has no original.
    [manager recordSessionWithDurationMs:1000 text:@"обычная" asrText:nil asrProvider:nil llmApplied:NO];
    XCTAssertEqualObjects([manager recentSessionsWithLimit:1][0][@"original_text"], @"");
}

- (void)testUpdateSessionOfEmptyRowHasNoOriginalAndNilTextKeepsText {
    SPHistoryManager *manager = [[SPHistoryManager alloc] initWithDatabasePath:self.dbPath];
    int64_t failed = [manager recordSessionWithDurationMs:4000 text:@"" asrText:nil asrProvider:nil
                                               llmApplied:NO status:@"error"
                                                audioPath:@"/tmp/velikiy-moguchiy-test/f.m4a"
                                                    error:@"boom" appBundleId:nil];
    XCTAssertTrue([manager updateSessionWithId:failed text:@"recovered" status:@"ok" error:nil]);
    NSDictionary *row = [manager recentSessionsWithLimit:1][0];
    XCTAssertEqualObjects(row[@"text"], @"recovered");
    XCTAssertEqualObjects(row[@"original_text"], @"");
    XCTAssertEqual([manager aggregateStats].sessionCount, 1);

    XCTAssertTrue([manager updateSessionWithId:failed text:nil status:nil error:@"later failure"]);
    row = [manager recentSessionsWithLimit:1][0];
    XCTAssertEqualObjects(row[@"text"], @"recovered");
    XCTAssertEqualObjects(row[@"error"], @"later failure");

    XCTAssertFalse([manager updateSessionWithId:9999 text:@"x" status:@"ok" error:nil]);
}

- (void)testErrorTextNeverContainsApiKeys {
    NSString *scrubbed = [SPHistoryManager scrubbedSecrets:
        @"Incorrect API key provided: sk-abc123DEF456. Authorization: Bearer abc.DEF-123 and a task-force"];
    XCTAssertFalse([scrubbed containsString:@"abc123DEF456"]);
    XCTAssertFalse([scrubbed containsString:@"abc.DEF-123"]);
    XCTAssertTrue([scrubbed containsString:@"sk-***"]);
    XCTAssertTrue([scrubbed containsString:@"task-force"]);

    SPHistoryManager *manager = [[SPHistoryManager alloc] initWithDatabasePath:self.dbPath];
    [manager recordSessionWithDurationMs:1000 text:@"" asrText:nil asrProvider:nil llmApplied:NO
                                  status:@"error" audioPath:@"/tmp/velikiy-moguchiy-test/k.m4a"
                                   error:@"key sk-SECRET123 rejected" appBundleId:nil];
    NSString *stored = [manager recentSessionsWithLimit:1][0][@"error"];
    XCTAssertFalse([stored containsString:@"SECRET123"]);
}

- (void)testErrorReasonTruncatesProviderMessage {
    NSString *longMessage = [@"" stringByPaddingToLength:1000 withString:@"ж" startingAtIndex:0];
    NSString *reason = [SPHistoryManager errorReasonWithSummary:@"ошибка распознавания"
                                                providerMessage:longMessage];
    NSArray *lines = [reason componentsSeparatedByString:@"\n"];
    XCTAssertEqual(lines.count, 2u);
    XCTAssertEqualObjects(lines[0], @"ошибка распознавания");
    XCTAssertLessThanOrEqual([lines[1] length], 301u);
    XCTAssertEqualObjects([SPHistoryManager errorReasonWithSummary:@"только итог" providerMessage:nil],
                          @"только итог");
}

@end
