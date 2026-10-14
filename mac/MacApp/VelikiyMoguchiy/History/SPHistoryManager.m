#import "SPHistoryManager.h"
#import "SPAppPaths.h"
#import <sqlite3.h>
#import <sys/stat.h>
#import <errno.h>
#import <string.h>

@implementation SPHistoryStats
@end

@interface SPHistoryManager () {
    sqlite3 *_db;
}
@end

NSNotificationName const SPHistoryDidChangeNotification = @"SPHistoryDidChangeNotification";

@implementation SPHistoryManager

+ (instancetype)sharedManager {
    static SPHistoryManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SPHistoryManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    NSString *dir = SPAppDataDirectory();
    return [self initWithDatabasePath:[dir stringByAppendingPathComponent:@"history.db"]];
}

- (instancetype)initWithDatabasePath:(NSString *)dbPath {
    self = [super init];
    if (self) {
        [self openDatabaseAtPath:dbPath];
    }
    return self;
}

- (void)openDatabaseAtPath:(NSString *)dbPath {
    // The database stores everything the user has dictated — owner-only
    // permissions on the directory and file (matches the config hardening).
    [[NSFileManager defaultManager] createDirectoryAtPath:dbPath.stringByDeletingLastPathComponent
                              withIntermediateDirectories:YES
                                               attributes:@{NSFilePosixPermissions : @(0700)}
                                                    error:nil];

    if (sqlite3_open(dbPath.UTF8String, &_db) != SQLITE_OK) {
        // sqlite3_open returns a handle even on failure; it must be closed
        // or it (and its resources) leak until process exit.
        NSLog(@"[VelikiyMoguchiy] Failed to open history database: %s", sqlite3_errmsg(_db));
        if (_db) {
            sqlite3_close_v2(_db);
        }
        _db = NULL;
        return;
    }
    // The database holds every transcript; a failure to make it owner-only
    // is worth surfacing rather than silently continuing world-readable.
    if (chmod(dbPath.UTF8String, 0600) != 0) {
        NSLog(@"[VelikiyMoguchiy] WARNING: could not restrict history database permissions (%s): %s",
              dbPath.UTF8String, strerror(errno));
    }

    const char *sql =
        "CREATE TABLE IF NOT EXISTS sessions ("
        "  id INTEGER PRIMARY KEY AUTOINCREMENT,"
        "  timestamp INTEGER NOT NULL,"
        "  duration_ms INTEGER NOT NULL,"
        "  text TEXT NOT NULL,"
        "  char_count INTEGER NOT NULL,"
        "  word_count INTEGER NOT NULL"
        ");";

    char *errMsg = NULL;
    if (sqlite3_exec(_db, sql, NULL, NULL, &errMsg) != SQLITE_OK) {
        NSLog(@"[VelikiyMoguchiy] Failed to create sessions table: %s", errMsg);
        sqlite3_free(errMsg);
    }

    [self migrateSchema];
}

/// Add columns introduced after the initial release. Databases created before
/// the migration lack them; ALTER TABLE is a no-op-safe way to catch up.
/// `asr_text` / `asr_provider` stay NULL for sessions recorded before the
/// upgrade — downstream consumers (dictionary suggestions) must skip those.
- (void)migrateSchema {
    NSSet<NSString *> *existing = [self sessionColumnNames];

    NSDictionary<NSString *, NSString *> *wanted = @{
        @"asr_text" : @"TEXT",
        @"asr_provider" : @"TEXT",
        @"llm_applied" : @"INTEGER NOT NULL DEFAULT 0",
        @"processed_for_dictionary" : @"INTEGER NOT NULL DEFAULT 0",
        @"audio_path" : @"TEXT",
        @"status" : @"TEXT NOT NULL DEFAULT 'ok'",
        @"error" : @"TEXT",
        @"app_bundle_id" : @"TEXT",
        @"original_text" : @"TEXT",
    };

    for (NSString *column in wanted) {
        if ([existing containsObject:column]) continue;

        NSString *alter = [NSString stringWithFormat:@"ALTER TABLE sessions ADD COLUMN %@ %@;",
                           column, wanted[column]];
        char *errMsg = NULL;
        if (sqlite3_exec(_db, alter.UTF8String, NULL, NULL, &errMsg) != SQLITE_OK) {
            NSLog(@"[VelikiyMoguchiy] Failed to add column %@: %s", column, errMsg);
            sqlite3_free(errMsg);
        } else {
            NSLog(@"[VelikiyMoguchiy] History schema migrated: added column %@", column);
        }
    }
}

