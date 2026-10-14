import XCTest

@testable import VelikiyMoguchiy

private final class MemoryPasteboard: RelayPasteboardBackend {
  private(set) var changeCount = 0
  private var data: Data?
  func read() -> Data? { data }
  func write(_ data: Data) {
    self.data = data
    changeCount += 1
  }
}

private final class RecordingSignals: RelaySignalling {
  private(set) var posted: [RelaySignalEvent] = []
  func post(_ event: RelaySignalEvent) { posted.append(event) }
  func observe(_ event: RelaySignalEvent, handler: @escaping () -> Void) {}
}

final class RelayTransportSelectionTests: XCTestCase {
  func testAppGroupIsUsedOnlyWhenTheContainerIsUsable() {
    XCTAssertEqual(RelayTransportKind.select(containerIsUsable: true), .appGroup)
    XCTAssertEqual(RelayTransportKind.select(containerIsUsable: false), .pasteboard)
    XCTAssertEqual(RelayTransport(role: .app, containerIsUsable: false).kind, .pasteboard)
    XCTAssertTrue(
      RelayTransport(role: .keyboard, containerIsUsable: false).storage
        is PasteboardKeyValueStorage)
    XCTAssertTrue(
      RelayTransport(role: .app, containerIsUsable: true).storage is UserDefaults)
  }

  func testTransportTitlesAreShownInSettings() {
    XCTAssertEqual(RelayTransportKind.appGroup.title, "App Group")
    XCTAssertEqual(RelayTransportKind.pasteboard.title, "резервный канал")
  }

  func testAppGroupIdentifierResolution() {
    // No profile (simulator, tests): Info.plist value, then the default.
    XCTAssertEqual(
      VoiceAppGroup.resolveIdentifier(infoValue: "group.x.1", entitledGroups: []), "group.x.1")
    XCTAssertEqual(
      VoiceAppGroup.resolveIdentifier(infoValue: nil, entitledGroups: []),
      "group.com.example.velikiy-moguchiy")
    XCTAssertEqual(
      VoiceAppGroup.resolveIdentifier(infoValue: "  ", entitledGroups: []),
      VoiceAppGroup.defaultIdentifier)
    // The Info.plist value is entitled: keep it.
    XCTAssertEqual(
      VoiceAppGroup.resolveIdentifier(infoValue: "group.x.1", entitledGroups: ["group.y.2", "group.x.1"]),
      "group.x.1")
    // A re-signer changed the group: follow the entitlements.
    XCTAssertEqual(
      VoiceAppGroup.resolveIdentifier(infoValue: "group.x.1", entitledGroups: ["group.rewritten.7"]),
      "group.rewritten.7")
  }

  func testAppDataDirectoryKeepsTheFolderFromBeforeTheRename() throws {
    let fileManager = FileManager.default
    let support = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: support) }
    let current = support.appendingPathComponent("VelikiyMoguchiy", isDirectory: true)
    let legacy = support.appendingPathComponent(
      VoiceAppGroup.legacyAppDataFolderName, isDirectory: true)

    XCTAssertEqual(VoiceAppGroup.resolveAppDataDirectory(in: support), current)
    try fileManager.createDirectory(at: legacy, withIntermediateDirectories: true)
    XCTAssertEqual(VoiceAppGroup.resolveAppDataDirectory(in: support), legacy)
    try fileManager.createDirectory(at: current, withIntermediateDirectories: true)
    XCTAssertEqual(VoiceAppGroup.resolveAppDataDirectory(in: support), current)
  }

  func testNoEmbeddedProfileMeansNoEntitledGroups() {
    XCTAssertTrue(VoiceAppGroup.embeddedProfileApplicationGroups(bundle: Bundle(for: Self.self)).isEmpty)
  }
}

final class PasteboardRelayTests: XCTestCase {
  private var appToKeyboard: MemoryPasteboard!
  private var keyboardToApp: MemoryPasteboard!
  private var appStore: SharedRelayStore!
  private var keyboardStore: SharedRelayStore!
  private var keyboardSignals: RecordingSignals!
  private var appSignals: RecordingSignals!

  override func setUp() {
    super.setUp()
    appToKeyboard = MemoryPasteboard()
    keyboardToApp = MemoryPasteboard()
    appSignals = RecordingSignals()
    keyboardSignals = RecordingSignals()
    appStore = makeStore(role: .app, signals: appSignals)
    keyboardStore = makeStore(role: .keyboard, signals: keyboardSignals)
  }

  private func makeStore(role: RelayProcessRole, signals: RecordingSignals) -> SharedRelayStore {
    SharedRelayStore(
      defaults: PasteboardKeyValueStorage(
        role: role, appToKeyboard: appToKeyboard, keyboardToApp: keyboardToApp, signals: signals),
      transportKind: .pasteboard)
  }

  func testKeyboardCommandReachesTheAppAndSignalsIt() {
    keyboardStore.issue(.start, requestID: "r1", dictationAction: .transcribe, language: .english)
    let command = appStore.pendingCommand(after: 0)
    XCTAssertEqual(command?.command, .start)
    XCTAssertEqual(command?.requestID, "r1")
    XCTAssertEqual(command?.languageCode, "en")
    XCTAssertEqual(keyboardSignals.posted.last, .keyboardChanged)

    appStore.markCommandHandled(sequence: 1)
    XCTAssertEqual(keyboardStore.snapshot().handledCommandSequence, 1)
    XCTAssertNil(appStore.pendingCommand(after: 1))
  }

