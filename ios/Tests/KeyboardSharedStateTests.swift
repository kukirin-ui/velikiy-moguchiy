import XCTest

@testable import VelikiyMoguchiy

/// State both keyboards (RU and EN, two processes) must see the same way.
final class KeyboardSharedStateTests: XCTestCase {
  private var suite: String!
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    suite = "VelikiyMoguchiySharedKeyboardState.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suite)
    super.tearDown()
  }

  private func request(created: Date = Date(), cancelling: Bool = false) -> KeyboardTrackedRequest {
    KeyboardTrackedRequest(
      requestID: "req-1", actionRawValue: RelayDictationAction.transcribe.rawValue,
      createdAt: created.timeIntervalSince1970, isCancelling: cancelling,
      documentIdentifier: UUID().uuidString, contextBeforeFingerprint: "b", contextAfterFingerprint: "a",
      awaitsKeyboardReactivation: false)
  }

  func testADictationStartedInOneKeyboardIsVisibleToTheOther() {
    let russian = SharedRelayStore(defaults: defaults)
    let english = SharedRelayStore(defaults: defaults)
    XCTAssertNil(english.trackedRequest)

    let tracked = request()
    russian.trackedRequest = tracked
    XCTAssertEqual(english.trackedRequest, tracked, "globe switch RU -> EN keeps the request")

    english.trackedRequest = nil
    XCTAssertNil(russian.trackedRequest, "the keyboard that inserted the text clears it for both")
  }

  func testAnOldRequestIsNotAdopted() {
    let store = SharedRelayStore(defaults: defaults)
    store.trackedRequest = request(created: Date().addingTimeInterval(-11 * 60))
    XCTAssertNil(store.trackedRequest, "older than ten minutes")
    store.trackedRequest = request(created: Date().addingTimeInterval(-9 * 60))
    XCTAssertNotNil(store.trackedRequest)
  }

  func testCancellingStateSurvivesTheSwitch() {
    let store = SharedRelayStore(defaults: defaults)
    store.trackedRequest = request(cancelling: true)
    XCTAssertEqual(SharedRelayStore(defaults: defaults).trackedRequest?.isCancelling, true)
  }

  func testConsumedResultSequenceOnlyGrowsAndIsShared() {
    let russian = SharedRelayStore(defaults: defaults)
    let english = SharedRelayStore(defaults: defaults)
    russian.consumedResultSequence = 7
    XCTAssertEqual(english.consumedResultSequence, 7)
    english.consumedResultSequence = max(english.consumedResultSequence, 5)
    XCTAssertEqual(russian.consumedResultSequence, 7)
  }

  func testKeyboardOwnedKeysStayWritableOnThePasteboardTransport() {
    let key = "relay.keyboard.tracked-request"
    XCTAssertTrue(PasteboardKeyValueStorage.isKeyboardKey(key))
    XCTAssertTrue(PasteboardKeyValueStorage.isKeyboardKey("relay.keyboard.last-seen"))
    XCTAssertTrue(PasteboardKeyValueStorage.isKeyboardKey("relay.keyboard.consumed-result-sequence"))
    XCTAssertFalse(PasteboardKeyValueStorage.isKeyboardKey("configuration.autocorrect-enabled"))
  }

  func testAutocorrectDefaultsToOffAndTravelsFromTheAppToTheKeyboards() {
    let store = SharedRelayStore(defaults: defaults)
    XCTAssertFalse(store.autocorrectEnabled)
    store.autocorrectEnabled = true
    XCTAssertTrue(SharedRelayStore(defaults: defaults).autocorrectEnabled)
  }
}
