import Foundation

/// Cross-process credential state. Only this boolean is shared with the
/// keyboard extensions; the API key itself stays in the app's Keychain.
enum CredentialAvailability {
  static let sharedDefaultsKey = "configuration.dashscope-api-key-available"
  static let keyboardMessage = "Откройте «Великий & Могучий» и добавьте ключ DashScope"
  static let appMessage = "Добавьте ключ DashScope в настройках, чтобы включить голос"

  static func isUsable(_ rawValue: String) -> Bool {
    let key = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return !key.isEmpty && key != "YOUR_DASHSCOPE_API_KEY"
  }
}
