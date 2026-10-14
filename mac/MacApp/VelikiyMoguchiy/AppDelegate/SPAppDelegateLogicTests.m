#import <XCTest/XCTest.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import "SPHotkeyMonitor.h"

@interface SPAppDelegateSessionStateTestProxy : NSObject
@property (nonatomic, copy) NSString *sessionState;
@property (nonatomic, assign) BOOL hasPendingConfigReload;
@property (nonatomic, assign) NSInteger reloadCount;
- (void)reloadConfigAndApplyHotkey;
- (void)reloadConfigAndApplyHotkeyIfSafe;
- (void)applyDeferredConfigReloadIfNeeded;
@end

static BOOL sessionStateAllowsConfigReloadForTest(NSString *state) {
    if (state.length == 0) return YES;
    return [state isEqualToString:@"idle"] ||
           [state isEqualToString:@"completed"] ||
           [state isEqualToString:@"failed"] ||
           [state isEqualToString:@"error"];
}

@implementation SPAppDelegateSessionStateTestProxy

- (void)reloadConfigAndApplyHotkey {
    self.reloadCount += 1;
}

- (void)reloadConfigAndApplyHotkeyIfSafe {
    if (!sessionStateAllowsConfigReloadForTest(self.sessionState)) {
        self.hasPendingConfigReload = YES;
        return;
    }

    self.hasPendingConfigReload = NO;
    [self reloadConfigAndApplyHotkey];
}

- (void)applyDeferredConfigReloadIfNeeded {
    if (!self.hasPendingConfigReload) return;
    if (!sessionStateAllowsConfigReloadForTest(self.sessionState)) return;

    self.hasPendingConfigReload = NO;
    [self reloadConfigAndApplyHotkey];
}

@end

@interface SPHotkeyMonitorTestDelegate : NSObject <SPHotkeyMonitorDelegate>
@property (nonatomic, assign) NSInteger holdStartCount;
@property (nonatomic, assign) NSInteger holdEndCount;
@property (nonatomic, assign) NSInteger tapStartCount;
@property (nonatomic, assign) NSInteger tapEndCount;
@property (nonatomic, assign) NSInteger triggerBeginCount;
@property (nonatomic, assign) NSInteger triggerCancelCount;
@property (nonatomic, assign) NSInteger holdCompanionCancelCount;
@end

@implementation SPHotkeyMonitorTestDelegate

- (void)hotkeyMonitorDidBeginTrigger {
    self.triggerBeginCount += 1;
}

- (void)hotkeyMonitorDidCancelTrigger {
    self.triggerCancelCount += 1;
}

- (void)hotkeyMonitorDidDetectHoldStart {
    self.holdStartCount += 1;
}

- (void)hotkeyMonitorDidDetectHoldEnd {
    self.holdEndCount += 1;
}

- (void)hotkeyMonitorDidDetectTapStart {
    self.tapStartCount += 1;
}

- (void)hotkeyMonitorDidDetectTapEnd {
    self.tapEndCount += 1;
}

- (void)hotkeyMonitorDidCancelHoldForCompanionInput {
    self.holdCompanionCancelCount += 1;
}

@end

@interface SPHotkeyMonitor (Tests)
- (void)handleTriggerDown;
- (void)handleTriggerUp;
- (void)holdTimerFired;
- (void)doubleTapTimerFired;
- (void)cancelDoubleTapCandidateForInterveningInput;
- (void)cancelTriggerForCompanionInput;
- (void)handleCompanionInput;
- (BOOL)handleNSEvent:(NSEvent *)event;
- (void)scheduleModifierRelease;
- (void)setRunning:(BOOL)running;
- (void)setTriggerDown:(BOOL)triggerDown;
- (NSUInteger)currentModifierFlags;
- (void)noteObservedPress;
@end

static uint64_t SPFakeSystemPressCount = 0;

static SPHotkeyMonitor *SPChordTestMonitor(SPHotkeyMonitorTestDelegate *delegate,
                                           SPHotkeyTriggerMode mode) {
    SPHotkeyMonitor *monitor = [[SPHotkeyMonitor alloc] initWithDelegate:delegate];
    [monitor setRunning:YES];
    monitor.triggerMode = mode;
    monitor.targetMatchKind = SPHotkeyMatchKindModifierOnly;
    monitor.targetKeyCode = 54; // right Command
    monitor.targetModifierFlag = 0x10;
    SPFakeSystemPressCount = 1000;
    monitor.systemPressCounter = ^uint64_t {
        return SPFakeSystemPressCount;
    };
    return monitor;
}