  func testAppStatusPreviewAndResultReachTheKeyboard() {
    appStore.publishStatus(.recording, message: "Слышу: привет", activeRequestID: "r1",
      activeDictationAction: .transcribe, recordingStartedAt: Date())
    var snapshot = keyboardStore.snapshot()
    XCTAssertEqual(snapshot.status, .recording)
    XCTAssertEqual(snapshot.message, "Слышу: привет")
    XCTAssertTrue(snapshot.hostIsOnline())
    XCTAssertEqual(appSignals.posted.last, .appChanged)

    let sequence = appStore.publishTranscript("Привет, мир.", requestID: "r1")
    snapshot = keyboardStore.snapshot()
    XCTAssertEqual(snapshot.resultSequence, sequence)
    XCTAssertEqual(snapshot.transcript, "Привет, мир.")
    XCTAssertEqual(snapshot.resultRequestID, "r1")
  }

  func testAcknowledgementHidesTheResultAndTheAppErasesIt() {
    let sequence = appStore.publishTranscript("секрет", requestID: "r1")
    keyboardStore.acknowledgeResult(sequence: sequence)
    XCTAssertNil(keyboardStore.snapshot().transcript, "acknowledged text is hidden at once")
    XCTAssertEqual(appStore.acknowledgedResultSequence, sequence)

    appStore.touchHeartbeat()
    XCTAssertNil(keyboardStore.snapshot().transcript)
    XCTAssertEqual(keyboardStore.snapshot().resultSequence, sequence)

    // A newer result is not hidden by the old acknowledgement.
    let next = appStore.publishTranscript("новый", requestID: "r2")
    XCTAssertEqual(keyboardStore.snapshot().transcript, "новый")
    XCTAssertGreaterThan(next, sequence)
  }

  func testLaunchRequestIsClaimedByTheAppWithoutDeletingTheKeyboardRecord() {
    let request = RelayLaunchRequest(
      requestID: UUID().uuidString, dictationAction: .transcribe, createdAt: Date(),
      originatingApplicationBundleIdentifier: nil)
    XCTAssertTrue(keyboardStore.authorizeLaunchRequest(request))
    XCTAssertNotNil(appStore.pendingLaunchRequest())

    let claimed = appStore.claimPendingLaunchRequest(matching: request)
    XCTAssertNotNil(claimed)
    XCTAssertNil(appStore.pendingLaunchRequest(), "claimed once")
    XCTAssertNil(keyboardStore.pendingLaunchRequest(), "the keyboard sees it claimed too")
    XCTAssertNil(appStore.claimPendingLaunchRequest(matching: request))
  }

  func testKeyboardCanCancelItsOwnPendingLaunch() {
    let request = RelayLaunchRequest(
      requestID: UUID().uuidString, dictationAction: .transcribe, createdAt: Date(),
      originatingApplicationBundleIdentifier: nil)
    XCTAssertTrue(keyboardStore.authorizeLaunchRequest(request))
    keyboardStore.clearLaunchAuthorization(for: request.requestID)
    XCTAssertNil(appStore.pendingLaunchRequest())
  }

  func testCredentialFlagTravelsToTheKeyboardButNeverTheKey() {
    XCTAssertFalse(keyboardStore.apiKeyIsAvailable)
    appStore.apiKeyIsAvailable = true
    XCTAssertTrue(keyboardStore.apiKeyIsAvailable)
  }

  func testEachSideWritesOnlyItsOwnPasteboard() {
    keyboardStore.issue(.stop, requestID: "r1")
    XCTAssertEqual(keyboardToApp.changeCount > 0, true)
    XCTAssertEqual(appToKeyboard.changeCount, 0)
    appStore.publishStatus(.idle, message: "ok")
    XCTAssertEqual(appToKeyboard.changeCount > 0, true)
  }

  func testOwnershipPartition() {
    XCTAssertTrue(PasteboardKeyValueStorage.isKeyboardKey("relay.command.sequence"))
    XCTAssertTrue(PasteboardKeyValueStorage.isKeyboardKey("relay.launch.pending-request"))
    XCTAssertTrue(PasteboardKeyValueStorage.isKeyboardKey("relay.result.acked"))
    XCTAssertFalse(PasteboardKeyValueStorage.isKeyboardKey("relay.command.handled-sequence"))
    XCTAssertFalse(PasteboardKeyValueStorage.isKeyboardKey("relay.status"))
    XCTAssertFalse(PasteboardKeyValueStorage.isKeyboardKey("relay.result.sequence"))
  }

  func testStateSurvivesANewProcessReadingThePasteboards() {
    appStore.publishStatus(.idle, message: "готов")
    let restarted = makeStore(role: .keyboard, signals: RecordingSignals())
    XCTAssertEqual(restarted.snapshot().message, "готов")
  }

  func testGeneralPasteboardFallbackRoundTripClearsTheItem() {
    let board = UIPasteboard(
      name: UIPasteboard.Name(rawValue: "test.fallback.\(UUID().uuidString)"), create: true)!
    defer { UIPasteboard.remove(withName: board.name) }
    RelayResultFallback.publish(text: "Привет", requestID: "r1", pasteboard: board)
    XCTAssertNil(RelayResultFallback.take(requestID: "other", pasteboard: board))
    XCTAssertEqual(RelayResultFallback.take(requestID: "r1", pasteboard: board), "Привет")
    XCTAssertNil(RelayResultFallback.take(requestID: "r1", pasteboard: board), "removed after reading")
  }
}
