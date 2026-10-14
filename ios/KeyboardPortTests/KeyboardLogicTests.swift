import UIKit
import XCTest

/// Autocapitalization, keyboardType mapping, Shift, delete repeat, smart punctuation.
final class AutocapitalizationRulesTests: XCTestCase {
  private func shifted(_ context: String?, type: UITextAutocapitalizationType = .sentences) -> Bool {
    AutocapitalizationRules.capitalization(type: type, contextBefore: context) == .shifted
  }

  func testStartOfTextAndNewLinesCapitalize() {
    XCTAssertTrue(shifted(nil))
    XCTAssertTrue(shifted(""))
    XCTAssertTrue(shifted("   "))
    XCTAssertTrue(shifted("Привет\n"))
    XCTAssertTrue(shifted("Hello.\n\n"))
  }

  func testCapitalOnlyAfterTheTerminatorAndASpace() {
    XCTAssertTrue(shifted("Привет. "))
    XCTAssertTrue(shifted("Что? "))
    XCTAssertTrue(shifted("Ого! "))
    XCTAssertTrue(shifted("Hello.  "), "several spaces")
    XCTAssertFalse(shifted("Привет."), "no space yet: could be a domain or a number")
    XCTAssertFalse(shifted("Привет"))
    XCTAssertFalse(shifted("Привет, "))
    XCTAssertFalse(shifted("Привет "))
  }

  func testUrlsDecimalsAndDottedAbbreviationsStayLowercase() {
    XCTAssertFalse(shifted("google.com"))
    XCTAssertFalse(shifted("see google."))
    XCTAssertFalse(shifted("3.14"))
    XCTAssertFalse(shifted("e.g"))
    XCTAssertFalse(shifted("т.е"))
    XCTAssertFalse(shifted("Pi is 3.14"))
  }

  func testKnownAbbreviationsDoNotStartASentence() {
    XCTAssertFalse(shifted("т.е. "))
    XCTAssertFalse(shifted("и т.д. "))
    XCTAssertFalse(shifted("e.g. "))
    XCTAssertFalse(shifted("Mr. "))
    XCTAssertFalse(shifted("Dr. "))
    XCTAssertFalse(shifted("А. С. "), "initials")
    XCTAssertTrue(shifted("Это конец. "))
    XCTAssertTrue(shifted("I said no. "))
  }

  func testEllipsisAndClosingQuotesAreSeenThrough() {
    XCTAssertTrue(shifted("Ну… "))
    XCTAssertTrue(shifted("Он сказал: «Идём.» "))
    XCTAssertTrue(shifted("She said “stop!” "))
    XCTAssertTrue(shifted("(Конец.) "))
    XCTAssertFalse(shifted("(конец) "))
  }

  func testOtherAutocapitalizationTypes() {
    XCTAssertFalse(shifted("Привет. ", type: .none))
    XCTAssertTrue(shifted("анна", type: .allCharacters))
    XCTAssertTrue(shifted("Hello ", type: .words))
    XCTAssertFalse(shifted("Hello", type: .words))
    XCTAssertTrue(shifted(nil, type: .words))
  }
}

final class KeyboardTypeMappingTests: XCTestCase {
  private func profile(_ type: UIKeyboardType?) -> KeyboardInputProfile {
    KeyboardInputProfile.resolve(keyboardType: type)
  }

  func testKeyboardTypesMapToLayouts() {
    XCTAssertEqual(profile(.default).kind, .standard)
    XCTAssertEqual(profile(nil).kind, .standard)
    XCTAssertEqual(profile(.asciiCapable).kind, .standard)
    XCTAssertEqual(profile(.emailAddress).kind, .email)
    XCTAssertEqual(profile(.URL).kind, .url)
    XCTAssertEqual(profile(.webSearch).kind, .webSearch)
    XCTAssertEqual(profile(.twitter).kind, .twitter)
    XCTAssertEqual(profile(.numberPad).kind, .numberPad)
    XCTAssertEqual(profile(.asciiCapableNumberPad).kind, .numberPad)
    XCTAssertEqual(profile(.decimalPad).kind, .decimalPad)
    XCTAssertEqual(profile(.phonePad).kind, .numberPad, "fallback: iOS normally swaps in its own pad")
    XCTAssertEqual(profile(.namePhonePad).kind, .numberPad)
  }

