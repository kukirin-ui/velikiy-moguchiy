import Foundation

/// Language of a dictation request. The keyboard that starts the dictation
/// decides it (the RU keyboard sends `ru`, the EN keyboard sends `en`); the
/// containing app forwards it to the speech model as the transcription
/// language and picks the matching rewrite instructions.
enum DictationLanguage: String, CaseIterable, Codable, Equatable, Sendable {
  case russian = "ru"
  case english = "en"

  static let defaultLanguage: DictationLanguage = .russian

  /// Resolves a stored code (`ru`, `en`, `ru-RU`, ...). Unknown or empty
  /// values fall back to the default language instead of failing a request.
  static func resolve(_ code: String?) -> DictationLanguage {
    guard let code = code?.lowercased() else { return defaultLanguage }
    if code.hasPrefix("ru") { return .russian }
    if code.hasPrefix("en") { return .english }
    return defaultLanguage
  }

  var code: String { rawValue }

  var displayName: String {
    switch self {
    case .russian: return "Русский"
    case .english: return "English"
    }
  }
}
