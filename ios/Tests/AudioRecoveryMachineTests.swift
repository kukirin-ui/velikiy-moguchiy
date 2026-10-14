import AVFoundation
import XCTest

@testable import VelikiyMoguchiy

final class AudioRecoveryMachineTests: XCTestCase {
  private typealias Machine = AudioRecoveryMachine

  func testInterruptionPausesTheEngineWithoutRebuildingTheSession() {
    var machine = Machine()
    XCTAssertEqual(machine.handle(.interruptionBegan(.normal)), .pauseEngine)
    XCTAssertEqual(machine.phase, .interrupted)
    // Route changes and a stalled engine during the pause are not acted on.
    XCTAssertEqual(machine.handle(.routeChanged), .none)
    XCTAssertEqual(machine.handle(.engineConfigurationChanged), .none)
    XCTAssertEqual(machine.handle(.engineStalled), .none)
  }

  func testAppWasSuspendedInterruptionIsIgnored() {
    var machine = Machine()
    XCTAssertEqual(machine.handle(.interruptionBegan(.appWasSuspended)), .none)
    XCTAssertEqual(machine.phase, .running)
  }

  func testShouldResumeGivesThreeAttemptsThenAsksForTheApp() {
    var machine = Machine()
    _ = machine.handle(.interruptionBegan(.normal))
    XCTAssertEqual(
      machine.handle(.interruptionEnded(shouldResume: true)), .resumeAfterInterruption(attempt: 1))
    XCTAssertEqual(machine.handle(.restartFailed), .resumeAfterInterruption(attempt: 2))
    XCTAssertEqual(machine.handle(.restartFailed), .resumeAfterInterruption(attempt: 3))
    XCTAssertEqual(machine.handle(.restartFailed), .reportNeedsApp)
    XCTAssertEqual(machine.phase, .needsApp)
    XCTAssertTrue(machine.needsApp)
  }

  func testWithoutTheResumeHintOnlyOnePoliteAttemptIsMade() {
    var machine = Machine()
    _ = machine.handle(.interruptionBegan(.normal))
    XCTAssertEqual(
      machine.handle(.interruptionEnded(shouldResume: false)), .resumeAfterInterruption(attempt: 1))
    XCTAssertEqual(machine.handle(.restartFailed), .reportNeedsApp)
  }

  func testSuccessfulResumeReturnsToRunning() {
    var machine = Machine()
    _ = machine.handle(.interruptionBegan(.normal))
    _ = machine.handle(.interruptionEnded(shouldResume: true))
    XCTAssertEqual(machine.handle(.restartSucceeded), .none)
    XCTAssertEqual(machine.phase, .running)
  }

  func testRouteAndConfigurationChangesRestartInPlaceNeverRebuildTheSession() {
    var machine = Machine()
    XCTAssertEqual(machine.handle(.routeChanged), .restartInPlace)
    XCTAssertEqual(machine.handle(.engineConfigurationChanged), .restartInPlace)
    XCTAssertEqual(machine.phase, .running)
    for event in [Machine.Event.routeChanged, .engineConfigurationChanged, .engineStalled] {
      var m = Machine()
      XCTAssertNotEqual(m.handle(event), .rebuildSession, "\(event) must not deactivate the session")
    }
  }

  func testAFailedInPlaceRestartIsRetriedBeforeGivingUp() {
    var machine = Machine()
    XCTAssertEqual(machine.handle(.routeChanged), .restartInPlace)
    XCTAssertEqual(machine.handle(.restartFailed), .resumeAfterInterruption(attempt: 2))
    XCTAssertEqual(machine.handle(.restartFailed), .resumeAfterInterruption(attempt: 3))
    XCTAssertEqual(machine.handle(.restartFailed), .reportNeedsApp)
  }

  func testStalledEngineGetsTwoRestartsThenNeedsTheApp() {
    var machine = Machine()
    XCTAssertEqual(machine.handle(.engineStalled), .restartInPlace)
    XCTAssertEqual(machine.handle(.engineStalled), .restartInPlace)
    XCTAssertEqual(machine.handle(.engineStalled), .reportNeedsApp)
  }

  func testFlowingBuffersResetTheStallBudget() {
    var machine = Machine()
    XCTAssertEqual(machine.handle(.engineStalled), .restartInPlace)
    XCTAssertEqual(machine.stallRestarts, 1)
    _ = machine.handle(.buffersFlowing)
    XCTAssertEqual(machine.stallRestarts, 0)
    XCTAssertEqual(machine.handle(.engineStalled), .restartInPlace)
    XCTAssertEqual(machine.handle(.engineStalled), .restartInPlace)
  }

  func testMissingEndNotificationIsRepairedWhenTheAppComesForward() {
    var machine = Machine()
    _ = machine.handle(.interruptionBegan(.normal))
    XCTAssertEqual(machine.handle(.appBecameActive), .rebuildSession)
    XCTAssertEqual(machine.handle(.restartSucceeded), .none)
    XCTAssertEqual(machine.phase, .running)
  }

  func testNeedsAppIsClearedByForegroundRebuildAndGivesUpAfterOneFailure() {
    var machine = Machine()
    _ = machine.handle(.interruptionBegan(.normal))
    _ = machine.handle(.interruptionEnded(shouldResume: false))
    _ = machine.handle(.restartFailed)
    XCTAssertTrue(machine.needsApp)
    // Background events do nothing while the app is needed.
    XCTAssertEqual(machine.handle(.routeChanged), .none)
    XCTAssertEqual(machine.handle(.engineStalled), .none)
    XCTAssertEqual(machine.handle(.appBecameActive), .rebuildSession)
    XCTAssertEqual(machine.handle(.restartFailed), .reportNeedsApp)
    XCTAssertEqual(machine.handle(.appBecameActive), .rebuildSession)
    XCTAssertEqual(machine.handle(.restartSucceeded), .none)
    XCTAssertEqual(machine.phase, .running)
  }

