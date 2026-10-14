import Combine
import Foundation

@MainActor
final class AppConfiguration: ObservableObject {
  private enum Key {
    static let legacyAPIKey = "configuration.dashscope-api-key-override"
    static let historyRetentionDays = "configuration.history-retention-days"
    static let noteLanguageCode = "configuration.note-language"
    static let stopInLowPowerMode = "configuration.stop-in-low-power-mode"
    static let keyVerified = "configuration.dashscope-key-verified"
  }

  private let defaults: UserDefaults
  private let relayStore: SharedRelayStore
  private let credentialStore: APIKeyStore

  /// The DashScope API key typed by the user. It lives only in this app's
  /// Keychain; the keyboards never see it, because the app does the networking.
  @Published var apiKeyOverride: String {
    didSet {
      if Self.trimmed(oldValue) != Self.trimmed(apiKeyOverride) { isKeyVerified = false }
      if credentialStore.saveAPIKey(apiKeyOverride) {
        defaults.removeObject(forKey: Key.legacyAPIKey)
        credentialPersistenceWarning = nil
      } else {
        credentialPersistenceWarning =
          "Ключ работает в этом сеансе, но не сохранился в Keychain."
      }
      // Only a boolean is shared with the keyboards; never the key itself.
      publishCredentialAvailability()
    }
  }

  @Published private(set) var credentialPersistenceWarning: String?

  /// Which DashScope endpoint the key belongs to.
  @Published var dashScopeRegion: DashScopeRegion {
    didSet {
      defaults.set(dashScopeRegion.rawValue, forKey: DashScopeRegion.defaultsKey)
      if oldValue != dashScopeRegion { isKeyVerified = false }
    }
  }

  /// The current key and region opened a DashScope session (a key check or a
  /// finished dictation). Any change to either clears it.
  @Published private(set) var isKeyVerified: Bool {
    didSet { defaults.set(isKeyVerified, forKey: Key.keyVerified) }
  }

  @Published var historyRetentionDays: Int {
    didSet {
      defaults.set(historyRetentionDays, forKey: Key.historyRetentionDays)
    }
  }

  /// Language of voice notes recorded inside the app (keyboard dictation uses
  /// the language of the keyboard that started it).
  @Published var noteLanguageCode: String {
    didSet {
      let resolved = DictationLanguage.resolve(noteLanguageCode).code
      if resolved != noteLanguageCode { noteLanguageCode = resolved }
      defaults.set(resolved, forKey: Key.noteLanguageCode)
    }
  }

  /// Light haptic tick on every key press (needs Full Access for the keyboard).
  @Published var keyHapticsEnabled: Bool {
    didSet {
      defaults.set(keyHapticsEnabled, forKey: KeyFeedbackSettings.hapticsKey)
      relayStore.keyHapticsEnabled = keyHapticsEnabled
    }
  }

  /// System keyboard click sound (still follows the iOS "Keyboard Clicks" switch).
  @Published var keyClickSoundEnabled: Bool {
    didSet {
      defaults.set(keyClickSoundEnabled, forKey: KeyFeedbackSettings.clickSoundKey)
      relayStore.keyClickSoundEnabled = keyClickSoundEnabled
    }
  }

  /// "Микрофон остаётся включённым после диктовки" (default: 15 минут).
  @Published var relaySessionLength: RelaySessionLength {
    didSet { defaults.set(relaySessionLength.rawValue, forKey: RelaySessionLength.defaultsKey) }
  }

  /// "Выключать в режиме энергосбережения" (default: on). The session is also
  /// ended below 10 % battery, independently of this switch.
  @Published var stopInLowPowerMode: Bool {
    didSet { defaults.set(stopInLowPowerMode, forKey: Key.stopInLowPowerMode) }
  }

  /// "Автоисправление" (default: off): replaces a misspelled word on space.
  @Published var autocorrectEnabled: Bool {
    didSet {
      defaults.set(autocorrectEnabled, forKey: KeyboardPreferences.autocorrectKey)
      relayStore.autocorrectEnabled = autocorrectEnabled
    }
  }

