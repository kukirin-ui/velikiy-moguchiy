import Foundation

/// One cell of the suggestion bar.
struct Suggestion: Equatable {
  /// What gets inserted.
  var text: String
  /// The word exactly as typed, shown in quotes when it is not a known word.
  var isTypedWord: Bool = false
  var isQuoted: Bool = false

  var display: String { isQuoted ? "“\(text)”" : text }
}

enum CasePreservation {
  /// "Hello" -> "Help" becomes "Help", "HELLO" -> "HELP", "hello" -> "help".
  static func apply(to candidate: String, like typed: String) -> String {
    guard let first = typed.first else { return candidate }
    if typed.count > 1, typed == typed.uppercased(), typed != typed.lowercased() {
      return candidate.uppercased()
    }
    if first.isUppercase, let head = candidate.first {
      return String(head).uppercased() + candidate.dropFirst()
    }
    return candidate
  }
}

enum EditDistance {
  /// Optimal string alignment distance (Damerau-Levenshtein with adjacent swaps).
  static func between(_ a: String, _ b: String) -> Int {
    let left = Array(a.lowercased())
    let right = Array(b.lowercased())
    if left.isEmpty { return right.count }
    if right.isEmpty { return left.count }
    var table = Array(repeating: Array(repeating: 0, count: right.count + 1), count: left.count + 1)
    for i in 0...left.count { table[i][0] = i }
    for j in 0...right.count { table[0][j] = j }
    for i in 1...left.count {
      for j in 1...right.count {
        let cost = left[i - 1] == right[j - 1] ? 0 : 1
        table[i][j] = min(
          table[i - 1][j] + 1,
          table[i][j - 1] + 1,
          table[i - 1][j - 1] + cost
        )
        if i > 1, j > 1, left[i - 1] == right[j - 2], left[i - 2] == right[j - 1] {
          table[i][j] = min(table[i][j], table[i - 2][j - 2] + 1)
        }
      }
    }
    return table[left.count][right.count]
  }
}

enum WordBoundary {
  /// Keys after which the word before the cursor is finished.
  static let boundaryCharacters: Set<String> = [
    " ", "\n", ".", ",", "!", "?", ";", ":", ")", "”", "»",
  ]

  static func isBoundary(_ text: String) -> Bool {
    boundaryCharacters.contains(text)
  }

  /// Characters that mean "this is a URL, an e-mail or a handle, not a word".
  private static let technicalNeighbours: Set<Character> = [".", "@", "/", "#", ":", "_", "\\"]

  /// The letters (and apostrophes) in front of the cursor, or "" when there is
  /// no word to complete (the cursor follows a space, a digit, "@" and so on).
  static func partialWord(contextBefore: String?) -> String {
    guard let context = contextBefore, !context.isEmpty else { return "" }
    var characters: [Character] = []
    var index = context.endIndex
    while index > context.startIndex {
      let previous = context.index(before: index)
      let character = context[previous]
      guard character.isLetter || character == "'" || character == "’" else { break }
      characters.append(character)
      index = previous
      if characters.count >= 40 { return "" }
    }
    guard !characters.isEmpty else { return "" }
    if index > context.startIndex {
      let neighbour = context[context.index(before: index)]
      if neighbour.isNumber || technicalNeighbours.contains(neighbour) { return "" }
    }
    let word = String(characters.reversed())
    // A leading apostrophe belongs to a quote, not to the word.
    return word.drop(while: { $0 == "'" || $0 == "’" }).description
  }

  /// The last whitespace-delimited token (text replacements may contain digits
  /// and symbols), without a trailing boundary.
  static func lastToken(contextBefore: String?) -> String {
    guard let context = contextBefore else { return "" }
    var characters: [Character] = []
    for character in context.reversed() {
      if character.isWhitespace { break }
      characters.append(character)
      if characters.count > 40 { return "" }
    }
    return String(characters.reversed())
  }
}

