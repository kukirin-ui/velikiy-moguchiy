import Foundation

/// Holding ⌫ deletes character by character after a short delay and, like on
/// Apple's keyboard, switches to whole words after a while.
enum DeleteStep: Equatable {
  case character
  case word
}

struct DeleteRepeatPolicy: Equatable {
  /// Pause before the first repeat.
  var initialDelay: TimeInterval = 0.42
  /// Interval between character deletions.
  var characterInterval: TimeInterval = 0.072
  /// Interval between word deletions.
  var wordInterval: TimeInterval = 0.1
  /// Words start after this many repeated characters or this much time held,
  /// whichever comes first.
  var repeatsBeforeWords = 10
  var holdBeforeWords: TimeInterval = 1.2

  static let standard = DeleteRepeatPolicy()
}

/// Pure state of one ⌫ hold; the surface feeds it timer ticks.
struct DeleteRepeatController: Equatable {
  let policy: DeleteRepeatPolicy
  private(set) var startedAt: TimeInterval?
  private(set) var characterRepeats = 0
  private(set) var wordRepeats = 0

  init(policy: DeleteRepeatPolicy = .standard) {
    self.policy = policy
  }

  var isHolding: Bool { startedAt != nil }

  /// The finger went down. Returns the delay before the first repeat.
  mutating func begin(at time: TimeInterval) -> TimeInterval {
    startedAt = time
    characterRepeats = 0
    wordRepeats = 0
    return policy.initialDelay
  }

  mutating func end() {
    startedAt = nil
  }

  /// One timer tick: what to delete, and how long to wait for the next tick.
  mutating func tick(at time: TimeInterval) -> (step: DeleteStep, nextInterval: TimeInterval)? {
    guard let startedAt else { return nil }
    let held = time - startedAt
    let wordsActive =
      wordRepeats > 0
      || characterRepeats >= policy.repeatsBeforeWords
      || held >= policy.holdBeforeWords
    if wordsActive {
      wordRepeats += 1
      return (.word, policy.wordInterval)
    }
    characterRepeats += 1
    return (.character, policy.characterInterval)
  }
}

/// How many characters "delete a word" removes: the spaces before the cursor
/// plus the word (letters and digits) in front of them, or a single punctuation
/// mark when no word is there.
enum DeleteWordRange {
  static let maximumLength = 64

  static func characterCount(contextBefore: String?) -> Int {
    guard let context = contextBefore, !context.isEmpty else { return 1 }
    var count = 0
    var iterator = context.reversed().makeIterator()
    var current = iterator.next()
    while let character = current, character.isWhitespace, !character.isNewline {
      count += 1
      current = iterator.next()
    }
    guard let first = current else { return max(count, 1) }
    if first.isNewline { return count + 1 }
    if isWordCharacter(first) {
      while let character = current, isWordCharacter(character) {
        count += 1
        if count >= maximumLength { break }
        current = iterator.next()
      }
    } else {
      count += 1
    }
    return max(count, 1)
  }

  static func isWordCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || character == "'" || character == "’"
      || character == "_"
  }
}
