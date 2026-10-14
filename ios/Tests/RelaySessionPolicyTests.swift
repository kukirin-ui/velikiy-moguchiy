import XCTest

@testable import VelikiyMoguchiy

final class RelaySessionPolicyTests: XCTestCase {
  func testDefaultIsFifteenMinutesAndTheFiveChoicesMatchTheSettingsScreen() {
    XCTAssertEqual(RelaySessionLength.default, .minutes15)
    XCTAssertEqual(
      RelaySessionLength.allCases.map(\.title),
      ["Сразу выключать", "5 мин", "15 мин", "1 час", "Пока не выключу"])
    XCTAssertEqual(RelaySessionLength.resolve(nil), .minutes15)
    XCTAssertEqual(RelaySessionLength.resolve("garbage"), .minutes15)
    XCTAssertEqual(RelaySessionLength.resolve("hour1"), .hour1)
  }

  func testTimedLengthsRestartForEveryTrigger() {
    let expected: [(RelaySessionLength, TimeInterval)] = [
      (.minutes5, 300), (.minutes15, 900), (.hour1, 3600),
    ]
    for (length, seconds) in expected {
      for trigger in [
        RelaySessionTrigger.armed, .keyboardActivity, .dictationFinished, .extended,
      ] {
        XCTAssertEqual(
          RelaySessionPolicy.deadline(length: length, trigger: trigger), .after(seconds),
          "\(length) \(trigger)")
      }
    }
  }

  func testUntilStoppedNeverArmsATimer() {
    for trigger in [RelaySessionTrigger.armed, .keyboardActivity, .dictationFinished, .extended] {
      XCTAssertEqual(RelaySessionPolicy.deadline(length: .untilStopped, trigger: trigger), .never)
    }
    XCTAssertNil(RelaySessionLength.untilStopped.idleTimeout)
  }

  func testImmediateShutdownGivesAFirstUseWindowThenAShortGrace() {
    XCTAssertEqual(
      RelaySessionPolicy.deadline(length: .afterDictation, trigger: .armed), .after(60))
    XCTAssertEqual(
      RelaySessionPolicy.deadline(length: .afterDictation, trigger: .dictationFinished), .after(3))
    XCTAssertEqual(
      RelaySessionPolicy.deadline(length: .afterDictation, trigger: .keyboardActivity), .unchanged)
  }

  func testWallClockDeadlineIsDueExactlyAtTheDeadline() {
    let deadline = Date(timeIntervalSince1970: 1_000)
    XCTAssertFalse(RelaySessionPolicy.isDue(deadline: nil))
    XCTAssertFalse(RelaySessionPolicy.isDue(deadline: deadline, now: deadline.addingTimeInterval(-0.1)))
    XCTAssertTrue(RelaySessionPolicy.isDue(deadline: deadline, now: deadline))
    XCTAssertTrue(RelaySessionPolicy.isDue(deadline: deadline, now: deadline.addingTimeInterval(30)))
  }

  func testShutdownMessagesExplainTheReasonAndWhatToDo() {
    XCTAssertTrue(RelaySessionPolicy.idleShutdownMessage(length: .minutes15).contains("15 минут"))
    XCTAssertTrue(RelaySessionPolicy.idleShutdownMessage(length: .afterDictation).contains("после диктовки"))
    for length in RelaySessionLength.allCases {
      XCTAssertTrue(
        RelaySessionPolicy.idleShutdownMessage(length: length).contains("Нажмите микрофон"))
    }
  }

  // MARK: Power

  func testLowBatteryBelowTenPercentUnlessCharging() {
    func constraint(_ level: Float, charging: Bool = false, lowPower: Bool = false, stop: Bool = true)
      -> RelayPowerConstraint?
    {
      RelayPowerPolicy.constraint(
        state: RelayPowerState(
          batteryLevel: level, isCharging: charging, isLowPowerModeEnabled: lowPower),
        stopInLowPowerMode: stop)
    }
    XCTAssertEqual(constraint(0.09), .lowBattery)
    XCTAssertEqual(constraint(0.0), .lowBattery)
    XCTAssertNil(constraint(0.10), "exactly 10 % is still fine")
    XCTAssertNil(constraint(0.09, charging: true))
    XCTAssertNil(constraint(-1), "unknown level (Simulator) never stops the session")
    XCTAssertEqual(constraint(0.05, lowPower: true), .lowBattery, "battery wins over Low Power Mode")
  }

  func testLowPowerModeStopsOnlyWhileTheSwitchIsOn() {
    let state = RelayPowerState(batteryLevel: 0.8, isCharging: false, isLowPowerModeEnabled: true)
    XCTAssertEqual(RelayPowerPolicy.constraint(state: state, stopInLowPowerMode: true), .lowPowerMode)
    XCTAssertNil(RelayPowerPolicy.constraint(state: state, stopInLowPowerMode: false))
    var off = state
    off.isLowPowerModeEnabled = false
    XCTAssertNil(RelayPowerPolicy.constraint(state: off, stopInLowPowerMode: true))
  }