static NSUInteger SPStubbedCurrentModifierFlags = 0;
static BOOL SPInstalledCurrentModifierFlagsStub = NO;

static NSUInteger SPCurrentModifierFlagsStub(id self, SEL _cmd) {
    return SPStubbedCurrentModifierFlags;
}

static void SPInstallCurrentModifierFlagsStub(void) {
    if (SPInstalledCurrentModifierFlagsStub) return;
    class_replaceMethod([SPHotkeyMonitor class],
                        @selector(currentModifierFlags),
                        (IMP)SPCurrentModifierFlagsStub,
                        "Q@:");
    SPInstalledCurrentModifierFlagsStub = YES;
}

@interface SPAppDelegateLogicTests : XCTestCase
@end

@implementation SPAppDelegateLogicTests

#pragma mark - Trigger combined with another key (Fn+brightness, Cmd-C)

// data1 of an NSSystemDefined aux-control event: key type in the high 16 bits,
// state in bits 8-15 (0x0A down, 0x0B up).
static NSInteger SPAuxData1(uint16_t keyType, uint8_t state) {
    return (NSInteger)(((uint64_t)keyType << 16) | ((uint64_t)state << 8));
}

- (void)testBrightnessAndVolumeKeysAreFunctionLayerEvents {
    XCTAssertTrue(SPHotkeyIsFunctionLayerSystemEvent(8, SPAuxData1(2, 0x0A)));  // brightness up
    XCTAssertTrue(SPHotkeyIsFunctionLayerSystemEvent(8, SPAuxData1(0, 0x0A)));  // volume up
    XCTAssertTrue(SPHotkeyIsFunctionLayerSystemEvent(8, SPAuxData1(7, 0x0A)));  // mute
    XCTAssertTrue(SPHotkeyIsFunctionLayerSystemEvent(8, SPAuxData1(21, 0x0A))); // keyboard backlight
    XCTAssertTrue(SPHotkeyIsFunctionLayerSystemEvent(8, SPAuxData1(16, 0x0A))); // play/pause
    XCTAssertTrue(SPHotkeyIsFunctionLayerSystemEvent(8, SPAuxData1(23, 0x0A)));
}

- (void)testGlobeKeyUpEventsAndOtherSubtypesAreNotFunctionLayerEvents {
    // Globe/Menu is key type 25: it must not cancel its own trigger.
    XCTAssertFalse(SPHotkeyIsFunctionLayerSystemEvent(8, SPAuxData1(25, 0x0A)));
    XCTAssertFalse(SPHotkeyIsFunctionLayerSystemEvent(8, SPAuxData1(24, 0x0A)));
    // Key-up and other subtypes do not count.
    XCTAssertFalse(SPHotkeyIsFunctionLayerSystemEvent(8, SPAuxData1(2, 0x0B)));
    XCTAssertFalse(SPHotkeyIsFunctionLayerSystemEvent(7, SPAuxData1(2, 0x0A)));
}

- (void)testCompanionKeyWhilePendingCancelsAutoTriggerInsteadOfStartingSession {
    SPHotkeyMonitorTestDelegate *delegate = [SPHotkeyMonitorTestDelegate new];
    SPHotkeyMonitor *monitor = [[SPHotkeyMonitor alloc] initWithDelegate:delegate];
    [monitor setRunning:YES];
    monitor.triggerMode = SPHotkeyTriggerModeAuto;
    monitor.targetMatchKind = SPHotkeyMatchKindModifierOnly;

    [monitor setTriggerDown:YES];
    [monitor handleTriggerDown];
    XCTAssertEqual(delegate.triggerBeginCount, 1);

    [monitor handleCompanionInput]; // Fn+brightness
    XCTAssertEqual(delegate.triggerCancelCount, 1);

    // The release that follows would have started a toggle session.
    [monitor handleTriggerUp];
    XCTAssertEqual(delegate.tapStartCount, 0);
    XCTAssertEqual(delegate.holdStartCount, 0);
}

