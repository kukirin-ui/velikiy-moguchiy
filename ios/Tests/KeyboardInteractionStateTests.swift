import XCTest

@testable import VelikiyMoguchiy

final class KeyboardInteractionStateTests: XCTestCase {
  func testAllPagesProduceFourRowsWithPositiveKeyWidths() {
    var state = KeyboardInteractionState()
    assertValidLayout(state.layout(inputKind: .standard, needsInputModeSwitchKey: true))

    state.tapPage()
    assertValidLayout(state.layout(inputKind: .standard, needsInputModeSwitchKey: true))

    state.tapShift(at: 1)
    assertValidLayout(state.layout(inputKind: .standard, needsInputModeSwitchKey: true))
  }

  func testSingleShiftIsConsumedAfterText() {
    var state = KeyboardInteractionState()
    state.tapShift(at: 1)
    XCTAssertTrue(state.usesUppercaseLetters)

    state.consumeText()
    XCTAssertEqual(state.capitalization, .lowercase)
  }

  func testDoubleShiftEnablesCapsLockUntilShiftIsTappedAgain() {
    var state = KeyboardInteractionState()
    state.tapShift(at: 1)
    state.tapShift(at: 1.2)
    XCTAssertTrue(state.isCapsLocked)

    state.consumeText()
    XCTAssertTrue(state.isCapsLocked)

    state.tapShift(at: 2)
    XCTAssertEqual(state.capitalization, .lowercase)
  }

  func testPageKeysCycleLettersNumbersSymbolsAndBack() {
    var state = KeyboardInteractionState()
    state.tapPage()
    XCTAssertEqual(state.page, .numbers)
    state.tapShift(at: 1)
    XCTAssertEqual(state.page, .symbols)
    state.tapShift(at: 2)
    XCTAssertEqual(state.page, .numbers)
    state.tapPage()
    XCTAssertEqual(state.page, .letters)
  }

  func testAutomaticCapitalizationDoesNotOverrideCapsLock() {
    var state = KeyboardInteractionState()
    state.tapShift(at: 1)
    state.tapShift(at: 1.2)
    state.applyAutomaticCapitalization(.lowercase)
    XCTAssertEqual(state.capitalization, .capsLock)
  }

  func testInputKindsExposeUsefulContextKeys() {
    let state = KeyboardInteractionState()
    XCTAssertTrue(
      actions(in: state.layout(inputKind: .email, needsInputModeSwitchKey: false))
        .contains(.text("@")))
    XCTAssertTrue(
      actions(in: state.layout(inputKind: .url, needsInputModeSwitchKey: false))
        .contains(.text(".com")))
    XCTAssertFalse(
      actions(in: state.layout(inputKind: .url, needsInputModeSwitchKey: false))
        .contains(.space))
  }

  func testNextKeyboardKeyTracksSystemRequirement() {
    let state = KeyboardInteractionState()
    XCTAssertTrue(
      actions(in: state.layout(inputKind: .standard, needsInputModeSwitchKey: true))
        .contains(.nextKeyboard))
    XCTAssertFalse(
      actions(in: state.layout(inputKind: .standard, needsInputModeSwitchKey: false))
        .contains(.nextKeyboard))
  }

  func testEnglishAlternateCharactersPreserveShiftCase() {
    var state = KeyboardInteractionState()
    XCTAssertEqual(Array(state.alternateCharacters(for: "a").prefix(3)), ["a", "à", "á"])

    state.tapShift(at: 1)
    XCTAssertEqual(Array(state.alternateCharacters(for: "A").prefix(3)), ["A", "À", "Á"])
  }