  func testSafariStyleAddressBarKeepsTheSpaceBar() {
    let addressBar = KeyboardInputProfile.resolve(keyboardType: .URL, returnKeyType: .go)
    XCTAssertEqual(addressBar.kind, .webSearch)
    XCTAssertEqual(KeyboardInputProfile.resolve(keyboardType: .URL, returnKeyType: .done).kind, .url)
  }

  func testStripIsDroppedLikeApplesInTechnicalFieldsWithoutAutocorrection() {
    func strip(_ type: UIKeyboardType, _ autocorrection: UITextAutocorrectionType) -> Bool {
      KeyboardInputProfile.resolve(keyboardType: type, autocorrectionType: autocorrection)
        .showsSuggestionStrip
    }
    for type: UIKeyboardType in [.webSearch, .URL, .emailAddress, .numbersAndPunctuation] {
      XCTAssertFalse(strip(type, .no), "\(type.rawValue)")
      XCTAssertTrue(strip(type, .default), "\(type.rawValue)")
    }
    XCTAssertTrue(strip(.default, .no), "plain text keeps the strip")
    XCTAssertTrue(strip(.twitter, .no))
    XCTAssertFalse(strip(.numberPad, .default))
    XCTAssertFalse(strip(.decimalPad, .yes))
  }

  func testWithoutTheStripTheKeyboardIsShorterAndTheKeysStayPut() {
    for geometry in [KeyboardGeometry.portrait, .landscape] {
      XCTAssertEqual(
        geometry.totalHeight(showsStrip: true) - geometry.totalHeight(showsStrip: false), 27,
        accuracy: 0.001)
      XCTAssertEqual(geometry.totalHeight(showsStrip: true), geometry.toolbarHeight + geometry.gridHeight + geometry.bottomPadding)
    }
  }

  func testNumbersAndPunctuationOpensOnThe123Page() {
    XCTAssertTrue(profile(.numbersAndPunctuation).startsOnNumbers)
    XCTAssertEqual(profile(.numbersAndPunctuation).kind, .standard)
    XCTAssertFalse(profile(.default).startsOnNumbers)
  }

  private func keys(_ rows: [KeyboardLayoutRow]) -> [KeyboardKeyAction] {
    rows.flatMap { $0.keys.map(\.action) }
  }

  func testDigitPadLayoutIsThreeByFourWithoutLettersOrMicrophone() {
    let state = KeyboardInteractionState(language: .russian, decimalSeparator: ",")
    let rows = state.layout(inputKind: .numberPad, needsInputModeSwitchKey: false)
    XCTAssertEqual(rows.count, 4)
    XCTAssertTrue(rows.allSatisfy { $0.keys.count == 3 })
    XCTAssertEqual(
      keys(rows),
      ["1", "2", "3", "4", "5", "6", "7", "8", "9"].map { .text($0) }
        + [.blank, .text("0"), .backspace])
    XCTAssertFalse(keys(rows).contains(.microphone))
    XCTAssertFalse(keys(rows).contains(.returnKey))
  }

  func testNumberPadPutsTheGlobeInTheCornerOnlyWhenIosAsksForIt() {
    let state = KeyboardInteractionState(language: .english)
    XCTAssertEqual(
      keys(state.layout(inputKind: .numberPad, needsInputModeSwitchKey: true)).dropFirst(9).first,
      .nextKeyboard)
    XCTAssertEqual(
      keys(state.layout(inputKind: .numberPad, needsInputModeSwitchKey: false)).dropFirst(9).first,
      .blank)
  }

  func testDecimalPadCornerIsTheRegionsSeparator() {
    let russian = KeyboardInteractionState(language: .russian, decimalSeparator: ",")
    let english = KeyboardInteractionState(language: .english, decimalSeparator: ".")
    XCTAssertEqual(
      keys(russian.layout(inputKind: .decimalPad, needsInputModeSwitchKey: true)).dropFirst(9).first,
      .text(","))
    XCTAssertEqual(
      keys(english.layout(inputKind: .decimalPad, needsInputModeSwitchKey: false)).dropFirst(9).first,
      .text("."))
  }

