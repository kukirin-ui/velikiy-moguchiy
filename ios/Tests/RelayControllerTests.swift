import UIKit
import XCTest

@testable import VelikiyMoguchiy

@MainActor
final class RelayControllerTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!
  private var directoryURL: URL!

  func testIdleDeadlineTracksSchedulingSuspensionAndStop() throws {
    let (controller, _) = try makeController()
    controller.isRelayRunning = true
    controller.status = .idle
    controller.scheduleIdleShutdownIfEligible()
    let deadline = try XCTUnwrap(controller.idleShutdownDeadline)
    XCTAssertEqual(deadline.timeIntervalSinceNow, 15 * 60, accuracy: 1, "default is 15 minutes")

    controller.markRelayActivityAndSuspendIdleShutdown()
    XCTAssertNil(controller.idleShutdownDeadline)
    controller.scheduleIdleShutdownIfEligible()
    XCTAssertNotNil(controller.idleShutdownDeadline)
    controller.stopRelay()
    XCTAssertNil(controller.idleShutdownDeadline)

    controller.isRelayRunning = true
    controller.status = .recording
    controller.scheduleIdleShutdownIfEligible()
    XCTAssertNil(controller.idleShutdownDeadline)
    controller.isRelayRunning = false
  }

  func testSessionLengthSettingDrivesTheCountdown() throws {
    let (controller, _) = try makeController()
    controller.isRelayRunning = true
    controller.status = .idle
    defer { controller.isRelayRunning = false }

    controller.configuration.relaySessionLength = .minutes5
    controller.scheduleIdleShutdownIfEligible()
    XCTAssertEqual(try XCTUnwrap(controller.idleShutdownDeadline).timeIntervalSinceNow, 300, accuracy: 1)

    controller.configuration.relaySessionLength = .hour1
    controller.scheduleIdleShutdownIfEligible()
    XCTAssertEqual(try XCTUnwrap(controller.idleShutdownDeadline).timeIntervalSinceNow, 3600, accuracy: 1)

    controller.configuration.relaySessionLength = .untilStopped
    controller.scheduleIdleShutdownIfEligible()
    XCTAssertNil(controller.idleShutdownDeadline, "«Пока не выключу» never arms a timer")
  }

  func testSettingPersistsAndDefaultsToFifteenMinutes() throws {
    let (controller, _) = try makeController()
    XCTAssertEqual(controller.configuration.relaySessionLength, .minutes15)
    XCTAssertTrue(controller.configuration.stopInLowPowerMode)
    XCTAssertFalse(controller.configuration.autocorrectEnabled)
    controller.configuration.relaySessionLength = .minutes5
    controller.configuration.stopInLowPowerMode = false
    let reloaded = AppConfiguration(
      defaults: defaults, credentialStore: APIKeyStore(service: keychainService))
    XCTAssertEqual(reloaded.relaySessionLength, .minutes5)
    XCTAssertFalse(reloaded.stopInLowPowerMode)
  }

  func testKeyboardActivityRestartsTheCountdownFromNow() throws {
    let (controller, store) = try makeController()
    controller.isRelayRunning = true
    controller.status = .idle
    defer { controller.isRelayRunning = false }
    controller.scheduleIdleShutdownIfEligible()
    // Pretend the countdown already ran for ten minutes.
    controller.idleShutdownDeadline = Date().addingTimeInterval(5 * 60)

    XCTAssertTrue(store.noteKeyboardActive(minimumInterval: 0))
    controller.pollKeyboardActivity()
    let restarted = try XCTUnwrap(controller.idleShutdownDeadline)
    XCTAssertEqual(restarted.timeIntervalSinceNow, 15 * 60, accuracy: 1)

    // The same stamp is not counted twice.
    controller.idleShutdownDeadline = Date().addingTimeInterval(60)
    controller.pollKeyboardActivity()
    XCTAssertEqual(try XCTUnwrap(controller.idleShutdownDeadline).timeIntervalSinceNow, 60, accuracy: 1)
  }

  func testImmediateShutdownLeavesAGraceAfterDictationAndIgnoresKeyboardShows() throws {
    let (controller, _) = try makeController()
    controller.isRelayRunning = true
    controller.status = .idle
    defer { controller.isRelayRunning = false }
    controller.configuration.relaySessionLength = .afterDictation

    controller.scheduleIdleShutdownIfEligible(trigger: .armed)
    XCTAssertEqual(try XCTUnwrap(controller.idleShutdownDeadline).timeIntervalSinceNow, 60, accuracy: 1)

    controller.markRelayActivityAndScheduleIdleShutdown()
    XCTAssertEqual(try XCTUnwrap(controller.idleShutdownDeadline).timeIntervalSinceNow, 3, accuracy: 1)

    controller.scheduleIdleShutdownIfEligible(trigger: .keyboardActivity)
    XCTAssertEqual(
      try XCTUnwrap(controller.idleShutdownDeadline).timeIntervalSinceNow, 3, accuracy: 1,
      "showing the keyboard must not stretch an immediate shutdown")
  }

  func testExtendRestartsTheCountdown() throws {
    let (controller, _) = try makeController()
    controller.isRelayRunning = true
    controller.status = .idle
    defer { controller.isRelayRunning = false }
    controller.scheduleIdleShutdownIfEligible()
    controller.idleShutdownDeadline = Date().addingTimeInterval(20)
    controller.extendSession()
    XCTAssertEqual(try XCTUnwrap(controller.idleShutdownDeadline).timeIntervalSinceNow, 15 * 60, accuracy: 1)
  }

  func testLowBatteryStopsAnIdleSessionButNotARunningDictation() throws {
    let (controller, store) = try makeController()
    controller.isRelayRunning = true
    controller.status = .idle
    controller.powerStateProvider = {
      RelayPowerState(batteryLevel: 0.09, isCharging: false, isLowPowerModeEnabled: false)
    }

    controller.status = .recording
    controller.activeRequestID = "dictation"
    controller.evaluatePowerConstraint()
    XCTAssertTrue(controller.isRelayRunning, "a dictation in progress is never cut off")
    controller.activeRequestID = nil
    controller.status = .idle

    controller.evaluatePowerConstraint()
    XCTAssertFalse(controller.isRelayRunning)
    XCTAssertEqual(store.snapshot().status, .offline)
    XCTAssertEqual(store.snapshot().offlineReason, .lowBattery)
  }

  func testLowPowerModeFollowsItsSwitch() throws {
    let (controller, store) = try makeController()
    controller.powerStateProvider = {
      RelayPowerState(batteryLevel: 0.8, isCharging: false, isLowPowerModeEnabled: true)
    }
    controller.configuration.stopInLowPowerMode = false
    controller.isRelayRunning = true
    controller.status = .idle
    controller.evaluatePowerConstraint()
    XCTAssertTrue(controller.isRelayRunning, "switch off: Low Power Mode is ignored")
    controller.isRelayRunning = false

    controller.configuration.stopInLowPowerMode = true
    controller.isRelayRunning = true
    controller.evaluatePowerConstraint()
    XCTAssertFalse(controller.isRelayRunning)
    XCTAssertEqual(store.snapshot().offlineReason, .lowPowerMode)
  }

  func testPowerConstraintShortensTheCountdownWhileADictationIsPending() throws {
    let (controller, _) = try makeController()
    controller.isRelayRunning = true
    controller.status = .idle
    defer { controller.isRelayRunning = false }
    controller.powerStateProvider = {
      RelayPowerState(batteryLevel: 0.05, isCharging: false, isLowPowerModeEnabled: false)
    }
    controller.scheduleIdleShutdownIfEligible(trigger: .dictationFinished)
    XCTAssertEqual(try XCTUnwrap(controller.idleShutdownDeadline).timeIntervalSinceNow, 3, accuracy: 1)
  }

  func testMaximumDictationDurationIsFiveMinutes() {
    XCTAssertEqual(RelayController.maximumDictationDuration, 5 * 60)
  }

  func testNoteSavesDurablyWithoutPublishingAKeyboardInsertion() throws {
    let (controller, store) = try makeController()
    let originalResult = store.snapshot().resultSequence
    let item = try controller.completeTranscription(
      "Remember to take the scenic route.", requestID: UUID().uuidString, action: .note
    )
    XCTAssertEqual(controller.noteCapturePhase, .saved(item))
    XCTAssertEqual(controller.history.first, item)
    XCTAssertEqual(TranscriptHistoryStore(directoryURL: directoryURL.appendingPathComponent("AppData")).items, [item])
    XCTAssertEqual(store.snapshot().resultSequence, originalResult)
    XCTAssertNil(store.snapshot().transcript)
  }

  func testNoteRetrySavesTextWithoutPublishingAKeyboardInsertion() async throws {
    let (controller, store) = try makeController()
    let requestID = UUID().uuidString
    let recordings = directoryURL.appendingPathComponent("Recordings", isDirectory: true)
    try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
    let url = recordings.appendingPathComponent("completed-note-ru-\(requestID).wav")
    try TestAudio.writeWAV(to: url, seconds: 1.0, sampleRate: 44_100)
    let recording = try controller.recoveryStore.stage(
      CapturedAudioSegment(
        requestID: requestID, url: url, startedAt: Date().addingTimeInterval(-2), endedAt: Date()),
      action: .note, languageCode: "ru"
    )
    XCTAssertEqual(recording.actionTitle, "Голосовая заметка")
    let reloaded = RecoverableRecordingStore(directoryURL: recordings)
    XCTAssertEqual(reloaded.recordings.first?.action, .note)
    controller.retryRecording(recording)
    for _ in 0..<200 where controller.retryingRecordingID != nil {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertNil(controller.retryingRecordingID)
    XCTAssertEqual(controller.history.first?.text, "Привет, мир.")
    XCTAssertTrue(controller.recoveryStore.recordings.isEmpty)
    XCTAssertNil(store.snapshot().transcript)
  }

  func testRetryOfASilentRecordingDeletesItInsteadOfKeepingAFalseAlarm() async throws {
    let (controller, _) = try makeController()
    let recording = try stageRecording(in: controller, amplitude: 0)
    controller.retryRecording(recording)
    try await waitForRetry(controller)
    XCTAssertTrue(controller.recoveryStore.recordings.isEmpty)
    XCTAssertTrue(controller.history.isEmpty)
    XCTAssertEqual(controller.statusMessage, "В записи не слышно речи — она удалена")
  }

  func testRetryFailureKeepsTheRecordingWithActionableAdvice() async throws {
    let (controller, _) = try makeController(
      socketScript: .init(errorOnResponse: "Access denied, please make sure your account is in good standing."))
    let recording = try stageRecording(in: controller, amplitude: 0.4)
    controller.retryRecording(recording)
    try await waitForRetry(controller)
    let kept = try XCTUnwrap(controller.recoveryStore.recordings.first)
    XCTAssertEqual(kept.lastError, DictationFailure(kind: .account, code: "svc").detail)
    XCTAssertEqual(controller.statusMessage, kept.lastError)
  }

  private func stageRecording(
    in controller: RelayController, amplitude: Double
  ) throws -> RecoverableRecording {
    let requestID = UUID().uuidString
    let recordings = directoryURL.appendingPathComponent("Recordings", isDirectory: true)
    try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
    let url = recordings.appendingPathComponent("completed-transcribe-ru-\(requestID).wav")
    try TestAudio.writeWAV(to: url, seconds: 1.0, sampleRate: 44_100, amplitude: amplitude)
    return try controller.recoveryStore.stage(
      CapturedAudioSegment(
        requestID: requestID, url: url, startedAt: Date().addingTimeInterval(-2), endedAt: Date()),
      action: .transcribe, languageCode: "ru"
    )
  }

  private func waitForRetry(_ controller: RelayController) async throws {
    for _ in 0..<200 where controller.retryingRecordingID != nil {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertNil(controller.retryingRecordingID)
  }

  func testHistoryRetentionDefaultsToThirtyDaysAndPersistsChanges() throws {
    let (controller, _) = try makeController()
    XCTAssertEqual(controller.configuration.historyRetentionDays, 30)
    try controller.historyStore.add(text: "Old note", createdAt: Date().addingTimeInterval(-10 * 86_400))
    try controller.historyStore.add(text: "New note")
    controller.configuration.historyRetentionDays = 7
    controller.applyHistoryRetention()
    XCTAssertEqual(controller.history.map(\.text), ["New note"])
    XCTAssertEqual(AppConfiguration(defaults: defaults).historyRetentionDays, 7)
  }

  func testCancelCommandStopsProcessingAndDeletesStagedRecording() throws {
    let (controller, store) = try makeController()
    let requestID = UUID().uuidString
    let recordingURL = directoryURL
      .appendingPathComponent("Recordings", isDirectory: true)
      .appendingPathComponent("completed-transcribe-en-\(requestID).wav")
    try FileManager.default.createDirectory(
      at: recordingURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data([0, 1, 2, 3]).write(to: recordingURL)
    let recording = try controller.recoveryStore.stage(
      CapturedAudioSegment(
        requestID: requestID,
        url: recordingURL,
        startedAt: Date().addingTimeInterval(-2),
        endedAt: Date()
      ),
      action: .transcribe,
      languageCode: "en"
    )

    controller.isRelayRunning = true
    controller.processingRequestID = requestID
    controller.processingRecordingID = recording.id
    controller.transcriptionTask = Task {
      try? await Task.sleep(nanoseconds: 30_000_000_000)
    }
    controller.publish(
      .transcribing,
      message: "Оформляю текст…",
      activeRequestID: requestID,
      activeDictationAction: .transcribe
    )

    controller.handle(
      RelayCommandEnvelope(
        sequence: 1,
        command: .cancel,
        requestID: requestID,
        dictationAction: .transcribe,
        languageCode: "ru",
        createdAt: Date()
      )
    )

    XCTAssertNil(controller.transcriptionTask)
    XCTAssertNil(controller.processingRequestID)
    XCTAssertNil(controller.processingRecordingID)
    XCTAssertTrue(controller.recoveryStore.recordings.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: recordingURL.path))
    XCTAssertEqual(store.snapshot().status, .idle)
    XCTAssertNil(store.snapshot().transcript)
  }

  override func setUpWithError() throws {
    try super.setUpWithError()
    suiteName = "VelikiyMoguchiyRelayControllerTests.\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let keychainService { APIKeyStore(service: keychainService).saveAPIKey("") }
    defaults.removePersistentDomain(forName: suiteName)
    try? FileManager.default.removeItem(at: directoryURL)
    try super.tearDownWithError()
  }

  private var keychainService: String!

  private func makeController(
    socketScript: FakeDashScopeSocket.Script = .init(finalText: "Привет, мир.")
  ) throws -> (RelayController, SharedRelayStore) {
    keychainService = "com.example.velikiy-moguchiy.tests.\(UUID().uuidString)"
    let configuration = AppConfiguration(
      defaults: defaults,
      credentialStore: APIKeyStore(service: keychainService)
    )
    configuration.apiKeyOverride = "test-api-key"
    let store = SharedRelayStore(defaults: defaults)
    store.resetForTesting()

    let controller = RelayController(
      configuration: configuration,
      store: store,
      transcriber: DashScopeRecordingTranscriber(socketFactory: { _ in
        FakeDashScopeSocket(script: socketScript)
      }),
      recoveryStore: RecoverableRecordingStore(
        directoryURL: directoryURL.appendingPathComponent("Recordings", isDirectory: true)
      ),
      historyStore: TranscriptHistoryStore(
        directoryURL: directoryURL.appendingPathComponent("AppData", isDirectory: true)
      )
    )
    return (controller, store)
  }

  #if VELIKIY_MOGUCHIY_PERSONAL_DEVICE
    func testManualReturnGuidanceIsNotReArmedByPolling() throws {
      let (controller, store) = try makeController()
      defer { controller.cancelAutomaticReturnToKeyboard() }

      let request = RelayLaunchRequest(
        requestID: UUID().uuidString,
        dictationAction: .transcribe,
        createdAt: Date(),
        originatingApplicationBundleIdentifier: "com.example.host"
      )
      XCTAssertTrue(store.authorizeLaunchRequest(request))
      // Mirror applicationDidBecomeActive: the controller holds the copy read
      // back from the store, whose timestamp went through a plist round trip.
      controller.pendingLaunchRequest = try XCTUnwrap(store.pendingLaunchRequest())
      controller.isRelayRunning = true
      controller.setLocalStatus(.idle, message: "Ready")

      // The bounded automatic return already gave up for this request.
      controller.requiresManualKeyboardReturn = true
      controller.preparePendingLaunchHandoffIfNeeded()
      XCTAssertTrue(controller.requiresManualKeyboardReturn)
      XCTAssertNil(controller.pendingHostReturn)
      XCTAssertTrue(controller.isKeyboardHandoffActive)
      XCTAssertNotNil(store.pendingLaunchRequest(), "The authorization must stay claimable")

      // A fresh activation clears the flag and gets a new bounded attempt.
      controller.requiresManualKeyboardReturn = false
      controller.preparePendingLaunchHandoffIfNeeded()
      XCTAssertEqual(
        controller.pendingHostReturn,
        RelayController.PendingHostReturn(
          requestID: request.requestID,
          bundleIdentifier: "com.example.host"
        )
      )
      XCTAssertEqual(controller.hostReturnAttemptCount, 0)
    }
  #endif
}