- (NSSet<NSString *> *)sessionColumnNames {
    NSMutableSet<NSString *> *columns = [NSMutableSet set];
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(_db, "PRAGMA table_info(sessions);", -1, &stmt, NULL) == SQLITE_OK) {
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            const char *name = (const char *)sqlite3_column_text(stmt, 1);
            if (name) [columns addObject:[NSString stringWithUTF8String:name]];
        }
    }
    sqlite3_finalize(stmt);
    return columns;
}

- (void)recordSessionWithDurationMs:(NSInteger)durationMs
                               text:(NSString *)text
                            asrText:(NSString *)asrText
                        asrProvider:(NSString *)asrProvider
                         llmApplied:(BOOL)llmApplied {
    [self recordSessionWithDurationMs:durationMs
                                 text:text
                              asrText:asrText
                          asrProvider:asrProvider
                           llmApplied:llmApplied
                               status:@"ok"
                            audioPath:nil];
}

- (void)recordSessionWithDurationMs:(NSInteger)durationMs
                               text:(NSString *)text
                            asrText:(NSString *)asrText
                        asrProvider:(NSString *)asrProvider
                         llmApplied:(BOOL)llmApplied
                             status:(NSString *)status
                          audioPath:(NSString *)audioPath {
    [self recordSessionWithDurationMs:durationMs
                                 text:text
                              asrText:asrText
                          asrProvider:asrProvider
                           llmApplied:llmApplied
                               status:status
                            audioPath:audioPath
                                error:nil
                          appBundleId:nil];
}

static void bindOptionalText(sqlite3_stmt *stmt, int index, NSString *value) {
    if (value.length > 0) {
        sqlite3_bind_text(stmt, index, value.UTF8String, -1, SQLITE_TRANSIENT);
    } else {
        sqlite3_bind_null(stmt, index);
    }
}

- (int64_t)recordSessionWithDurationMs:(NSInteger)durationMs
                                  text:(NSString *)text
                               asrText:(NSString *)asrText
                           asrProvider:(NSString *)asrProvider
                            llmApplied:(BOOL)llmApplied
                                status:(NSString *)status
                             audioPath:(NSString *)audioPath
                                 error:(NSString *)error
                           appBundleId:(NSString *)appBundleId {
    return [self recordSessionWithDurationMs:durationMs
                                        text:text
                                     asrText:asrText
                                 asrProvider:asrProvider
                                  llmApplied:llmApplied
                                      status:status
                                   audioPath:audioPath
                                       error:error
                                 appBundleId:appBundleId
                                originalText:nil];
}

