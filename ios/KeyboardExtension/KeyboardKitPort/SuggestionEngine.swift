import UIKit

/// The slice of `UITextChecker` the suggestion bar uses; a fake stands in for it in tests.
protocol TextChecking: AnyObject {
  func isValidWord(_ word: String) -> Bool
  func completions(for partial: String) -> [String]
  func guesses(for word: String) -> [String]
}

/// `UITextChecker` for one language. Not thread-safe: use from one queue.
final class SystemTextChecker: TextChecking {
  private let checker = UITextChecker()
  let language: String

  /// `nil` when iOS has no dictionary for the language.
  init?(language: String) {
    guard UITextChecker.availableLanguages.contains(language) else { return nil }
    self.language = language
  }

  func isValidWord(_ word: String) -> Bool {
    let range = checker.rangeOfMisspelledWord(
      in: word, range: NSRange(location: 0, length: (word as NSString).length),
      startingAt: 0, wrap: false, language: language)
    return range.location == NSNotFound
  }

  func completions(for partial: String) -> [String] {
    checker.completions(
      forPartialWordRange: NSRange(location: 0, length: (partial as NSString).length),
      in: partial, language: language) ?? []
  }

  func guesses(for word: String) -> [String] {
    checker.guesses(
      forWordRange: NSRange(location: 0, length: (word as NSString).length),
      in: word, language: language) ?? []
  }
}

/// Builds the three suggestions for the word before the cursor and decides
/// automatic corrections. Heavy calls happen on `queue`, never on the main thread.
final class SuggestionEngine {
  let queue = DispatchQueue(label: "VelikiyMoguchiy.suggestions", qos: .userInitiated)
  private let checker: TextChecking?
  private(set) var replacements = TextReplacementTable()
  /// Words the user put back with ⌫ right after a correction.
  private(set) var rejectedWords: Set<String> = []

  /// `ru_RU` for the Russian keyboard, `en_US` for the English one.
  static func languageIdentifier(for language: KeyboardLayoutLanguage) -> String {
    language == .russian ? "ru_RU" : "en_US"
  }

  private let language: KeyboardLayoutLanguage

  init(language: KeyboardLayoutLanguage, checker: TextChecking? = nil) {
    self.language = language
    self.checker =
      checker ?? SystemTextChecker(language: Self.languageIdentifier(for: language))
    // The first call loads the lexicon (slow, and its completions can come back
    // empty); do it off the main thread before the first keystroke needs it.
    let warmUp = self.checker
    queue.async { _ = warmUp?.completions(for: "a") }
  }

  var hasDictionary: Bool { checker != nil }

  func setReplacements(_ table: TextReplacementTable) {
    replacements = table
  }

  func reject(_ word: String) {
    rejectedWords.insert(word.lowercased())
  }

  func suggestions(contextBefore: String?) -> [Suggestion] {
    let typed = WordBoundary.partialWord(contextBefore: contextBefore)
    guard !typed.isEmpty else {
      return SentenceStarters.suggestions(for: language, contextBefore: contextBefore)
    }
    guard checker != nil || !replacements.isEmpty else { return [] }
    let isValid = checker?.isValidWord(typed) ?? true
    let completions = checker?.completions(for: typed) ?? []
    // Guesses are the slow call; ask only when the word looks wrong or is short.
    let guesses = (isValid && typed.count > 3) ? [] : (checker?.guesses(for: typed) ?? [])
    return SuggestionComposer.compose(
      typed: typed,
      isValidWord: isValid,
      guesses: guesses,
      completions: completions,
      lexiconMatches: replacements.documentTexts(withPrefix: typed)
    )
  }

  /// What typing `boundary` should do to the text before the cursor, if anything.
  func replacement(
    contextBefore: String?,
    autocorrectEnabled: Bool
  ) -> BoundaryReplacement? {
    let token = WordBoundary.lastToken(contextBefore: contextBefore)
    guard !token.isEmpty else { return nil }
    if let expanded = replacements.replacement(forToken: token) {
      return BoundaryReplacement(original: token, replacement: expanded, isAutocorrect: false)
    }
    guard autocorrectEnabled, let checker else { return nil }
    let word = WordBoundary.partialWord(contextBefore: contextBefore)
    guard word == token else { return nil }
    let isValid = checker.isValidWord(word)
    guard !isValid else { return nil }
    guard
      let corrected = AutocorrectRules.correction(
        for: word, guesses: checker.guesses(for: word), isValidWord: false,
        rejectedWords: rejectedWords)
    else { return nil }
    return BoundaryReplacement(original: word, replacement: corrected, isAutocorrect: true)
  }
}