  func testMediaServicesResetAlwaysRebuilds() {
    for setup: [Machine.Event] in [[], [.interruptionBegan(.normal)], [.routeChanged]] {
      var machine = Machine()
      setup.forEach { _ = machine.handle($0) }
      XCTAssertEqual(machine.handle(.mediaServicesReset), .rebuildSession)
    }
  }

  func testNewInterruptionDuringRecoveryPausesAgain() {
    var machine = Machine()
    _ = machine.handle(.interruptionBegan(.normal))
    _ = machine.handle(.interruptionEnded(shouldResume: true))
    XCTAssertEqual(machine.handle(.interruptionBegan(.normal)), .pauseEngine)
    XCTAssertEqual(machine.phase, .interrupted)
  }

  func testFreshStartResetsEverything() {
    var machine = Machine()
    _ = machine.handle(.interruptionBegan(.normal))
    _ = machine.handle(.interruptionEnded(shouldResume: false))
    _ = machine.handle(.restartFailed)
    XCTAssertEqual(machine.handle(.started), .none)
    XCTAssertEqual(machine.phase, .running)
  }

  // MARK: Notification parsing

  func testInterruptionNotificationsAreParsed() {
    let began: [AnyHashable: Any] = [
      AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue
    ]
    XCTAssertEqual(Machine.interruptionEvent(from: began), .interruptionBegan(.normal))

    let suspended: [AnyHashable: Any] = [
      AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
      AVAudioSessionInterruptionReasonKey: UInt(1),
    ]
    XCTAssertEqual(Machine.interruptionEvent(from: suspended), .interruptionBegan(.appWasSuspended))

    let endedWithHint: [AnyHashable: Any] = [
      AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
      AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue,
    ]
    XCTAssertEqual(
      Machine.interruptionEvent(from: endedWithHint), .interruptionEnded(shouldResume: true))
    let endedPlain: [AnyHashable: Any] = [
      AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue
    ]
    XCTAssertEqual(
      Machine.interruptionEvent(from: endedPlain), .interruptionEnded(shouldResume: false))
    XCTAssertNil(Machine.interruptionEvent(from: nil))
  }

  func testOnlyDeviceRouteChangesTriggerARestart() {
    func event(_ reason: AVAudioSession.RouteChangeReason) -> Machine.Event? {
      Machine.routeChangeEvent(from: [AVAudioSessionRouteChangeReasonKey: reason.rawValue])
    }
    XCTAssertEqual(event(.newDeviceAvailable), .routeChanged)
    XCTAssertEqual(event(.oldDeviceUnavailable), .routeChanged)
    XCTAssertNil(event(.categoryChange), "our own category change must not loop")
    XCTAssertNil(event(.wakeFromSleep))
    XCTAssertNil(event(.noSuitableRouteForCategory))
  }

  // MARK: Engine wiring

  @MainActor
  func testInterruptionNotificationPausesWithoutDeactivatingAndReportsThePause() {
    let capture = AudioCaptureEngine()
    var events: [String] = []
    capture.recoveryHandler = { event in
      switch event {
      case .paused: events.append("paused")
      case .recovered: events.append("recovered")
      case .needsApp: events.append("needsApp")
      case .failed: events.append("failed")
      }
    }
    capture.shouldBeRunning = true
    NotificationCenter.default.post(
      name: AVAudioSession.interruptionNotification,
      object: AVAudioSession.sharedInstance(),
      userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
    pumpMainQueue()
    XCTAssertEqual(events, ["paused"])
    XCTAssertEqual(capture.recoveryMachine.phase, .interrupted)
    capture.stop()
    XCTAssertEqual(capture.recoveryMachine.phase, .running, "stop resets the machine")
  }

  @MainActor
  func testRouteChangeNotificationSchedulesADebouncedRecovery() {
    let capture = AudioCaptureEngine()
    capture.shouldBeRunning = true
    NotificationCenter.default.post(
      name: AVAudioSession.routeChangeNotification,
      object: AVAudioSession.sharedInstance(),
      userInfo: [
        AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue
      ])
    pumpMainQueue()
    XCTAssertNotNil(capture.recoveryWorkItem)
    capture.stop()
    XCTAssertNil(capture.recoveryWorkItem)
  }

  @MainActor
  func testCategoryChangeRouteNotificationIsIgnored() {
    let capture = AudioCaptureEngine()
    capture.shouldBeRunning = true
    NotificationCenter.default.post(
      name: AVAudioSession.routeChangeNotification,
      object: AVAudioSession.sharedInstance(),
      userInfo: [
        AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.categoryChange.rawValue
      ])
    pumpMainQueue()
    XCTAssertNil(capture.recoveryWorkItem)
    capture.stop()
  }

  /// The observers run on the main queue; let them run before asserting.
  private func pumpMainQueue() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
  }

  func testIdleCaptureUsesALongIOBufferAndDictationAShortOne() {
    XCTAssertEqual(AudioCaptureEngine.CaptureProfile.idle.preferredIOBufferDuration, 0.1)
    XCTAssertEqual(AudioCaptureEngine.CaptureProfile.dictating.preferredIOBufferDuration, 0.02)
  }

  @MainActor
  func testLivenessCheckIgnoresAnEngineThatIsNotRunning() {
    let capture = AudioCaptureEngine()
    capture.shouldBeRunning = true
    capture.checkLiveness(now: 1_000_000)
    XCTAssertEqual(capture.recoveryMachine.stallRestarts, 0)
    capture.stop()
  }
}