- (void)testCompanionKeyWhilePendingCancelsToggleTrigger {
    SPHotkeyMonitorTestDelegate *delegate = [SPHotkeyMonitorTestDelegate new];
    SPHotkeyMonitor *monitor = [[SPHotkeyMonitor alloc] initWithDelegate:delegate];
    [monitor setRunning:YES];
    monitor.triggerMode = SPHotkeyTriggerModeToggle;
    monitor.targetMatchKind = SPHotkeyMatchKindModifierOnly;

    [monitor setTriggerDown:YES];
    [monitor handleTriggerDown];
    [monitor cancelTriggerForCompanionInput]; // Cmd-C
    [monitor handleTriggerUp];

    XCTAssertEqual(delegate.triggerCancelCount, 1);
    XCTAssertEqual(delegate.tapStartCount, 0);
}

#pragma mark - Clean tap versus chord

- (void)testCleanTapStartsToggleRecording {
    SPHotkeyMonitorTestDelegate *delegate = [SPHotkeyMonitorTestDelegate new];
    SPHotkeyMonitor *monitor = SPChordTestMonitor(delegate, SPHotkeyTriggerModeToggle);

    [monitor setTriggerDown:YES];
    [monitor handleTriggerDown];
    [monitor handleTriggerUp];

    XCTAssertEqual(delegate.tapStartCount, 1);
    XCTAssertEqual(delegate.triggerCancelCount, 0);
}

- (void)testKeyTheMonitorNeverSawTurnsTheTapIntoAChord {
    // Right Command + V without Accessibility: only the modifier reaches the
    // monitor, the V shows up in the system press count alone.
    SPHotkeyMonitorTestDelegate *delegate = [SPHotkeyMonitorTestDelegate new];
    SPHotkeyMonitor *monitor = SPChordTestMonitor(delegate, SPHotkeyTriggerModeToggle);

    [monitor setTriggerDown:YES];
    [monitor handleTriggerDown];
    SPFakeSystemPressCount += 1;
    [monitor handleTriggerUp];

    XCTAssertEqual(delegate.tapStartCount, 0);
    XCTAssertEqual(delegate.triggerCancelCount, 1);

    // The next clean tap works again.
    [monitor setTriggerDown:YES];
    [monitor handleTriggerDown];
    [monitor handleTriggerUp];
    XCTAssertEqual(delegate.tapStartCount, 1);
}

- (void)testPressesBeforeTheTriggerDoNotCount {
    SPHotkeyMonitorTestDelegate *delegate = [SPHotkeyMonitorTestDelegate new];
    SPHotkeyMonitor *monitor = SPChordTestMonitor(delegate, SPHotkeyTriggerModeAuto);

    SPFakeSystemPressCount += 5; // typing before the tap
    [monitor setTriggerDown:YES];
    [monitor handleTriggerDown];
    [monitor handleTriggerUp];

    XCTAssertEqual(delegate.tapStartCount, 1);
}

- (void)testPressesTheMonitorObservedAreLeftToThePreciseKeyPath {
    // A press the monitor saw was already judged by the key path (the trigger
    // key's own key events, the app's synthetic typing): no double verdict.
    SPHotkeyMonitorTestDelegate *delegate = [SPHotkeyMonitorTestDelegate new];
    SPHotkeyMonitor *monitor = SPChordTestMonitor(delegate, SPHotkeyTriggerModeToggle);

    [monitor setTriggerDown:YES];
    [monitor handleTriggerDown];
    SPFakeSystemPressCount += 1;
    [monitor noteObservedPress];
    [monitor handleTriggerUp];

    XCTAssertEqual(delegate.tapStartCount, 1);
}

- (void)testObservedKeyWhileHeldCancelsViaTheKeyPath {
    SPHotkeyMonitorTestDelegate *delegate = [SPHotkeyMonitorTestDelegate new];
    SPHotkeyMonitor *monitor = SPChordTestMonitor(delegate, SPHotkeyTriggerModeToggle);
    NSEvent *v = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                  location:NSZeroPoint
                             modifierFlags:NSEventModifierFlagCommand
                                 timestamp:0
                              windowNumber:0
                                   context:nil
                                characters:@"v"
               charactersIgnoringModifiers:@"v"
                                 isARepeat:NO
                                   keyCode:9];

    [monitor setTriggerDown:YES];
    [monitor handleTriggerDown];
    SPFakeSystemPressCount += 1;
    [monitor handleNSEvent:v];
    [monitor handleTriggerUp];

    XCTAssertEqual(delegate.tapStartCount, 0);
    XCTAssertEqual(delegate.triggerCancelCount, 1);
}