  func testWebSearchBottomRowHasASpaceBarAndAPeriod() {
    let state = KeyboardInteractionState(language: .english)
    let bottom = state.layout(inputKind: .webSearch, needsInputModeSwitchKey: false).last!.keys.map(\.action)
    XCTAssertEqual(bottom, [.page, .microphone, .space, .text("."), .returnKey])
  }

  func testUrlBottomRowHasNoSpaceBarAndTheRegionsDomain() {
    let english = KeyboardInteractionState(language: .english)
    let russian = KeyboardInteractionState(language: .russian)
    XCTAssertEqual(
      english.layout(inputKind: .url, needsInputModeSwitchKey: false).last!.keys.map(\.action),
      [.page, .microphone, .text("."), .text("/"), .text(".com"), .returnKey])
    XCTAssertEqual(
      russian.layout(inputKind: .url, needsInputModeSwitchKey: false).last!.keys.map(\.action),
      [.page, .microphone, .text("."), .text("/"), .text(".com"), .returnKey],
      "Apple shows .com on the Russian keyboard too")
    XCTAssertEqual(english.alternateCharacters(for: ".com"), [".com", ".ru", ".org", ".net", ".edu"])
    XCTAssertEqual(russian.alternateCharacters(for: ".ru").first, ".ru")
  }

  func testEmailAndTwitterBottomRows() {
    let state = KeyboardInteractionState(language: .english)
    XCTAssertEqual(
      state.layout(inputKind: .email, needsInputModeSwitchKey: false).last!.keys.map(\.action),
      [.page, .microphone, .space, .text("@"), .text("."), .returnKey])
    XCTAssertEqual(
      state.layout(inputKind: .twitter, needsInputModeSwitchKey: false).last!.keys.map(\.action),
      [.page, .microphone, .space, .text("@"), .text("#"), .returnKey])
  }

  func testTechnicalKindsDisableSmartPunctuationAndCorrection() {
    XCTAssertTrue(KeyboardInputKind.url.isTechnical)
    XCTAssertTrue(KeyboardInputKind.numberPad.isTechnical)
    XCTAssertFalse(KeyboardInputKind.standard.isTechnical)
    XCTAssertFalse(KeyboardInputKind.twitter.isTechnical)
  }
}

final class ShiftStateTests: XCTestCase {
  func testDoubleTapGivesCapsLockFromAnAutomaticCapital() {
    var state = KeyboardInteractionState(language: .english)
    state.applyAutomaticCapitalization(.shifted)
    state.tapShift(at: 10.0)
    XCTAssertEqual(state.capitalization, .lowercase, "first tap cancels the automatic capital")
    state.tapShift(at: 10.2)
    XCTAssertEqual(state.capitalization, .capsLock, "second tap within 0.32 s locks")
    state.tapShift(at: 11)
    XCTAssertEqual(state.capitalization, .lowercase)
  }

  func testDoubleTapFromLowercaseStillGivesCapsLock() {
    var state = KeyboardInteractionState(language: .english)
    state.tapShift(at: 5.0)
    XCTAssertEqual(state.capitalization, .shifted)
    state.tapShift(at: 5.25)
    XCTAssertEqual(state.capitalization, .capsLock)
  }

  func testSlowSecondTapJustTogglesBack() {
    var state = KeyboardInteractionState(language: .english)
    state.tapShift(at: 5.0)
    state.tapShift(at: 5.6)
    XCTAssertEqual(state.capitalization, .lowercase)
  }

  func testTypingConsumesAShiftButNotCapsLock() {
    var state = KeyboardInteractionState(language: .english)
    state.tapShift(at: 1)
    state.consumeText()
    XCTAssertEqual(state.capitalization, .lowercase)
    state.tapShift(at: 2.0)
    state.tapShift(at: 2.1)
    state.consumeText()
    XCTAssertEqual(state.capitalization, .capsLock)
  }
}

