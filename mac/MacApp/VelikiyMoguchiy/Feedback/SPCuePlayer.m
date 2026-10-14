#import "SPCuePlayer.h"
#import <AppKit/AppKit.h>
#import "velikiy_moguchiy_core.h"

@interface SPCuePlayer ()

@property (nonatomic, assign) BOOL startSoundEnabled;
@property (nonatomic, assign) BOOL stopSoundEnabled;
@property (nonatomic, assign) BOOL errorSoundEnabled;

@end

@implementation SPCuePlayer

- (instancetype)init {
    self = [super init];
    if (self) {
        _startSoundEnabled = YES;
        _stopSoundEnabled = YES;
        _errorSoundEnabled = YES;
    }
    return self;
}

- (void)reloadFeedbackConfig {
    struct SPFeedbackConfig cfg = sp_core_get_feedback_config();
    self.startSoundEnabled = cfg.start_sound;
    self.stopSoundEnabled = cfg.stop_sound;
    self.errorSoundEnabled = cfg.error_sound;
}

- (void)playStart {
    if (self.startSoundEnabled) {
        [self playSystemSound:@"Tink"];
    }
}

- (void)playStop {
    if (self.stopSoundEnabled) {
        [self playSystemSound:@"Pop"];
    }
}

- (void)playError {
    if (self.errorSoundEnabled) {
        [self playSystemSound:@"Basso"];
    }
}

- (void)playSystemSound:(NSString *)name {
    NSSound *sound = [NSSound soundNamed:name];
    if (sound) {
        [sound play];
    }
}

@end
