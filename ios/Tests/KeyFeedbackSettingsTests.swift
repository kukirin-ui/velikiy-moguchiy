import XCTest

@testable import VelikiyMoguchiy

private final class FeedbackMemoryPasteboard: RelayPasteboardBackend {
  private(set) var changeCount = 0
  private var data: Data?
  func read() -> Data? { data }
  func write(_ data: Data) {
    self.data = data
    changeCount += 1
  }
}

/// Settings plumbing for key haptics / click sound: app writes, keyboard reads.
@MainActor
final class KeyFeedbackSettingsTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!

  override func setUpWithError() throws {
    try super.setUpWithError()
    suiteName = "VelikiyMoguchiyKeyFeedbackTests.\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    super.tearDown()
  }

  func testMissingOrMalformedValuesMeanOn() {
    XCTAssertTrue(KeyFeedbackSettings.isEnabled(nil))
    XCTAssertTrue(KeyFeedbackSettings.isEnabled("nope"))
    XCTAssertTrue(KeyFeedbackSettings.isEnabled(NSNumber(value: true)))
    XCTAssertFalse(KeyFeedbackSettings.isEnabled(NSNumber(value: false)))
  }

  func testStoreDefaultsToOnAndRoundTripsThroughAppGroupDefaults() {
    let appStore = SharedRelayStore(defaults: defaults)
    let keyboardStore = SharedRelayStore(defaults: defaults)
    XCTAssertTrue(keyboardStore.keyHapticsEnabled)
    XCTAssertTrue(keyboardStore.keyClickSoundEnabled)

    appStore.keyHapticsEnabled = false
    XCTAssertFalse(keyboardStore.keyHapticsEnabled)
    XCTAssertTrue(keyboardStore.keyClickSoundEnabled, "toggles are independent")

    appStore.keyClickSoundEnabled = false
    appStore.keyHapticsEnabled = true
    XCTAssertTrue(keyboardStore.keyHapticsEnabled)
    XCTAssertFalse(keyboardStore.keyClickSoundEnabled)
  }

  func testSettingsTravelOverThePasteboardFallbackAndDefaultToOn() {
    let appToKeyboard = FeedbackMemoryPasteboard()
    let keyboardToApp = FeedbackMemoryPasteboard()
    func store(_ role: RelayProcessRole) -> SharedRelayStore {
      SharedRelayStore(
        defaults: PasteboardKeyValueStorage(
          role: role, appToKeyboard: appToKeyboard, keyboardToApp: keyboardToApp),
        transportKind: .pasteboard)
    }
    let appStore = store(.app)
    let keyboardStore = store(.keyboard)
    XCTAssertTrue(keyboardStore.keyHapticsEnabled, "nothing published yet: default on")

    appStore.keyHapticsEnabled = false
    appStore.keyClickSoundEnabled = true
    XCTAssertFalse(keyboardStore.keyHapticsEnabled)
    XCTAssertTrue(keyboardStore.keyClickSoundEnabled)
    XCTAssertFalse(
      PasteboardKeyValueStorage.isKeyboardKey(KeyFeedbackSettings.hapticsKey),
      "the app owns the settings keys on the single-writer channel")
  }

  func testAppConfigurationPersistsAndPublishesToggles() {
    let store = SharedRelayStore(defaults: defaults)
    let service = "com.example.velikiy-moguchiy.tests.\(UUID().uuidString)"
    let first = AppConfiguration(
      defaults: defaults, credentialStore: APIKeyStore(service: service), relayStore: store)
    XCTAssertTrue(first.keyHapticsEnabled)
    XCTAssertTrue(first.keyClickSoundEnabled)

    first.keyHapticsEnabled = false
    first.keyClickSoundEnabled = false
    XCTAssertFalse(store.keyHapticsEnabled)
    XCTAssertFalse(store.keyClickSoundEnabled)

    // A relaunch with the shared channel reset republishes the saved choice.
    let freshStore = SharedRelayStore(defaults: UserDefaults(suiteName: "\(suiteName!).other")!)
    let second = AppConfiguration(
      defaults: defaults, credentialStore: APIKeyStore(service: service), relayStore: freshStore)
    XCTAssertFalse(second.keyHapticsEnabled)
    XCTAssertFalse(second.keyClickSoundEnabled)
    XCTAssertFalse(freshStore.keyHapticsEnabled)
    XCTAssertFalse(freshStore.keyClickSoundEnabled)
    UserDefaults(suiteName: "\(suiteName!).other")?.removePersistentDomain(
      forName: "\(suiteName!).other")
  }
}