- (void)testMouseClickWhileHeldCancelsTheTrigger {
    SPHotkeyMonitorTestDelegate *delegate = [SPHotkeyMonitorTestDelegate new];
    SPHotkeyMonitor *monitor = SPChordTestMonitor(delegate, SPHotkeyTriggerModeToggle);
    NSEvent *click = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                        location:NSZeroPoint
                                   modifierFlags:NSEventModifierFlagCommand
                                       timestamp:0
                                    windowNumber:0
                                         context:nil
                                     eventNumber:0
                                      clickCount:1
                                        pressure:1];

    [monitor setTriggerDown:YES];
    [monitor handleTriggerDown];
    SPFakeSystemPressCount += 1;
    [monitor handleNSEvent:click];
    [monitor handleTriggerUp];

    XCTAssertEqual(delegate.tapStartCount, 0);
    XCTAssertEqual(delegate.triggerCancelCount, 1);
}

- (void)testUnseenClickDuringHoldClassificationCancelsHoldMode {
    SPHotkeyMonitorTestDelegate *delegate = [SPHotkeyMonitorTestDelegate new];
    SPHotkeyMonitor *monitor = SPChordTestMonitor(delegate, SPHotkeyTriggerModeAuto);

    [monitor setTriggerDown:YES];
    [monitor handleTriggerDown];
    SPFakeSystemPressCount += 1;
    [monitor handleTriggerUp];

    XCTAssertEqual(delegate.tapStartCount, 0);
    XCTAssertEqual(delegate.holdStartCount, 0);
    XCTAssertEqual(delegate.triggerCancelCount, 1);
}

- (void)testUnseenKeyBetweenDoubleTapPressesCancelsTheGesture {
    SPHotkeyMonitorTestDelegate *delegate = [SPHotkeyMonitorTestDelegate new];
    SPHotkeyMonitor *monitor = SPChordTestMonitor(delegate, SPHotkeyTriggerModeDoubleTap);

    [monitor setTriggerDown:YES];
    [monitor handleTriggerDown];
    [monitor setTriggerDown:NO];
    [monitor handleTriggerUp];
    SPFakeSystemPressCount += 1; // Command-V between the two presses
    [monitor setTriggerDown:YES];
    [monitor handleTriggerDown];
    [monitor setTriggerDown:NO];
    [monitor handleTriggerUp];

    XCTAssertEqual(delegate.tapStartCount, 0);
    XCTAssertEqual(delegate.triggerCancelCount, 1);
}

- (void)testCleanDoubleTapStillStartsRecording {
    SPHotkeyMonitorTestDelegate *delegate = [SPHotkeyMonitorTestDelegate new];
    SPHotkeyMonitor *monitor = SPChordTestMonitor(delegate, SPHotkeyTriggerModeDoubleTap);

    for (int i = 0; i < 2; i++) {
        [monitor setTriggerDown:YES];
        [monitor handleTriggerDown];
        [monitor setTriggerDown:NO];
        [monitor handleTriggerUp];
    }

    XCTAssertEqual(delegate.tapStartCount, 1);
}

- (void)testCompanionKeyDuringHoldDiscardsTheHoldSession {
    SPHotkeyMonitorTestDelegate *delegate = [SPHotkeyMonitorTestDelegate new];
    SPHotkeyMonitor *monitor = [[SPHotkeyMonitor alloc] initWithDelegate:delegate];
    [monitor setRunning:YES];
    monitor.triggerMode = SPHotkeyTriggerModeAuto;
    monitor.targetMatchKind = SPHotkeyMatchKindModifierOnly;

    [monitor setTriggerDown:YES];
    [monitor handleTriggerDown];
    [monitor holdTimerFired];
    XCTAssertEqual(delegate.holdStartCount, 1);

    [monitor cancelTriggerForCompanionInput];
    XCTAssertEqual(delegate.holdCompanionCancelCount, 1);

    // Releasing the trigger afterwards must not report a normal hold end.
    [monitor handleTriggerUp];
    XCTAssertEqual(delegate.holdEndCount, 0);
}

- (void)testCompanionKeyAfterTriggerReleaseIsIgnored {
    SPHotkeyMonitorTestDelegate *delegate = [SPHotkeyMonitorTestDelegate new];
    SPHotkeyMonitor *monitor = [[SPHotkeyMonitor alloc] initWithDelegate:delegate];
    [monitor setRunning:YES];
    monitor.triggerMode = SPHotkeyTriggerModeAuto;
    monitor.targetMatchKind = SPHotkeyMatchKindModifierOnly;

    [monitor setTriggerDown:YES];
    [monitor handleTriggerDown];
    [monitor holdTimerFired];
    [monitor setTriggerDown:NO]; // trigger released, debounce still pending

    [monitor cancelTriggerForCompanionInput]; // the user's next typing
    XCTAssertEqual(delegate.holdCompanionCancelCount, 0);
    XCTAssertEqual(delegate.triggerCancelCount, 0);
}