- (int64_t)recordSessionWithDurationMs:(NSInteger)durationMs
                                  text:(NSString *)text
                               asrText:(NSString *)asrText
                           asrProvider:(NSString *)asrProvider
                            llmApplied:(BOOL)llmApplied
                                status:(NSString *)status
                             audioPath:(NSString *)audioPath
                                 error:(NSString *)error
                           appBundleId:(NSString *)appBundleId
                          originalText:(NSString *)originalText {
    if (!_db) return 0;
    text = text ?: @"";
    status = status.length > 0 ? status : @"ok";
    // A session without text is only worth a row when it carries a recording.
    if (text.length == 0 && audioPath.length == 0) return 0;

    NSInteger charCount = 0;
    NSInteger wordCount = 0;
    [self countText:text charCount:&charCount wordCount:&wordCount];

    const char *sql = "INSERT INTO sessions (timestamp, duration_ms, text, char_count, word_count, "
                      "asr_text, asr_provider, llm_applied, audio_path, status, error, app_bundle_id, "
                      "original_text) "
                      "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);";
    sqlite3_stmt *stmt = NULL;
    int64_t rowId = 0;

    if (sqlite3_prepare_v2(_db, sql, -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(stmt, 1, (sqlite3_int64)[[NSDate date] timeIntervalSince1970]);
        sqlite3_bind_int64(stmt, 2, (sqlite3_int64)durationMs);
        sqlite3_bind_text(stmt, 3, text.UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(stmt, 4, (sqlite3_int64)charCount);
        sqlite3_bind_int64(stmt, 5, (sqlite3_int64)wordCount);
        bindOptionalText(stmt, 6, asrText);
        bindOptionalText(stmt, 7, asrProvider);
        sqlite3_bind_int(stmt, 8, llmApplied ? 1 : 0);
        bindOptionalText(stmt, 9, audioPath);
        sqlite3_bind_text(stmt, 10, status.UTF8String, -1, SQLITE_TRANSIENT);
        bindOptionalText(stmt, 11, [SPHistoryManager scrubbedSecrets:error]);
        bindOptionalText(stmt, 12, appBundleId);
        bindOptionalText(stmt, 13, originalText);

        if (sqlite3_step(stmt) == SQLITE_DONE) {
            rowId = (int64_t)sqlite3_last_insert_rowid(_db);
        } else {
            NSLog(@"[VelikiyMoguchiy] Failed to insert session: %s", sqlite3_errmsg(_db));
        }
    }
    sqlite3_finalize(stmt);

    NSLog(@"[VelikiyMoguchiy] History recorded — duration:%ldms chars:%ld words:%ld provider:%@ llm:%d status:%@",
          (long)durationMs, (long)charCount, (long)wordCount,
          asrProvider.length > 0 ? asrProvider : @"?", llmApplied ? 1 : 0, status);

    if (rowId > 0) [self postChangeNotification];
    return rowId;
}

- (BOOL)updateSessionWithId:(int64_t)sessionId
                       text:(NSString *)text
                     status:(NSString *)status
                      error:(NSString *)error {
    if (!_db || sessionId <= 0) return NO;

    NSInteger charCount = 0;
    NSInteger wordCount = 0;
    if (text) [self countText:text charCount:&charCount wordCount:&wordCount];

    const char *sql =
        "UPDATE sessions SET "
        "original_text = CASE WHEN ?1 IS NOT NULL AND original_text IS NULL "
        "                     AND text != '' AND text != ?1 THEN text ELSE original_text END, "
        "asr_text = CASE WHEN ?1 IS NOT NULL AND text != ?1 THEN NULL ELSE asr_text END, "
        "text = COALESCE(?1, text), "
        "char_count = CASE WHEN ?1 IS NOT NULL THEN ?2 ELSE char_count END, "
        "word_count = CASE WHEN ?1 IS NOT NULL THEN ?3 ELSE word_count END, "
        "status = COALESCE(?4, status), "
        "error = ?5 "
        "WHERE id = ?6;";
    sqlite3_stmt *stmt = NULL;
    BOOL updated = NO;
    if (sqlite3_prepare_v2(_db, sql, -1, &stmt, NULL) == SQLITE_OK) {
        if (text) {
            sqlite3_bind_text(stmt, 1, text.UTF8String, -1, SQLITE_TRANSIENT);
        } else {
            sqlite3_bind_null(stmt, 1);
        }
        sqlite3_bind_int64(stmt, 2, (sqlite3_int64)charCount);
        sqlite3_bind_int64(stmt, 3, (sqlite3_int64)wordCount);
        bindOptionalText(stmt, 4, status);
        bindOptionalText(stmt, 5, [SPHistoryManager scrubbedSecrets:error]);
        sqlite3_bind_int64(stmt, 6, (sqlite3_int64)sessionId);
        if (sqlite3_step(stmt) == SQLITE_DONE) {
            updated = sqlite3_changes(_db) > 0;
        } else {
            NSLog(@"[VelikiyMoguchiy] Failed to update session: %s", sqlite3_errmsg(_db));
        }
    }
    sqlite3_finalize(stmt);
    if (updated) [self postChangeNotification];
    return updated;
}

#pragma mark - Error reasons

static const NSUInteger kProviderMessageLimit = 300;

static NSString *truncated(NSString *text, NSUInteger limit) {
    if (text.length <= limit) return text;
    NSRange safe = [text rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, limit)];
    return [[text substringWithRange:safe] stringByAppendingString:@"…"];
}

+ (NSString *)scrubbedSecrets:(NSString *)message {
    if (message.length == 0) return message;
    static NSRegularExpression *keys;
    static NSRegularExpression *bearer;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = [NSRegularExpression regularExpressionWithPattern:@"(?<![A-Za-z0-9])sk-[A-Za-z0-9_-]+"
                                                         options:0 error:nil];
        bearer = [NSRegularExpression regularExpressionWithPattern:@"(bearer\\s+)[A-Za-z0-9._~+/=-]+"
                                                           options:NSRegularExpressionCaseInsensitive
                                                             error:nil];
    });
    NSMutableString *result = [message mutableCopy];
    [keys replaceMatchesInString:result options:0 range:NSMakeRange(0, result.length)
                    withTemplate:@"sk-***"];
    [bearer replaceMatchesInString:result options:0 range:NSMakeRange(0, result.length)
                      withTemplate:@"$1***"];
    return result;
}

