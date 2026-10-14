#import <Foundation/Foundation.h>

/// Watches the Play/Pause media key (wired-headset inline button, keyboard F8)
/// and swallows it so it toggles dictation instead of Music playback.
@interface SPMediaKeyMonitor : NSObject

- (instancetype)initWithHandler:(void (^)(void))handler;
- (BOOL)start;
- (void)stop;

@end