- (void)testCompanionKeyDoesNotAffectRecordingToggleSession {
    SPHotkeyMonitorTestDelegate *delegate = [SPHotkeyMonitorTestDelegate new];
    SPHotkeyMonitor *monitor = [[SPHotkeyMonitor alloc] initWithDelegate:delegate];
    [monitor setRunning:YES];
    monitor.triggerMode = SPHotkeyTriggerModeAuto;
    monitor.targetMatchKind = SPHotkeyMatchKindModifierOnly;

    [monitor setTriggerDown:YES];
    [monitor handleTriggerDown];
    [monitor handleTriggerUp]; // short tap: hands-free recording started
    XCTAssertEqual(delegate.tapStartCount, 1);

    // Typing while a hands-free session runs is normal and must not cancel it.
    [monitor setTriggerDown:NO];
    [monitor cancelTriggerForCompanionInput];
    XCTAssertEqual(delegate.triggerCancelCount, 0);
    XCTAssertEqual(delegate.holdCompanionCancelCount, 0);
}

- (void)testTriggerDownBeginsAudioBeforeHoldClassification {
    SPHotkeyMonitorTestDelegate *delegate = [SPHotkeyMonitorTestDelegate new];
    SPHotkeyMonitor *monitor = [[SPHotkeyMonitor alloc] initWithDelegate:delegate];
    [monitor setRunning:YES];
    monitor.triggerMode = SPHotkeyTriggerModeHold;

    [monitor handleTriggerDown];

    XCTAssertEqual(delegate.triggerBeginCount, 1);
    XCTAssertEqual(delegate.holdStartCount, 0);
}

- (void)testIgnoredShortHoldGestureCancelsEarlyAudio {
    SPHotkeyMonitorTestDelegate *delegate = [SPHotkeyMonitorTestDelegate new];
    SPHotkeyMonitor *monitor = [[SPHotkeyMonitor alloc] initWithDelegate:delegate];
    [monitor setRunning:YES];
    monitor.triggerMode = SPHotkeyTriggerModeHold;

    [monitor handleTriggerDown];
    [monitor handleTriggerUp];

    XCTAssertEqual(delegate.triggerBeginCount, 1);
    XCTAssertEqual(delegate.triggerCancelCount, 1);
    XCTAssertEqual(delegate.holdStartCount, 0);
}

- (void)testModifierShortReleaseCancelsBeforeHoldTimerFires {
    SPHotkeyMonitorTestDelegate *delegate = [SPHotkeyMonitorTestDelegate new];
    SPHotkeyMonitor *monitor = [[SPHotkeyMonitor alloc] initWithDelegate:delegate];
    [monitor setRunning:YES];
    monitor.triggerMode = SPHotkeyTriggerModeHold;

    [monitor setTriggerDown:YES];
    [monitor handleTriggerDown];
    [monitor setTriggerDown:NO];
    [monitor scheduleModifierRelease];
    [monitor holdTimerFired];

    XCTAssertEqual(delegate.triggerCancelCount, 1);
    XCTAssertEqual(delegate.holdStartCount, 0);
}

- (void)testDefersReloadDuringActiveSession {
    SPAppDelegateSessionStateTestProxy *proxy = [SPAppDelegateSessionStateTestProxy new];
    proxy.sessionState = @"recording_hold";

    [proxy reloadConfigAndApplyHotkeyIfSafe];

    XCTAssertTrue(proxy.hasPendingConfigReload);
    XCTAssertEqual(proxy.reloadCount, 0);
}

- (void)testAppliesDeferredReloadOnceIdle {
    SPAppDelegateSessionStateTestProxy *proxy = [SPAppDelegateSessionStateTestProxy new];
    proxy.sessionState = @"recording_toggle";

    [proxy reloadConfigAndApplyHotkeyIfSafe];
    XCTAssertTrue(proxy.hasPendingConfigReload);
    XCTAssertEqual(proxy.reloadCount, 0);

    proxy.sessionState = @"idle";
    [proxy applyDeferredConfigReloadIfNeeded];

    XCTAssertFalse(proxy.hasPendingConfigReload);
    XCTAssertEqual(proxy.reloadCount, 1);
}