  func testRussianLettersMatchApplesLayout() {
    let state = KeyboardInteractionState(language: .russian)
    let rows = state.layout(inputKind: .standard, needsInputModeSwitchKey: false)
    func letters(_ row: KeyboardLayoutRow) -> String {
      row.keys.compactMap { key -> String? in
        if case .text(let text) = key.action { return text }
        return nil
      }.joined()
    }
    XCTAssertEqual(letters(rows[0]), "йцукенгшщзх")
    XCTAssertEqual(letters(rows[1]), "фывапролджэ")
    XCTAssertEqual(letters(rows[2]), "ячсмитьбю")
    XCTAssertFalse(rows.flatMap(\.keys).map(\.action).contains(.text("ё")))
    XCTAssertFalse(rows.flatMap(\.keys).map(\.action).contains(.text("ъ")))
  }

  func testRussianLongPressOffersYoAndHardSign() {
    var state = KeyboardInteractionState(language: .russian)
    XCTAssertEqual(state.alternateCharacters(for: "е"), ["е", "ё"])
    XCTAssertEqual(state.alternateCharacters(for: "ь"), ["ь", "ъ"])
    XCTAssertTrue(state.alternateCharacters(for: "й").isEmpty)
    state.tapShift(at: 1)
    XCTAssertEqual(state.alternateCharacters(for: "Е"), ["Е", "Ё"])
    XCTAssertEqual(state.alternateCharacters(for: "Ь"), ["Ь", "Ъ"])
  }

  func testRussianNumbersPageUsesTheRuble() {
    var state = KeyboardInteractionState(language: .russian)
    state.tapPage()
    let actions = state.layout(inputKind: .standard, needsInputModeSwitchKey: false)
      .flatMap(\.keys).map(\.action)
    XCTAssertTrue(actions.contains(.text("₽")))
    XCTAssertFalse(actions.contains(.text("$")))
  }

  func testEnglishLayoutDoesNotOfferCyrillicAlternates() {
    let state = KeyboardInteractionState(language: .english)
    XCTAssertTrue(state.alternateCharacters(for: "е").isEmpty)
    XCTAssertEqual(state.language.letterRowStrings[0], "qwertyuiop")
  }

  func testSymbolPagesHaveFivePunctuationKeysBetweenTheSideKeys() {
    var state = KeyboardInteractionState()
    state.tapPage()
    for _ in 0..<2 {
      let third = state.layout(inputKind: .standard, needsInputModeSwitchKey: false)[2]
      XCTAssertEqual(third.keys.count, 7)
      XCTAssertEqual(third.keys.first?.action, .shift)
      XCTAssertEqual(third.keys.last?.action, .backspace)
      state.tapShift(at: 1)
    }
  }

  func testMicrophoneSitsRightAfterThePageKey() {
    let state = KeyboardInteractionState()
    for globe in [false, true] {
      let bottom = state.layout(inputKind: .standard, needsInputModeSwitchKey: globe)[3]
      let actions = bottom.keys.map(\.action)
      XCTAssertEqual(actions.first, .page)
      XCTAssertEqual(actions.last, .returnKey)
      XCTAssertEqual(actions.contains(.nextKeyboard), globe)
      XCTAssertEqual(actions.firstIndex(of: .microphone), globe ? 2 : 1)
    }
  }

  private func actions(in rows: [KeyboardLayoutRow]) -> [KeyboardKeyAction] {
    rows.flatMap(\.keys).map(\.action)
  }

  private func assertValidLayout(
    _ rows: [KeyboardLayoutRow],
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(rows.count, 4, file: file, line: line)
    XCTAssertTrue(rows.allSatisfy { !$0.keys.isEmpty }, file: file, line: line)
    XCTAssertTrue(rows.flatMap(\.keys).allSatisfy { $0.width > 0 }, file: file, line: line)
    let allActions = actions(in: rows)
    XCTAssertEqual(allActions.filter { $0 == .backspace }.count, 1, file: file, line: line)
    XCTAssertEqual(allActions.filter { $0 == .returnKey }.count, 1, file: file, line: line)
    XCTAssertEqual(allActions.filter { $0 == .page }.count, 1, file: file, line: line)
  }
}
