import UIKit
import XCTest

private final class FakeChecker: TextChecking {
  var valid: Set<String> = []
  var completionTable: [String: [String]] = [:]
  var guessTable: [String: [String]] = [:]
  func isValidWord(_ word: String) -> Bool { valid.contains(word.lowercased()) }
  func completions(for partial: String) -> [String] { completionTable[partial.lowercased()] ?? [] }
  func guesses(for word: String) -> [String] { guessTable[word.lowercased()] ?? [] }
}

final class SuggestionRulesTests: XCTestCase {
  func testPartialWordIsTheLettersBeforeTheCursor() {
    XCTAssertEqual(WordBoundary.partialWord(contextBefore: "Привет, ми"), "ми")
    XCTAssertEqual(WordBoundary.partialWord(contextBefore: "don't"), "don't")
    XCTAssertEqual(WordBoundary.partialWord(contextBefore: "hello "), "")
    XCTAssertEqual(WordBoundary.partialWord(contextBefore: nil), "")
    XCTAssertEqual(WordBoundary.partialWord(contextBefore: "x2"), "", "digit before: not a word")
    XCTAssertEqual(WordBoundary.partialWord(contextBefore: "google.co"), "", "URL piece")
    XCTAssertEqual(WordBoundary.partialWord(contextBefore: "me@ex"), "", "e-mail piece")
    XCTAssertEqual(WordBoundary.partialWord(contextBefore: "«сл"), "сл")
  }

  func testBoundaryKeys() {
    for key in [" ", "\n", ".", ",", "!", "?", ";", ":", ")"] {
      XCTAssertTrue(WordBoundary.isBoundary(key), key)
    }
    XCTAssertFalse(WordBoundary.isBoundary("a"))
    XCTAssertFalse(WordBoundary.isBoundary("-"))
  }

  func testEditDistance() {
    XCTAssertEqual(EditDistance.between("teh", "the"), 1, "swap")
    XCTAssertEqual(EditDistance.between("привте", "привет"), 1)
    XCTAssertEqual(EditDistance.between("cat", "cart"), 1)
    XCTAssertEqual(EditDistance.between("cat", "dog"), 3)
    XCTAssertEqual(EditDistance.between("", "ab"), 2)
    XCTAssertEqual(EditDistance.between("Word", "word"), 0)
  }

  func testCasePreservation() {
    XCTAssertEqual(CasePreservation.apply(to: "hello", like: "Hel"), "Hello")
    XCTAssertEqual(CasePreservation.apply(to: "hello", like: "HEL"), "HELLO")
    XCTAssertEqual(CasePreservation.apply(to: "hello", like: "hel"), "hello")
    XCTAssertEqual(CasePreservation.apply(to: "привет", like: "Пр"), "Привет")
  }

  func testComposerPutsTheTypedWordFirstAndTwoCandidates() {
    let result = SuggestionComposer.compose(
      typed: "teh", isValidWord: false, guesses: ["the", "ten", "tea"], completions: ["tehran"],
      lexiconMatches: [])
    XCTAssertEqual(result.map(\.text), ["teh", "the", "ten"])
    XCTAssertTrue(result[0].isQuoted, "an unknown word is shown in quotes")
    XCTAssertEqual(result[0].display, "“teh”")
    XCTAssertEqual(result[1].display, "the")
  }

  func testComposerForAValidPrefixPrefersCompletions() {
    let result = SuggestionComposer.compose(
      typed: "hel", isValidWord: true, guesses: ["held"], completions: ["hello", "help", "helmet"],
      lexiconMatches: [])
    XCTAssertEqual(result.map(\.text), ["hel", "hello", "help"])
    XCTAssertFalse(result[0].isQuoted)
  }

  func testComposerKeepsTheCapitalAndDropsDuplicates() {
    let result = SuggestionComposer.compose(
      typed: "Пр", isValidWord: true, guesses: [], completions: ["привет", "Привет", "при"],
      lexiconMatches: [])
    XCTAssertEqual(result.map(\.text), ["Пр", "Привет", "При"])
  }

  func testComposerOffersTextReplacementPhrases() {
    let result = SuggestionComposer.compose(
      typed: "omw", isValidWord: false, guesses: [], completions: [],
      lexiconMatches: ["On my way!"])
    XCTAssertEqual(result.map(\.text), ["omw", "On my way!"])
    XCTAssertTrue(SuggestionComposer.compose(
      typed: "", isValidWord: true, guesses: [], completions: ["x"], lexiconMatches: []).isEmpty)
  }

  // MARK: Autocorrect

  func testAutocorrectNeedsAnUnknownWordOneEditFromTheBestGuess() {
    func fix(_ word: String, _ guesses: [String], valid: Bool = false, rejected: Set<String> = [])
      -> String?
    {
      AutocorrectRules.correction(
        for: word, guesses: guesses, isValidWord: valid, rejectedWords: rejected)
    }
    XCTAssertEqual(fix("teh", ["the", "ten"]), "the")
    XCTAssertEqual(fix("Teh", ["the"]), "The", "keeps the capital")
    XCTAssertEqual(fix("привте", ["привет"]), "привет")
    XCTAssertNil(fix("teh", ["the"], valid: true), "known words are left alone")
    XCTAssertNil(fix("zz", ["zzz"]), "too short")
    XCTAssertNil(fix("helo", ["goodbye"]), "too far")
    XCTAssertNil(fix("teh", ["the"], rejected: ["teh"]), "the user put it back once")
    XCTAssertNil(fix("NASA", ["nasal"]), "acronym")
    XCTAssertNil(fix("iPhne", ["iPhone"]), "camel case")
    XCTAssertNil(fix("abc123", ["abc"]), "digits")
    XCTAssertNil(fix("teh", []))
  }