- (void)testIdleReloadDoesNotDefer {
    SPAppDelegateSessionStateTestProxy *proxy = [SPAppDelegateSessionStateTestProxy new];
    proxy.sessionState = @"idle";

    [proxy reloadConfigAndApplyHotkeyIfSafe];

    XCTAssertFalse(proxy.hasPendingConfigReload);
    XCTAssertEqual(proxy.reloadCount, 1);
}

- (void)testModifierReleaseDebounceDoesNotEndHoldWhileModifierStillDown {
    SPInstallCurrentModifierFlagsStub();

    SPHotkeyMonitorTestDelegate *delegate = [SPHotkeyMonitorTestDelegate new];
    SPHotkeyMonitor *monitor = [[SPHotkeyMonitor alloc] initWithDelegate:delegate];
    [monitor setRunning:YES];
    monitor.triggerMode = SPHotkeyTriggerModeHold;
    SPStubbedCurrentModifierFlags = monitor.targetModifierFlag;

    [monitor setTriggerDown:YES];
    [monitor handleTriggerDown];
    [monitor holdTimerFired];

    [monitor setTriggerDown:NO];
    [monitor scheduleModifierRelease];

    XCTestExpectation *expectation = [self expectationWithDescription:@"release verification window"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        XCTAssertEqual(delegate.holdStartCount, 1);
        XCTAssertEqual(delegate.holdEndCount, 0);
        [expectation fulfill];
    });

    [self waitForExpectations:@[expectation] timeout:1.0];
}

- (void)testModifierReleaseDebounceIgnoresBriefFalseRelease {
    SPInstallCurrentModifierFlagsStub();

    SPHotkeyMonitorTestDelegate *delegate = [SPHotkeyMonitorTestDelegate new];
    SPHotkeyMonitor *monitor = [[SPHotkeyMonitor alloc] initWithDelegate:delegate];
    [monitor setRunning:YES];
    monitor.triggerMode = SPHotkeyTriggerModeHold;
    SPStubbedCurrentModifierFlags = 0;

    [monitor setTriggerDown:YES];
    [monitor handleTriggerDown];
    [monitor holdTimerFired];

    [monitor setTriggerDown:NO];
    [monitor scheduleModifierRelease];

    XCTestExpectation *expectation = [self expectationWithDescription:@"release debounce window"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SPStubbedCurrentModifierFlags = monitor.targetModifierFlag;
        [monitor setTriggerDown:YES];
        [monitor handleTriggerDown];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.55 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        XCTAssertEqual(delegate.holdStartCount, 1);
        XCTAssertEqual(delegate.holdEndCount, 0);
        [expectation fulfill];
    });

    [self waitForExpectations:@[expectation] timeout:1.0];
}

- (void)testModifierReleaseDebounceEndsHoldWhenReleasePersists {
    SPInstallCurrentModifierFlagsStub();

    SPHotkeyMonitorTestDelegate *delegate = [SPHotkeyMonitorTestDelegate new];
    SPHotkeyMonitor *monitor = [[SPHotkeyMonitor alloc] initWithDelegate:delegate];
    [monitor setRunning:YES];
    monitor.triggerMode = SPHotkeyTriggerModeHold;
    SPStubbedCurrentModifierFlags = 0;

    [monitor setTriggerDown:YES];
    [monitor handleTriggerDown];
    [monitor holdTimerFired];

    [monitor setTriggerDown:NO];
    [monitor scheduleModifierRelease];

    XCTestExpectation *expectation = [self expectationWithDescription:@"release debounce fires"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        XCTAssertEqual(delegate.holdStartCount, 1);
        XCTAssertEqual(delegate.holdEndCount, 1);
        [expectation fulfill];
    });

    [self waitForExpectations:@[expectation] timeout:1.0];
}

- (void)testToggleModeDoesNotEnterHoldFlowAfterLongPress {
    SPHotkeyMonitorTestDelegate *delegate = [SPHotkeyMonitorTestDelegate new];
    SPHotkeyMonitor *monitor = [[SPHotkeyMonitor alloc] initWithDelegate:delegate];
    [monitor setRunning:YES];
    monitor.triggerMode = SPHotkeyTriggerModeToggle;

    [monitor setTriggerDown:YES];
    [monitor handleTriggerDown];
    [monitor holdTimerFired];

    XCTAssertEqual(delegate.holdStartCount, 0);
    XCTAssertEqual(delegate.tapStartCount, 0);

    [monitor setTriggerDown:NO];
    [monitor handleTriggerUp];

    XCTAssertEqual(delegate.holdStartCount, 0);
    XCTAssertEqual(delegate.holdEndCount, 0);
    XCTAssertEqual(delegate.tapStartCount, 1);
    XCTAssertEqual(delegate.tapEndCount, 0);
}