  init(
    defaults: UserDefaults = .standard,
    credentialStore: APIKeyStore = APIKeyStore(),
    relayStore: SharedRelayStore? = nil
  ) {
    self.defaults = defaults
    self.relayStore = relayStore ?? SharedRelayStore()
    self.credentialStore = credentialStore
    let savedRetention = defaults.integer(forKey: Key.historyRetentionDays)
    self.historyRetentionDays = savedRetention > 0 ? savedRetention : 30
    self.keyHapticsEnabled = KeyFeedbackSettings.isEnabled(
      defaults.object(forKey: KeyFeedbackSettings.hapticsKey))
    self.keyClickSoundEnabled = KeyFeedbackSettings.isEnabled(
      defaults.object(forKey: KeyFeedbackSettings.clickSoundKey))
    self.relaySessionLength = RelaySessionLength.resolve(
      defaults.string(forKey: RelaySessionLength.defaultsKey))
    self.stopInLowPowerMode =
      (defaults.object(forKey: Key.stopInLowPowerMode) as? NSNumber)?.boolValue ?? true
    self.autocorrectEnabled = KeyboardPreferences.isAutocorrectEnabled(
      defaults.object(forKey: KeyboardPreferences.autocorrectKey))
    self.noteLanguageCode = DictationLanguage.resolve(
      defaults.string(forKey: Key.noteLanguageCode)
        ?? Locale.preferredLanguages.first
    ).code

    var secured = credentialStore.loadAPIKey()
    #if DEBUG
      // Simulator and test runs can inject a key without touching the
      // Keychain UI: `SIMCTL_CHILD_VELIKIY_MOGUCHIY_DASHSCOPE_API_KEY=... simctl launch`.
      if secured.isEmpty,
        let injected = ProcessInfo.processInfo.environment["VELIKIY_MOGUCHIY_DASHSCOPE_API_KEY"]
      {
        secured = injected
      }
      if ProcessInfo.processInfo.environment["VELIKIY_MOGUCHIY_FORCE_MISSING_API_KEY"] == "1" {
        secured = ""
      }
    #endif
    self.apiKeyOverride = secured
    self.isKeyVerified = CredentialAvailability.isUsable(secured) && defaults.bool(forKey: Key.keyVerified)
    let region = DashScopeRegion.resolve(
      stored: defaults.string(forKey: DashScopeRegion.defaultsKey),
      hasExistingKey: CredentialAvailability.isUsable(secured)
    )
    self.dashScopeRegion = region
    // Pin the choice now, so adding a key later does not move a new install to China.
    defaults.set(region.rawValue, forKey: DashScopeRegion.defaultsKey)
    self.credentialPersistenceWarning = nil
    defaults.removeObject(forKey: Key.legacyAPIKey)
    publishCredentialAvailability()
    // Republish so keyboards see the saved choice even when the shared
    // channel was reset (pasteboard fallback entries expire).
    self.relayStore.keyHapticsEnabled = keyHapticsEnabled
    self.relayStore.keyClickSoundEnabled = keyClickSoundEnabled
    self.relayStore.autocorrectEnabled = autocorrectEnabled
  }

  var apiKey: String {
    Self.trimmed(apiKeyOverride)
  }

  func markKeyVerified() {
    if hasUsableAPIKey, !isKeyVerified { isKeyVerified = true }
  }

  /// Applies a finished key check; a key that works only in the other region
  /// switches the region, since that is the only setting that can be wrong.
  func apply(_ outcome: DashScopeKeyCheck.Outcome) {
    switch outcome {
    case .works:
      markKeyVerified()
    case .worksInOtherRegion(let region):
      dashScopeRegion = region
      markKeyVerified()
    case .failed:
      isKeyVerified = false
    }
  }

  private static func trimmed(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var noteLanguage: DictationLanguage {
    DictationLanguage.resolve(noteLanguageCode)
  }

  var speechModel: String {
    DashScopeProtocol.model
  }

  var hasUsableAPIKey: Bool {
    CredentialAvailability.isUsable(apiKey)
  }

  func clearAPIKeyOverride() {
    apiKeyOverride = ""
  }

  private func publishCredentialAvailability() {
    relayStore.apiKeyIsAvailable = hasUsableAPIKey
    if hasUsableAPIKey { relayStore.clearMissingKeyReason() }
  }
}