+ (NSString *)errorReasonWithSummary:(NSString *)summary providerMessage:(NSString *)providerMessage {
    NSCharacterSet *trim = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSString *head = [[self scrubbedSecrets:summary] ?: @"" stringByTrimmingCharactersInSet:trim];
    head = [[head componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]
            componentsJoinedByString:@" "];
    NSString *detail = [[self scrubbedSecrets:providerMessage] ?: @"" stringByTrimmingCharactersInSet:trim];
    detail = truncated(detail, kProviderMessageLimit);
    if (head.length == 0) return detail;
    if (detail.length == 0 || [detail isEqualToString:head]) return head;
    return [NSString stringWithFormat:@"%@\n%@", head, detail];
}

+ (NSString *)shortErrorReason:(NSString *)error {
    if (error.length == 0) return @"";
    NSRange newline = [error rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]];
    return newline.location == NSNotFound ? error : [error substringToIndex:newline.location];
}

- (void)countText:(NSString *)text charCount:(NSInteger *)outChars wordCount:(NSInteger *)outWords {
    NSInteger chars = 0;
    NSInteger words = 0;
    BOOL inWord = NO;

    for (NSUInteger i = 0; i < text.length; i++) {
        unichar ch = [text characterAtIndex:i];

        // CJK Unified Ideographs and extensions
        if ((ch >= 0x4E00 && ch <= 0x9FFF) ||   // CJK Unified
            (ch >= 0x3400 && ch <= 0x4DBF) ||   // CJK Extension A
            (ch >= 0xF900 && ch <= 0xFAFF)) {   // CJK Compatibility
            chars++;
            if (inWord) {
                words++;
                inWord = NO;
            }
        } else if ((ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') ||
                   (ch >= '0' && ch <= '9') || ch == '\'') {
            // Latin alphanumeric — part of a word
            if (!inWord) {
                inWord = YES;
            }
        } else {
            // Whitespace, punctuation, etc.
            if (inWord) {
                words++;
                inWord = NO;
            }
        }
    }
    if (inWord) {
        words++;
    }

    *outChars = chars;
    *outWords = words;
}

- (SPHistoryStats *)aggregateStats {
    SPHistoryStats *stats = [[SPHistoryStats alloc] init];
    if (!_db) return stats;

    const char *sql = "SELECT COUNT(*), COALESCE(SUM(duration_ms),0), "
                      "COALESCE(SUM(char_count),0), COALESCE(SUM(word_count),0) "
                      "FROM sessions WHERE status = 'ok';";
    sqlite3_stmt *stmt = NULL;

    if (sqlite3_prepare_v2(_db, sql, -1, &stmt, NULL) == SQLITE_OK) {
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            stats.sessionCount = (NSInteger)sqlite3_column_int64(stmt, 0);
            stats.totalDurationMs = (NSInteger)sqlite3_column_int64(stmt, 1);
            stats.totalCharCount = (NSInteger)sqlite3_column_int64(stmt, 2);
            stats.totalWordCount = (NSInteger)sqlite3_column_int64(stmt, 3);
        }
    }
    sqlite3_finalize(stmt);

    return stats;
}