  // MARK: Text replacements

  func testTextReplacementTable() {
    let table = TextReplacementTable(pairs: [
      ("omw", "On my way!"), ("Мфу", "Мария Фёдоровна"), ("same", "same"), ("", "x"),
    ])
    XCTAssertEqual(table.replacement(forToken: "omw"), "On my way!")
    XCTAssertEqual(table.replacement(forToken: "OMW"), "On my way!")
    XCTAssertEqual(table.replacement(forToken: "мфу"), "Мария Фёдоровна")
    XCTAssertNil(table.replacement(forToken: "same"), "identity entries are not replacements")
    XCTAssertNil(table.replacement(forToken: "hello"))
    XCTAssertEqual(table.documentTexts(withPrefix: "om"), ["On my way!"])
  }

  // MARK: Engine (fake checker)

  func testEngineExpandsATextReplacementAtABoundary() {
    let engine = SuggestionEngine(language: .english, checker: FakeChecker())
    engine.setReplacements(TextReplacementTable(pairs: [("omw", "On my way!")]))
    let plan = engine.replacement(contextBefore: "ok omw", autocorrectEnabled: false)
    XCTAssertEqual(plan, BoundaryReplacement(original: "omw", replacement: "On my way!", isAutocorrect: false))
    XCTAssertNil(engine.replacement(contextBefore: "ok omw!", autocorrectEnabled: false))
  }

  func testEngineAutocorrectsOnlyWhenTheSettingIsOn() {
    let checker = FakeChecker()
    checker.guessTable["teh"] = ["the"]
    let engine = SuggestionEngine(language: .english, checker: checker)
    XCTAssertNil(engine.replacement(contextBefore: "say teh", autocorrectEnabled: false), "default OFF")
    XCTAssertEqual(
      engine.replacement(contextBefore: "say teh", autocorrectEnabled: true),
      BoundaryReplacement(original: "teh", replacement: "the", isAutocorrect: true))
    engine.reject("teh")
    XCTAssertNil(engine.replacement(contextBefore: "say teh", autocorrectEnabled: true))
  }

  func testEngineSuggestionsForThePartialWord() {
    let checker = FakeChecker()
    checker.completionTable["hel"] = ["hello", "help"]
    let engine = SuggestionEngine(language: .english, checker: checker)
    checker.valid = ["hel"]
    XCTAssertEqual(engine.suggestions(contextBefore: "say hel").map(\.text), ["hel", "hello", "help"])
    XCTAssertTrue(engine.suggestions(contextBefore: "say ").isEmpty)
  }

  // MARK: Real UITextChecker (simulator dictionaries)

  /// Facts measured in the simulator (iOS 26.3): both dictionaries exist; English
  /// has completions and guesses; Russian has guesses only (its completions are
  /// empty), so the Russian bar mostly offers corrections.
  func testSystemDictionariesForBothKeyboardLanguages() throws {
    let languages = UITextChecker.availableLanguages
    print("UITEXTCHECKER_LANGUAGES", languages.filter { $0.hasPrefix("ru") || $0.hasPrefix("en") })
    let english = try XCTUnwrap(SystemTextChecker(language: "en_US"), "en_US dictionary")
    _ = english.completions(for: "a")  // the first call loads the lexicon
    XCTAssertTrue(english.isValidWord("hello"))
    XCTAssertFalse(english.isValidWord("helo"))
    XCTAssertTrue(english.guesses(for: "helo").contains("hello"))
    XCTAssertFalse(english.completions(for: "hel").isEmpty)
    guard let russian = SystemTextChecker(language: "ru_RU") else {
      throw XCTSkip("ru_RU is not in UITextChecker.availableLanguages on this runtime")
    }
    XCTAssertTrue(russian.isValidWord("привет"))
    XCTAssertFalse(russian.isValidWord("превет"))
    XCTAssertTrue(russian.guesses(for: "сдлеал").contains("сделал"))
    XCTAssertTrue(russian.guesses(for: "спасиб").contains("спасибо"))
  }

  func testGuessesThatContinueTheTypedPrefixComeFirst() {
    let result = SuggestionComposer.compose(
      typed: "спасиб", isValidWord: false, guesses: ["спаси", "пасиб", "спасибо", "спасиба"],
      completions: [], lexiconMatches: [])
    XCTAssertEqual(result.map(\.text), ["спасиб", "спасибо", "спасиба"])
  }
}

final class SentenceStarterTests: XCTestCase {
  func testStartersAppearOnlyBeforeTheFirstLetterOfASentence() {
    XCTAssertEqual(
      SentenceStarters.suggestions(for: .russian, contextBefore: nil).map(\.text), ["Я", "Ну"])
    XCTAssertEqual(
      SentenceStarters.suggestions(for: .english, contextBefore: "").map(\.text), ["I", "The", "I'm"])
    XCTAssertFalse(SentenceStarters.suggestions(for: .english, contextBefore: "Done. ").isEmpty)
    XCTAssertFalse(SentenceStarters.suggestions(for: .english, contextBefore: "line\n").isEmpty)
    XCTAssertTrue(SentenceStarters.suggestions(for: .english, contextBefore: "I am ").isEmpty)
    XCTAssertTrue(SentenceStarters.suggestions(for: .english, contextBefore: "Done.").isEmpty)
  }
}
