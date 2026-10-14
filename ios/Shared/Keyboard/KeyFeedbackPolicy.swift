import Foundation

/// User-facing key feedback settings shared between the app (writes) and the
/// keyboards (read on `viewWillAppear`). Both default to ON when never set.
enum KeyFeedbackSettings {
  static let hapticsKey = "configuration.key-haptics-enabled"
  static let clickSoundKey = "configuration.key-click-sound-enabled"

  /// A missing or malformed value means "on" (the shipped default).
  static func isEnabled(_ stored: Any?) -> Bool {
    (stored as? NSNumber)?.boolValue ?? true
  }
}

/// What the keyboard should do on a key-down.
///
/// Haptics from a third-party keyboard only work with Full Access, so the
/// decision is `fullAccess && toggle`; without Full Access the keyboard stays
/// silently quiet. Input clicks are played through `UIDevice.playInputClick`,
/// which itself follows the system "Keyboard Clicks" setting, so only our own
/// toggle is checked here.
struct KeyFeedbackPolicy: Equatable {
  var hasFullAccess: Bool
  var hapticsEnabled: Bool
  var clickSoundEnabled: Bool

  /// Before the settings are loaded: no haptics (Full Access unknown), clicks on.
  static let initial = KeyFeedbackPolicy(
    hasFullAccess: false, hapticsEnabled: true, clickSoundEnabled: true)

  var shouldVibrate: Bool { hasFullAccess && hapticsEnabled }
  var shouldPlayClick: Bool { clickSoundEnabled }
}