- (NSArray<NSDictionary *> *)recentSessionsWithLimit:(NSUInteger)limit {
    NSMutableArray<NSDictionary *> *sessions = [NSMutableArray array];
    if (!_db) return sessions;

    const char *sql = "SELECT id, timestamp, duration_ms, text, status, audio_path, "
                      "error, app_bundle_id, original_text "
                      "FROM sessions ORDER BY id DESC LIMIT ?;";
    sqlite3_stmt *stmt = NULL;

    if (sqlite3_prepare_v2(_db, sql, -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(stmt, 1, (sqlite3_int64)limit);
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            const char *text = (const char *)sqlite3_column_text(stmt, 3);
            if (!text) continue;
            const char *status = (const char *)sqlite3_column_text(stmt, 4);
            const char *audioPath = (const char *)sqlite3_column_text(stmt, 5);
            const char *error = (const char *)sqlite3_column_text(stmt, 6);
            const char *appBundleId = (const char *)sqlite3_column_text(stmt, 7);
            const char *originalText = (const char *)sqlite3_column_text(stmt, 8);
            NSTimeInterval ts = (NSTimeInterval)sqlite3_column_int64(stmt, 1);
            [sessions addObject:@{
                @"id" : @(sqlite3_column_int64(stmt, 0)),
                @"timestamp" : [NSDate dateWithTimeIntervalSince1970:ts],
                @"duration_ms" : @(sqlite3_column_int64(stmt, 2)),
                @"text" : [NSString stringWithUTF8String:text] ?: @"",
                @"status" : status ? ([NSString stringWithUTF8String:status] ?: @"ok") : @"ok",
                @"audio_path" : audioPath ? ([NSString stringWithUTF8String:audioPath] ?: @"") : @"",
                @"error" : error ? ([NSString stringWithUTF8String:error] ?: @"") : @"",
                @"app_bundle_id" : appBundleId ? ([NSString stringWithUTF8String:appBundleId] ?: @"") : @"",
                @"original_text" : originalText ? ([NSString stringWithUTF8String:originalText] ?: @"") : @"",
            }];
        }
    }
    sqlite3_finalize(stmt);

    return sessions;
}

- (void)deleteSessionWithId:(int64_t)sessionId {
    if (!_db) return;
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(_db, "DELETE FROM sessions WHERE id = ?;", -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(stmt, 1, sessionId);
        if (sqlite3_step(stmt) != SQLITE_DONE) {
            NSLog(@"[VelikiyMoguchiy] Failed to delete session: %s", sqlite3_errmsg(_db));
        }
    }
    sqlite3_finalize(stmt);
    [self postChangeNotification];
}

- (void)detachAudioPath:(NSString *)audioPath {
    if (!_db || audioPath.length == 0) return;
    // Rows that exist only for their recording (cancelled / failed / empty)
    // have nothing left to show once the file is gone.
    const char *statements[] = {
        "DELETE FROM sessions WHERE audio_path = ? AND text = '';",
        "UPDATE sessions SET audio_path = NULL WHERE audio_path = ?;",
    };
    for (size_t i = 0; i < sizeof(statements) / sizeof(statements[0]); i++) {
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(_db, statements[i], -1, &stmt, NULL) == SQLITE_OK) {
            sqlite3_bind_text(stmt, 1, audioPath.UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_step(stmt);
        }
        sqlite3_finalize(stmt);
    }
    [self postChangeNotification];
}

- (void)postChangeNotification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:SPHistoryDidChangeNotification
                                                            object:self];
    });
}

- (void)dealloc {
    if (_db) {
        sqlite3_close(_db);
        _db = NULL;
    }
}

@end
