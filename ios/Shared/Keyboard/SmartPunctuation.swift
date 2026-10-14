import UIKit

/// Typographic replacements that follow the field's smart-punctuation traits,
/// like iOS's "Smart Punctuation": « » in Russian and “ ” in English, ’ for the
/// apostrophe, `--` becomes an em dash, `...` becomes an ellipsis.
struct SmartPunctuationSettings: Equatable {
  var quotes: Bool
  var dashes: Bool

  static let off = SmartPunctuationSettings(quotes: false, dashes: false)

  /// `.default` follows the system, which is on for ordinary text; `.no` is how
  /// code and technical fields opt out. URL/e-mail/number layouts are always off.
  static func resolve(
    quotes: UITextSmartQuotesType?,
    dashes: UITextSmartDashesType?,
    inputKind: KeyboardInputKind
  ) -> SmartPunctuationSettings {
    guard !inputKind.isTechnical else { return .off }
    return SmartPunctuationSettings(
      quotes: quotes != .some(.no),
      dashes: dashes != .some(.no)
    )
  }
}

/// What to do instead of inserting the typed character as is.
struct PunctuationEdit: Equatable {
  var deleteBackwardCount: Int
  var insert: String
}

enum SmartPunctuation {
  private static let openingContext: Set<Character> = [
    "(", "[", "{", "«", "“", "‘", "—", "–", "-", "/", "<",
  ]

  static func edit(
    typing text: String,
    contextBefore: String?,
    language: KeyboardLayoutLanguage,
    settings: SmartPunctuationSettings
  ) -> PunctuationEdit {
    let plain = PunctuationEdit(deleteBackwardCount: 0, insert: text)
    let before = contextBefore ?? ""
    switch text {
    case "\"" where settings.quotes:
      let opens = opensQuote(after: before.last)
      let quote: String
      switch language {
      case .russian: quote = opens ? "«" : "»"
      case .english: quote = opens ? "“" : "”"
      }
      return PunctuationEdit(deleteBackwardCount: 0, insert: quote)
    case "'" where settings.quotes:
      return PunctuationEdit(
        deleteBackwardCount: 0, insert: opensQuote(after: before.last) ? "‘" : "’")
    case "-" where settings.dashes:
      if before.hasSuffix("-") && !before.hasSuffix("--") {
        return PunctuationEdit(deleteBackwardCount: 1, insert: "—")
      }
      return plain
    case "." where settings.dashes:
      if before.hasSuffix("..") && !before.hasSuffix("...") {
        return PunctuationEdit(deleteBackwardCount: 2, insert: "…")
      }
      return plain
    default:
      return plain
    }
  }

  /// A quote opens at the start, after whitespace, or after an opening bracket
  /// or dash; anywhere else it closes (or is an apostrophe).
  static func opensQuote(after previous: Character?) -> Bool {
    guard let previous else { return true }
    return previous.isWhitespace || openingContext.contains(previous)
  }
}