final class DeleteRepeatTests: XCTestCase {
  func testCharactersFirstThenWordsAfterTenRepeatsOrOneAndAHalfTenthsSeconds() {
    var controller = DeleteRepeatController()
    XCTAssertEqual(controller.begin(at: 100), 0.42)
    var steps: [DeleteStep] = []
    var time = 100.42
    for _ in 0..<10 {
      let result = controller.tick(at: time)!
      steps.append(result.step)
      XCTAssertEqual(result.nextInterval, 0.072, accuracy: 0.0001)
      time += 0.072
    }
    XCTAssertEqual(steps, Array(repeating: .character, count: 10))
    let eleventh = controller.tick(at: time)!
    XCTAssertEqual(eleventh.step, .word, "10 character repeats switch to words")
    XCTAssertEqual(eleventh.nextInterval, 0.1, accuracy: 0.0001)
  }

  func testHoldingForTwelveTenthsOfASecondSwitchesToWordsEarly() {
    var controller = DeleteRepeatController()
    _ = controller.begin(at: 0)
    XCTAssertEqual(controller.tick(at: 0.42)?.step, .character)
    XCTAssertEqual(controller.tick(at: 1.19)?.step, .character)
    XCTAssertEqual(controller.tick(at: 1.2)?.step, .word)
    XCTAssertEqual(controller.tick(at: 1.3)?.step, .word, "stays in word mode")
  }

  func testEndStopsTheRepeatAndANewHoldStartsOverInCharacterMode() {
    var controller = DeleteRepeatController()
    _ = controller.begin(at: 0)
    _ = controller.tick(at: 2)
    controller.end()
    XCTAssertNil(controller.tick(at: 3))
    _ = controller.begin(at: 10)
    XCTAssertEqual(controller.tick(at: 10.42)?.step, .character)
  }

  func testWordDeletionCountsSpacesPlusTheWord() {
    XCTAssertEqual(DeleteWordRange.characterCount(contextBefore: "привет мир"), 3)
    XCTAssertEqual(DeleteWordRange.characterCount(contextBefore: "привет мир  "), 5)
    XCTAssertEqual(DeleteWordRange.characterCount(contextBefore: "hello, "), 2, "space and the comma")
    XCTAssertEqual(DeleteWordRange.characterCount(contextBefore: "hello"), 5)
    XCTAssertEqual(DeleteWordRange.characterCount(contextBefore: "строка\n"), 1, "a newline goes alone")
    XCTAssertEqual(DeleteWordRange.characterCount(contextBefore: "don’t"), 5)
    XCTAssertEqual(DeleteWordRange.characterCount(contextBefore: nil), 1)
    XCTAssertEqual(DeleteWordRange.characterCount(contextBefore: ""), 1)
    XCTAssertEqual(DeleteWordRange.characterCount(contextBefore: "a1b2 "), 5)
  }
}

final class SmartPunctuationTests: XCTestCase {
  private let on = SmartPunctuationSettings(quotes: true, dashes: true)

  private func edit(
    _ text: String, after context: String?, _ language: KeyboardLayoutLanguage = .russian,
    settings: SmartPunctuationSettings? = nil
  ) -> PunctuationEdit {
    SmartPunctuation.edit(
      typing: text, contextBefore: context, language: language, settings: settings ?? on)
  }

  func testRussianQuotesOpenAndClose() {
    XCTAssertEqual(edit("\"", after: nil).insert, "«")
    XCTAssertEqual(edit("\"", after: "Он сказал ").insert, "«")
    XCTAssertEqual(edit("\"", after: "(").insert, "«")
    XCTAssertEqual(edit("\"", after: "Идём").insert, "»")
    XCTAssertEqual(edit("\"", after: "Идём.").insert, "»")
  }

  func testEnglishUsesCurlyQuotesAndApostrophes() {
    XCTAssertEqual(edit("\"", after: "He said ", .english).insert, "“")
    XCTAssertEqual(edit("\"", after: "stop", .english).insert, "”")
    XCTAssertEqual(edit("'", after: "don", .english).insert, "’")
    XCTAssertEqual(edit("'", after: "He said ", .english).insert, "‘")
  }

  func testDoubleHyphenBecomesAnEmDash() {
    XCTAssertEqual(edit("-", after: "слово-"), PunctuationEdit(deleteBackwardCount: 1, insert: "—"))
    XCTAssertEqual(edit("-", after: "слово"), PunctuationEdit(deleteBackwardCount: 0, insert: "-"))
    XCTAssertEqual(edit("-", after: "слово—"), PunctuationEdit(deleteBackwardCount: 0, insert: "-"))
  }