  func testConstraintStopsOnlyAnIdleSessionWithoutAPendingHandoff() {
    XCTAssertTrue(
      RelayPowerPolicy.shouldStopNow(
        constraint: .lowBattery, operationIsBusy: false, hasPendingHandoff: false))
    XCTAssertFalse(
      RelayPowerPolicy.shouldStopNow(
        constraint: .lowBattery, operationIsBusy: true, hasPendingHandoff: false))
    XCTAssertFalse(
      RelayPowerPolicy.shouldStopNow(
        constraint: .lowPowerMode, operationIsBusy: false, hasPendingHandoff: true))
    XCTAssertFalse(
      RelayPowerPolicy.shouldStopNow(
        constraint: nil, operationIsBusy: false, hasPendingHandoff: false))
  }

  func testAConstraintTurnsAnySettingIntoStopAfterDictation() {
    XCTAssertEqual(
      RelaySessionPolicy.effectiveLength(configured: .hour1, constraint: .lowPowerMode),
      .afterDictation)
    XCTAssertEqual(
      RelaySessionPolicy.effectiveLength(configured: .untilStopped, constraint: .lowBattery),
      .afterDictation)
    XCTAssertEqual(
      RelaySessionPolicy.effectiveLength(configured: .hour1, constraint: nil), .hour1)
  }

  func testConstraintsMapToTheirOfflineReasons() {
    XCTAssertEqual(RelayPowerConstraint.lowBattery.offlineReason, .lowBattery)
    XCTAssertEqual(RelayPowerConstraint.lowPowerMode.offlineReason, .lowPowerMode)
    XCTAssertTrue(RelayPowerConstraint.lowBattery.shutdownMessage.contains("10 %"))
  }
}

final class SessionKeyboardActivityStoreTests: XCTestCase {
  func testKeyboardActivityIsThrottledAndReadableByTheApp() {
    let suite = "VelikiyMoguchiyKeyboardActivity.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = SharedRelayStore(defaults: defaults)
    store.resetForTesting()
    XCTAssertNil(store.keyboardLastSeen)

    let t0 = Date(timeIntervalSince1970: 10_000)
    XCTAssertTrue(store.noteKeyboardActive(now: t0))
    XCTAssertEqual(store.keyboardLastSeen, t0)
    XCTAssertFalse(store.noteKeyboardActive(now: t0.addingTimeInterval(10)), "throttled to 30 s")
    XCTAssertEqual(store.keyboardLastSeen, t0)
    XCTAssertTrue(store.noteKeyboardActive(now: t0.addingTimeInterval(31)))
    XCTAssertTrue(
      store.noteKeyboardActive(now: t0.addingTimeInterval(32), minimumInterval: 0),
      "showing the keyboard bypasses the throttle")
  }

  func testAppGroupWritesPostADarwinSignalButHeartbeatsDoNot() {
    final class Spy: RelaySignalling {
      var posted: [RelaySignalEvent] = []
      var handlers: [RelaySignalEvent: () -> Void] = [:]
      func post(_ event: RelaySignalEvent) { posted.append(event) }
      func observe(_ event: RelaySignalEvent, handler: @escaping () -> Void) {
        handlers[event] = handler
      }
    }
    let suite = "VelikiyMoguchiySignals.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let appSignals = Spy()
    let keyboardSignals = Spy()
    let app = SharedRelayStore(
      defaults: defaults, transportKind: .appGroup, role: .app, signals: appSignals)
    let keyboard = SharedRelayStore(
      defaults: defaults, transportKind: .appGroup, role: .keyboard, signals: keyboardSignals)

    app.publishStatus(.idle, message: "Готово")
    XCTAssertEqual(appSignals.posted, [.appChanged])
    app.touchHeartbeat()
    XCTAssertEqual(appSignals.posted, [.appChanged], "heartbeat does not wake the keyboard")

    keyboard.issue(.start, requestID: "r")
    XCTAssertEqual(keyboardSignals.posted, [.keyboardChanged])

    var appWoken = 0
    var keyboardWoken = 0
    app.onRemoteChange = { appWoken += 1 }
    keyboard.onRemoteChange = { keyboardWoken += 1 }
    appSignals.handlers[.keyboardChanged]?()
    keyboardSignals.handlers[.appChanged]?()
    XCTAssertEqual(appWoken, 1)
    XCTAssertEqual(keyboardWoken, 1)
    XCTAssertNil(appSignals.handlers[.appChanged], "the app listens only to the keyboard's signal")
  }
}
