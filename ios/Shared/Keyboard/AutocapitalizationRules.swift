import UIKit

/// When the next letter should be a capital. Apple capitalizes after a sentence
/// end only once a space (or a new line) follows it, so "google.com", "3.14" and
/// "e.g" stay lowercase, and a known abbreviation ("т.е. ", "Mr. ") does too.
enum AutocapitalizationRules {
  /// What ends a sentence. "…" counts, like in the audit's rule set.
  private static let terminators: Set<Character> = [".", "!", "?", "…"]
  /// Closing marks that may sit between the terminator and the space.
  private static let closers: Set<Character> = ["\"", "”", "»", "’", "'", ")", "]", "}"]

  private static let abbreviations: Set<String> = [
    // English
    "mr", "mrs", "ms", "dr", "prof", "vs", "e.g", "i.e", "approx", "fig", "inc", "ltd", "jr", "sr",
    // Russian
    "т.е", "т.д", "т.п", "т.к", "т.н", "т.ч", "и т.д", "и т.п", "г", "гг", "ул", "им", "др", "пр",
    "см", "рис", "стр", "тыс", "млн", "млрд", "руб", "коп", "англ", "напр", "проф", "акад", "доц",
  ]

  static func capitalization(
    type: UITextAutocapitalizationType,
    contextBefore: String?
  ) -> KeyboardCapitalization {
    switch type {
    case .none:
      return .lowercase
    case .allCharacters:
      return .shifted
    case .words:
      return startsWord(contextBefore) ? .shifted : .lowercase
    case .sentences:
      return startsSentence(contextBefore) ? .shifted : .lowercase
    @unknown default:
      return .lowercase
    }
  }

  /// Start of the text, or whitespace right before the cursor.
  static func startsWord(_ context: String?) -> Bool {
    guard let last = context?.last else { return true }
    return last.isWhitespace
  }

  static func startsSentence(_ context: String?) -> Bool {
    guard let context, !context.isEmpty else { return true }
    guard let last = context.last else { return true }
    // A fresh paragraph starts a sentence whatever came before.
    if last.isNewline { return true }
    // Everything so far is whitespace.
    if context.allSatisfy(\.isWhitespace) { return true }
    guard last.isWhitespace else { return false }

    // Skip the whitespace run, then closing quotes and brackets.
    var index = context.endIndex
    while index > context.startIndex {
      let previous = context.index(before: index)
      if context[previous].isWhitespace { index = previous } else { break }
    }
    while index > context.startIndex {
      let previous = context.index(before: index)
      if closers.contains(context[previous]) { index = previous } else { break }
    }
    guard index > context.startIndex else { return false }
    let terminatorIndex = context.index(before: index)
    let terminator = context[terminatorIndex]
    guard terminators.contains(terminator) else { return false }
    if terminator == "." {
      let beforeTerminator = String(context[context.startIndex..<terminatorIndex])
      if endsWithAbbreviation(beforeTerminator) { return false }
    }
    return true
  }

  /// The word before a full stop is an abbreviation or an initial: "т.е", "Mr",
  /// "А" (as in "А. С. Пушкин"), or a dotted chain of single letters.
  static func endsWithAbbreviation(_ text: String) -> Bool {
    var token = ""
    for character in text.reversed() {
      if character.isWhitespace || "([{«“\"".contains(character) { break }
      token.insert(character, at: token.startIndex)
    }
    guard !token.isEmpty else { return false }
    let lowered = token.lowercased()
    if abbreviations.contains(lowered) { return true }
    // "т.е", "e.g", "U.S": letter, dot, letter ...
    let parts = lowered.split(separator: ".", omittingEmptySubsequences: false)
    if parts.count >= 2, parts.allSatisfy({ $0.count == 1 && $0.first?.isLetter == true }) {
      return true
    }
    // A single capital letter is an initial.
    if token.count == 1, let only = token.first, only.isLetter, only.isUppercase { return true }
    return false
  }
}