  func testThreeDotsBecomeAnEllipsis() {
    XCTAssertEqual(edit(".", after: "Ну.."), PunctuationEdit(deleteBackwardCount: 2, insert: "…"))
    XCTAssertEqual(edit(".", after: "Ну."), PunctuationEdit(deleteBackwardCount: 0, insert: "."))
  }

  func testSwitchedOffLeavesTextAlone() {
    XCTAssertEqual(edit("\"", after: nil, settings: .off).insert, "\"")
    XCTAssertEqual(edit("-", after: "a-", settings: .off).insert, "-")
    let quotesOnly = SmartPunctuationSettings(quotes: true, dashes: false)
    XCTAssertEqual(edit("-", after: "a-", settings: quotesOnly).insert, "-")
    XCTAssertEqual(edit("\"", after: nil, settings: quotesOnly).insert, "«")
  }

  func testFieldTraitsAndTechnicalKindsDecideTheSettings() {
    XCTAssertEqual(
      SmartPunctuationSettings.resolve(quotes: .default, dashes: .default, inputKind: .standard),
      SmartPunctuationSettings(quotes: true, dashes: true))
    XCTAssertEqual(
      SmartPunctuationSettings.resolve(quotes: .no, dashes: .yes, inputKind: .standard),
      SmartPunctuationSettings(quotes: false, dashes: true))
    XCTAssertEqual(
      SmartPunctuationSettings.resolve(quotes: nil, dashes: nil, inputKind: .standard),
      SmartPunctuationSettings(quotes: true, dashes: true))
    XCTAssertEqual(
      SmartPunctuationSettings.resolve(quotes: .yes, dashes: .yes, inputKind: .url), .off)
    XCTAssertEqual(
      SmartPunctuationSettings.resolve(quotes: .yes, dashes: .yes, inputKind: .email), .off)
  }

  func testRussianLongPressVariantsOfTheQuoteAndEllipsisKey() {
    let russian = KeyboardInteractionState(language: .russian)
    XCTAssertEqual(russian.alternateCharacters(for: "\""), ["\"", "«", "»", "„", "“", "”"])
    XCTAssertEqual(russian.alternateCharacters(for: "."), [".", "…"])
    XCTAssertEqual(russian.alternateCharacters(for: "-"), ["-", "–", "—", "•"])
  }
}

final class TrackpadCursorTests: XCTestCase {
  func testStepsAreCountedFromTheAnchorWithoutRepeating() {
    var cursor = TrackpadCursor(anchor: CGPoint(x: 100, y: 100))
    XCTAssertEqual(cursor.steps(to: CGPoint(x: 135, y: 100)).characters, 3)
    XCTAssertEqual(cursor.steps(to: CGPoint(x: 135, y: 100)).characters, 0)
    XCTAssertEqual(cursor.steps(to: CGPoint(x: 100, y: 100)).characters, -3)
    let vertical = cursor.steps(to: CGPoint(x: 100, y: 145))
    XCTAssertEqual(vertical.lines, 2)
    XCTAssertEqual(vertical.characters, 0)
  }

  func testVerticalOffsetKeepsTheColumnWhereThePreviousLineAllows() {
    // "hello\nworld|" cursor after "world": up goes to column 5 of "hello" = end of it.
    XCTAssertEqual(
      TrackpadCursor.verticalOffset(contextBefore: "hello\nwor", contextAfter: "ld", direction: -1),
      -(3 + 1 + (5 - 3)))
    // Previous line shorter than the column: lands at its end.
    XCTAssertEqual(
      TrackpadCursor.verticalOffset(contextBefore: "ab\nlonger line", contextAfter: "", direction: -1),
      -(11 + 1 + 0))
    // Down from the first line.
    XCTAssertEqual(
      TrackpadCursor.verticalOffset(contextBefore: "hel", contextAfter: "lo\nworld", direction: 1),
      2 + 1 + 3)
    // Down from the last line goes to its end; up from the first goes to its start.
    XCTAssertEqual(
      TrackpadCursor.verticalOffset(contextBefore: "abc", contextAfter: "de", direction: 1), 2)
    XCTAssertEqual(
      TrackpadCursor.verticalOffset(contextBefore: "abc", contextAfter: "de", direction: -1), -3)
  }
}