#pragma mark - Mouse button trigger

- (void)testMouseButtonMatchingUsesOneBasedButtonNumbers {
    // kCGMouseEventButtonNumber: 2 = middle, 3 = back, 4 = forward.
    XCTAssertTrue(SPHotkeyMouseButtonMatches(2, 3));
    XCTAssertTrue(SPHotkeyMouseButtonMatches(3, 4));
    XCTAssertTrue(SPHotkeyMouseButtonMatches(4, 5));
    XCTAssertFalse(SPHotkeyMouseButtonMatches(2, 4));
    XCTAssertFalse(SPHotkeyMouseButtonMatches(3, 3));
    // Left and right clicks, and a disabled configuration, never match.
    XCTAssertFalse(SPHotkeyMouseButtonMatches(0, 1));
    XCTAssertFalse(SPHotkeyMouseButtonMatches(1, 2));
    XCTAssertFalse(SPHotkeyMouseButtonMatches(2, 0));
    XCTAssertFalse(SPHotkeyMouseButtonMatches(-1, 0));
}

- (void)testMouseButtonMonitorUsesTheSameHoldAndTapStateMachine {
    SPHotkeyMonitorTestDelegate *delegate = [SPHotkeyMonitorTestDelegate new];
    SPHotkeyMonitor *monitor = [[SPHotkeyMonitor alloc] initWithDelegate:delegate];
    [monitor setRunning:YES];
    monitor.targetMatchKind = SPHotkeyMatchKindMouseButton;
    monitor.targetKeyCode = 4;
    monitor.triggerMode = SPHotkeyTriggerModeAuto;

    // Hold: press, held past the threshold, release.
    [monitor setTriggerDown:YES];
    [monitor handleTriggerDown];
    XCTAssertEqual(delegate.triggerBeginCount, 1);
    [monitor holdTimerFired];
    XCTAssertEqual(delegate.holdStartCount, 1);
    [monitor setTriggerDown:NO];
    [monitor handleTriggerUp];
    XCTAssertEqual(delegate.holdEndCount, 1);

    // Tap: starts a hands-free recording, the next tap ends it.
    [monitor setTriggerDown:YES];
    [monitor handleTriggerDown];
    [monitor setTriggerDown:NO];
    [monitor handleTriggerUp];
    XCTAssertEqual(delegate.tapStartCount, 1);
    [monitor setTriggerDown:YES];
    [monitor handleTriggerDown];
    XCTAssertEqual(delegate.tapEndCount, 1);
}

- (void)testMouseButtonMonitorIgnoresKeyboardKeysWithTheSameNumber {
    SPHotkeyMonitorTestDelegate *delegate = [SPHotkeyMonitorTestDelegate new];
    SPHotkeyMonitor *monitor = [[SPHotkeyMonitor alloc] initWithDelegate:delegate];
    [monitor setRunning:YES];
    monitor.targetMatchKind = SPHotkeyMatchKindMouseButton;
    monitor.targetKeyCode = 4; // "h" has key code 4
    monitor.triggerMode = SPHotkeyTriggerModeToggle;

    NSEvent *down = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                     location:NSZeroPoint
                                modifierFlags:0
                                    timestamp:0
                                 windowNumber:0
                                      context:nil
                                   characters:@"h"
                  charactersIgnoringModifiers:@"h"
                                    isARepeat:NO
                                      keyCode:4];
    XCTAssertFalse([monitor handleNSEvent:down]);
    XCTAssertEqual(delegate.triggerBeginCount, 0);
    XCTAssertEqual(delegate.tapStartCount, 0);
}

- (void)testDoubleTapModeWaitsForSecondTapBeforeStarting {
    SPHotkeyMonitorTestDelegate *delegate = [SPHotkeyMonitorTestDelegate new];
    SPHotkeyMonitor *monitor = [[SPHotkeyMonitor alloc] initWithDelegate:delegate];
    [monitor setRunning:YES];
    monitor.triggerMode = SPHotkeyTriggerModeDoubleTap;

    [monitor handleTriggerDown];
    [monitor handleTriggerUp];

    XCTAssertEqual(delegate.triggerBeginCount, 0);
    XCTAssertEqual(delegate.tapStartCount, 0);

    [monitor doubleTapTimerFired];
    [monitor handleTriggerDown];
    [monitor handleTriggerUp];

    XCTAssertEqual(delegate.triggerBeginCount, 0);
    XCTAssertEqual(delegate.tapStartCount, 0);
}

