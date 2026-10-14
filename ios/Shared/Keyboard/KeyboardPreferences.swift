import Foundation

/// Keyboard behaviour switches the app writes and the keyboards read.
enum KeyboardPreferences {
  static let autocorrectKey = "configuration.autocorrect-enabled"

  /// Automatic correction on space is OFF unless the user turned it on: a wrong
  /// silent replacement is worse than a missing one.
  static func isAutocorrectEnabled(_ stored: Any?) -> Bool {
    (stored as? NSNumber)?.boolValue ?? false
  }
}
