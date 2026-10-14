import AVFoundation
import SwiftUI
import UIKit

/// What a new user still has to do before the first dictation.
struct SetupProgress: Equatable {
  enum Microphone: Equatable { case undetermined, denied, granted }

  var hasKey: Bool
  var keyVerified: Bool
  var microphone: Microphone
  /// How many of this app's keyboards iOS lists as added; nil when iOS does not say.
  var addedKeyboards: Int?
  var totalKeyboards: Int
  /// The keyboard has written to the shared store, which iOS allows only with
  /// Full Access, so it is also proof that a keyboard was added.
  var keyboardReported: Bool

  var keyboardAdded: Bool { keyboardReported || (addedKeyboards ?? 0) > 0 }
  var fullAccess: Bool { keyboardReported }
  var microphoneGranted: Bool { microphone == .granted }

  static let stepCount = 4

  var completedSteps: Int {
    [hasKey, microphoneGranted, keyboardAdded, fullAccess].filter { $0 }.count
  }

  var isComplete: Bool { completedSteps == Self.stepCount }
}

/// Reads the parts of the setup that live outside the app: the microphone
/// permission, the keyboards added in iOS Settings and whether a keyboard with
/// Full Access has reported in. Cheap enough to refresh every second while a
/// setup screen is visible.
@MainActor
final class SetupChecklist: ObservableObject {
  @Published private(set) var microphone: SetupProgress.Microphone = .undetermined
  @Published private(set) var addedKeyboards: Int?
  @Published private(set) var totalKeyboards = 2
  @Published private(set) var keyboardReported = false

  private lazy var ownKeyboards: Set<String> = Self.embeddedKeyboardIdentifiers()

  func progress(_ configuration: AppConfiguration) -> SetupProgress {
    SetupProgress(
      hasKey: configuration.hasUsableAPIKey,
      keyVerified: configuration.isKeyVerified,
      microphone: microphone,
      addedKeyboards: addedKeyboards,
      totalKeyboards: totalKeyboards,
      keyboardReported: keyboardReported
    )
  }

  func refresh(store: SharedRelayStore) {
    let microphone = Self.microphoneState()
    if microphone != self.microphone { self.microphone = microphone }

    let own = ownKeyboards
    let total = max(own.count, 1)
    if total != totalKeyboards { totalKeyboards = total }
    let active = Self.activeKeyboardIdentifiers()
    let added: Int? = own.isEmpty || active.isEmpty ? nil : own.intersection(active).count
    if added != addedKeyboards { addedKeyboards = added }

    store.refreshFromRemote()
    let reported = store.keyboardLastSeen != nil
    if reported != keyboardReported { keyboardReported = reported }
  }

  func requestMicrophone(store: SharedRelayStore) async {
    _ = await AVAudioApplication.requestRecordPermission()
    refresh(store: store)
  }

  private static func microphoneState() -> SetupProgress.Microphone {
    switch AVAudioApplication.shared.recordPermission {
    case .granted: return .granted
    case .denied: return .denied
    default: return .undetermined
    }
  }

  /// Bundle identifiers of the keyboards inside this app as installed, which
  /// differ from the project's when a sideloading tool re-signs the app.
  private static func embeddedKeyboardIdentifiers() -> Set<String> {
    guard let plugIns = Bundle.main.builtInPlugInsURL,
      let items = try? FileManager.default.contentsOfDirectory(
        at: plugIns, includingPropertiesForKeys: nil)
    else { return [] }
    return Set(
      items.compactMap(Bundle.init(url:)).filter { bundle in
        let point = (bundle.infoDictionary?["NSExtension"] as? [String: Any])?[
          "NSExtensionPointIdentifier"] as? String
        return point == "com.apple.keyboard-service"
      }.compactMap(\.bundleIdentifier))
  }

  /// `identifier` is not public API on UITextInputMode; the app ships outside
  /// the App Store, and the `AppleKeyboards` preference is read as a second source.
  private static func activeKeyboardIdentifiers() -> Set<String> {
    var identifiers = Set(UserDefaults.standard.stringArray(forKey: "AppleKeyboards") ?? [])
    let selector = NSSelectorFromString("identifier")
    for mode in UITextInputMode.activeInputModes where mode.responds(to: selector) {
      if let identifier = mode.value(forKey: "identifier") as? String {
        identifiers.insert(identifier)
      }
    }
    return identifiers
  }
}