- (void)testDoubleTapModeStartsOnSecondTapAndStopsOnNextSingleTap {
    SPHotkeyMonitorTestDelegate *delegate = [SPHotkeyMonitorTestDelegate new];
    SPHotkeyMonitor *monitor = [[SPHotkeyMonitor alloc] initWithDelegate:delegate];
    [monitor setRunning:YES];
    monitor.triggerMode = SPHotkeyTriggerModeDoubleTap;

    [monitor handleTriggerDown];
    [monitor handleTriggerUp];
    [monitor handleTriggerDown];

    XCTAssertEqual(delegate.triggerBeginCount, 1);
    XCTAssertEqual(delegate.tapStartCount, 0);

    [monitor handleTriggerUp];

    XCTAssertEqual(delegate.tapStartCount, 1);
    XCTAssertEqual(delegate.tapEndCount, 0);

    [monitor handleTriggerDown];

    XCTAssertEqual(delegate.tapEndCount, 0);

    [monitor handleTriggerUp];

    XCTAssertEqual(delegate.tapStartCount, 1);
    XCTAssertEqual(delegate.tapEndCount, 1);
}

- (void)testDoubleTapModeDoesNotStopRecordingForCommandShortcut {
    SPHotkeyMonitorTestDelegate *delegate = [SPHotkeyMonitorTestDelegate new];
    SPHotkeyMonitor *monitor = [[SPHotkeyMonitor alloc] initWithDelegate:delegate];
    [monitor setRunning:YES];
    monitor.triggerMode = SPHotkeyTriggerModeDoubleTap;

    [monitor handleTriggerDown];
    [monitor handleTriggerUp];
    [monitor handleTriggerDown];
    [monitor handleTriggerUp];
    XCTAssertEqual(delegate.tapStartCount, 1);

    [monitor handleTriggerDown];
    NSEvent *commandC = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                         location:NSZeroPoint
                                    modifierFlags:NSEventModifierFlagCommand
                                        timestamp:0
                                     windowNumber:0
                                          context:nil
                                       characters:@"c"
                      charactersIgnoringModifiers:@"c"
                                         isARepeat:NO
                                           keyCode:8];
    [monitor handleNSEvent:commandC];
    [monitor handleTriggerUp];

    XCTAssertEqual(delegate.tapEndCount, 0);

    [monitor handleTriggerDown];
    [monitor handleTriggerUp];

    XCTAssertEqual(delegate.tapEndCount, 1);
}

- (void)testDoubleTapModeCancelsCandidateWhenAnotherKeyIsPressed {
    SPHotkeyMonitorTestDelegate *delegate = [SPHotkeyMonitorTestDelegate new];
    SPHotkeyMonitor *monitor = [[SPHotkeyMonitor alloc] initWithDelegate:delegate];
    [monitor setRunning:YES];
    monitor.triggerMode = SPHotkeyTriggerModeDoubleTap;

    [monitor handleTriggerDown];
    [monitor cancelDoubleTapCandidateForInterveningInput];
    [monitor handleTriggerUp];
    [monitor handleTriggerDown];
    [monitor handleTriggerUp];

    XCTAssertEqual(delegate.triggerBeginCount, 0);
    XCTAssertEqual(delegate.triggerCancelCount, 0);
    XCTAssertEqual(delegate.tapStartCount, 0);
}

- (void)testDoubleTapModeCancelsPreCaptureIfSecondTapBecomesShortcut {
    SPHotkeyMonitorTestDelegate *delegate = [SPHotkeyMonitorTestDelegate new];
    SPHotkeyMonitor *monitor = [[SPHotkeyMonitor alloc] initWithDelegate:delegate];
    [monitor setRunning:YES];
    monitor.triggerMode = SPHotkeyTriggerModeDoubleTap;

    [monitor handleTriggerDown];
    [monitor handleTriggerUp];
    [monitor handleTriggerDown];
    [monitor cancelDoubleTapCandidateForInterveningInput];

    XCTAssertEqual(delegate.triggerBeginCount, 1);
    XCTAssertEqual(delegate.triggerCancelCount, 1);
    XCTAssertEqual(delegate.tapStartCount, 0);
}

@end
