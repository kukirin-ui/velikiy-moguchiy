#import <Foundation/Foundation.h>

/// Keeps an AAC (.m4a) copy of every dictation's microphone audio under
/// ~/.velikiy-moguchiy/recordings/YYYY-MM-DD/<unix-ms>.m4a and expires old files.
/// All file work happens on a private serial queue, so `appendPCM:` is safe to
/// call from the audio thread.
@interface SPRecordingManager : NSObject

+ (instancetype)sharedManager;

/// ~/.velikiy-moguchiy/recordings
+ (NSString *)recordingsDirectory;

/// Open a new recording (closing any previous one) when history.save_recordings
/// is on. Returns the path the file will be written to, or nil when recording
/// is disabled.
- (NSString *)beginRecording;

/// Append 16 kHz mono PCM Int16 LE audio to the current recording.
- (void)appendPCM:(const void *)buffer length:(uint32_t)length;

/// Close the current recording, if any.
- (void)endRecording;

/// Close the current recording and wait until the file is finalized.
- (void)endRecordingAndWait;

/// Waits for pending writes of `path` and returns it if a non-empty file
/// exists there, nil otherwise.
- (NSString *)existingPathForRecording:(NSString *)path;

/// Delete recordings older than history.recordings_retention_days now and
/// every 6 hours afterwards.
- (void)startRetention;

@end