enum SuggestionComposer {
  /// Up to three cells: the typed word first (quoted when it is not a word),
  /// then the best candidates. The second cell is the automatic correction.
  static func compose(
    typed: String,
    isValidWord: Bool,
    guesses: [String],
    completions: [String],
    lexiconMatches: [String]
  ) -> [Suggestion] {
    guard !typed.isEmpty else { return [] }
    var seen: Set<String> = [typed.lowercased()]
    var candidates: [String] = []
    func add(_ list: [String]) {
      for item in list {
        let cased = CasePreservation.apply(to: item, like: typed)
        let key = cased.lowercased()
        guard !seen.contains(key), !cased.isEmpty else { continue }
        seen.insert(key)
        candidates.append(cased)
      }
    }
    // An exact text-replacement hit beats everything.
    let exact = lexiconMatches.filter { $0.lowercased() != typed.lowercased() }
    // Guesses that continue what is typed read as completions, so they lead.
    let lowered = typed.lowercased()
    let continuing = guesses.filter { $0.lowercased().hasPrefix(lowered) }
    let corrections = guesses.filter { !$0.lowercased().hasPrefix(lowered) }
    if isValidWord {
      add(completions)
      add(continuing)
      add(corrections)
      add(exact)
    } else {
      add(continuing)
      add(corrections)
      add(completions)
      add(exact)
    }
    var result = [
      Suggestion(text: typed, isTypedWord: true, isQuoted: !isValidWord)
    ]
    result += candidates.prefix(2).map { Suggestion(text: $0) }
    return result
  }
}

enum AutocorrectRules {
  /// A correction only for an unknown word of at least three letters, one edit
  /// away from the best guess, never for acronyms, camelCase or a word the user
  /// already put back with ⌫.
  static func correction(
    for word: String,
    guesses: [String],
    isValidWord: Bool,
    rejectedWords: Set<String>
  ) -> String? {
    guard !isValidWord,
      word.count >= 3,
      word.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" }),
      !rejectedWords.contains(word.lowercased())
    else { return nil }
    let tail = word.dropFirst()
    // "NASA", "iPhone", "McDonald": leave alone.
    if tail.contains(where: \.isUppercase) { return nil }
    guard
      let best = guesses.first(where: {
        $0.lowercased() != word.lowercased()
          && EditDistance.between($0, word) == 1
          && !$0.contains(" ")
      })
    else { return nil }
    return CasePreservation.apply(to: best, like: word)
  }
}

/// The user's text replacements (Settings → Keyboard → Text Replacement).
struct TextReplacementTable: Equatable {
  private(set) var entries: [String: String] = [:]

  init(pairs: [(userInput: String, documentText: String)] = []) {
    for pair in pairs where !pair.userInput.isEmpty && pair.userInput != pair.documentText {
      entries[pair.userInput.lowercased()] = pair.documentText
    }
  }

  var isEmpty: Bool { entries.isEmpty }

  func replacement(forToken token: String) -> String? {
    entries[token.lowercased()]
  }

  /// Phrases whose shortcut starts with what is typed (suggestion candidates).
  func documentTexts(withPrefix prefix: String) -> [String] {
    let key = prefix.lowercased()
    guard !key.isEmpty else { return [] }
    return entries.filter { $0.key.hasPrefix(key) }.sorted { $0.key < $1.key }.map(\.value)
  }
}

/// Plans what typing a boundary key does to the word before the cursor.
struct BoundaryReplacement: Equatable {
  var original: String
  var replacement: String
  var isAutocorrect: Bool
}

/// What Apple's keyboard offers before the first letter of a sentence
/// (iOS 26, empty Telegram field): «Я», «Ну» in Russian; "I", "The", "I'm" in English.
enum SentenceStarters {
  static func suggestions(
    for language: KeyboardLayoutLanguage, contextBefore: String?
  ) -> [Suggestion] {
    guard startsSentence(contextBefore) else { return [] }
    let words = language == .russian ? ["Я", "Ну"] : ["I", "The", "I'm"]
    return words.map { Suggestion(text: $0) }
  }

  /// Empty field, a new line, or a space after the end of a sentence.
  static func startsSentence(_ contextBefore: String?) -> Bool {
    let context = contextBefore ?? ""
    if context.isEmpty || context.hasSuffix("\n") { return true }
    guard context.hasSuffix(" ") else { return false }
    let text = context.trimmingCharacters(in: .whitespaces)
    guard let last = text.last else { return true }
    return ".!?…".contains(last)
  }
}
