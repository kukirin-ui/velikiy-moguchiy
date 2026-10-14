#import "SPMediaKeyMonitor.h"
#import <AppKit/AppKit.h>

// IOKit hidsystem/ev_keymap.h. Media keys arrive as NSSystemDefined events with
// subtype 8 (aux control buttons); data1 carries the key type in its high 16
// bits and the key state in bits 8-15 (0x0A down, 0x0B up). Decoding follows
// OpenLess' system_defined_event_payload.
static const int16_t kAuxControlButtonsSubtype = 8;
static const uint16_t kKeyTypePlay = 16;
static const uint8_t kKeyStateDown = 0x0A;

@interface SPMediaKeyMonitor ()
@property (nonatomic, copy) void (^handler)(void);
@property (nonatomic, assign) CFMachPortRef tap;
@property (nonatomic, assign) CFRunLoopSourceRef source;
@end

static CGEventRef mediaKeyTapCallback(CGEventTapProxy proxy, CGEventType type,
                                      CGEventRef event, void *userInfo) {
    SPMediaKeyMonitor *monitor = (__bridge SPMediaKeyMonitor *)userInfo;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (monitor.tap) CGEventTapEnable(monitor.tap, true);
        return event;
    }
    if (type != NSEventTypeSystemDefined) return event;

    NSEvent *nsEvent = [NSEvent eventWithCGEvent:event];
    if (nsEvent.subtype != kAuxControlButtonsSubtype) return event;
    NSInteger data1 = nsEvent.data1;
    uint16_t keyType = (uint16_t)(((uint64_t)data1 >> 16) & 0xffff);
    if (keyType != kKeyTypePlay) return event;

    uint8_t keyState = (uint8_t)((data1 >> 8) & 0xff);
    if (keyState == kKeyStateDown) {
        void (^handler)(void) = monitor.handler;
        dispatch_async(dispatch_get_main_queue(), ^{ if (handler) handler(); });
    }
    return NULL;
}

@implementation SPMediaKeyMonitor

- (instancetype)initWithHandler:(void (^)(void))handler {
    if ((self = [super init])) {
        _handler = [handler copy];
    }
    return self;
}

- (BOOL)start {
    if (self.tap) return YES;
    CGEventMask mask = CGEventMaskBit(NSEventTypeSystemDefined);
    CFMachPortRef tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
                                         kCGEventTapOptionDefault, mask,
                                         mediaKeyTapCallback, (__bridge void *)self);
    if (!tap) {
        NSLog(@"[VelikiyMoguchiy] Media key tap could not be created (Accessibility / Input Monitoring?)");
        return NO;
    }
    self.tap = tap;
    self.source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), self.source, kCFRunLoopCommonModes);
    CGEventTapEnable(tap, true);
    NSLog(@"[VelikiyMoguchiy] Media key monitor active (Play/Pause toggles dictation)");
    return YES;
}

- (void)stop {
    if (!self.tap) return;
    CGEventTapEnable(self.tap, false);
    CFRunLoopRemoveSource(CFRunLoopGetMain(), self.source, kCFRunLoopCommonModes);
    CFRelease(self.source);
    CFRelease(self.tap);
    self.source = NULL;
    self.tap = NULL;
}

- (void)dealloc {
    [self stop];
}

@end
