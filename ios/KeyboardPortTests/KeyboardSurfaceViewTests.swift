import UIKit
import XCTest

@MainActor
final class KeyboardSurfaceViewTests: XCTestCase {
  func testTypingConsumesSingleShiftAndUsesUppercaseText() throws {
    let (surface, delegate) = makeSurface()

    surface.activate(try button("keyboard-shift-key", in: surface).key.action)
    XCTAssertNotNil(findButton("keyboard-key-Q", in: surface))

    let q = try button("keyboard-key-Q", in: surface)
    surface.activate(q.key.action)

    XCTAssertEqual(delegate.insertedText, ["Q"])
    XCTAssertEqual(surface.interactionState.capitalization, .lowercase)
    XCTAssertNotNil(findButton("keyboard-key-q", in: surface))
  }

  func testSpaceAndDeleteDispatchExactlyOnceForATap() throws {
    let (surface, delegate) = makeSurface()

    surface.activate(try button("keyboard-space-key", in: surface).key.action)
    surface.activate(try button("keyboard-delete-key", in: surface).key.action)

    XCTAssertEqual(delegate.insertedText, [" "])
    XCTAssertEqual(delegate.deleteCount, 1)
  }

  func testInputClickPlaysOnKeyDownNotOnKeyUpAndFollowsTheToggle() throws {
    let (surface, delegate) = makeSurface()

    press("keyboard-key-q", in: surface, finger: 1, release: false)
    XCTAssertEqual(delegate.clickCount, 1, "click on key-down")
    XCTAssertEqual(delegate.insertedText, [], "text only on release")
    release("keyboard-key-q", in: surface, finger: 1)
    XCTAssertEqual(delegate.clickCount, 1, "no second click on key-up")
    XCTAssertEqual(delegate.insertedText, ["q"])

    surface.feedbackPolicy = KeyFeedbackPolicy(
      hasFullAccess: true, hapticsEnabled: true, clickSoundEnabled: false)
    tap("keyboard-key-q", in: surface)
    XCTAssertEqual(delegate.clickCount, 1, "toggle off: silent")
  }

  func testEveryKindOfKeyGivesKeyDownFeedback() throws {
    let (surface, delegate) = makeSurface()
    let ids = [
      "keyboard-space-key", "keyboard-delete-key", "keyboard-shift-key",
      "keyboard-page-key", "keyboard-microphone-key", "keyboard-return-key",
    ]
    for id in ids {
      let before = delegate.clickCount
      press(id, in: surface, finger: 1, release: false)
      XCTAssertEqual(delegate.clickCount, before + 1, id)
      release(id, in: surface, finger: 1)
      // Pressing "123" swaps the page; go back so the next ids exist.
      if id == "keyboard-page-key" {
        surface.activate(.page)
        surface.layoutIfNeeded()
      }
    }
  }

  func testPageKeysRenderNumbersThenSymbols() throws {
    let (surface, _) = makeSurface()

    surface.activate(try button("keyboard-page-key", in: surface).key.action)
    XCTAssertEqual(surface.interactionState.page, .numbers)
    XCTAssertNotNil(findButton("keyboard-key-1", in: surface))

    surface.activate(try button("keyboard-shift-key", in: surface).key.action)
    XCTAssertEqual(surface.interactionState.page, .symbols)
    XCTAssertNotNil(findButton("keyboard-key-[", in: surface))
  }

  func testBottomRowPutsTheMicrophoneInTheEmojiSlot() throws {
    let (surface, delegate) = makeSurface()
    surface.updateInputContext(kind: .standard, returnKeyType: .default, needsInputModeSwitchKey: false)
    surface.layoutIfNeeded()
    let page = try button("keyboard-page-key", in: surface)
    let mic = try button("keyboard-microphone-key", in: surface)
    let space = try button("keyboard-space-key", in: surface)
    XCTAssertLessThan(page.frame.maxX, mic.frame.minX)
    XCTAssertLessThan(mic.frame.maxX, space.frame.minX)
    XCTAssertNil(findButton("keyboard-next-keyboard-key", in: surface))

    surface.activate(mic.key.action)
    XCTAssertEqual(delegate.microphoneTaps, 1)
  }

  func testGlobeKeyAppearsBetweenPageAndMicrophoneOnlyWhenRequested() throws {
    let (surface, _) = makeSurface()
    let globe = try button("keyboard-next-keyboard-key", in: surface)
    let mic = try button("keyboard-microphone-key", in: surface)
    XCTAssertLessThan(globe.frame.maxX, mic.frame.minX)
  }

  func testTypingLockLeavesTheMicrophoneUsable() throws {
    let (surface, _) = makeSurface()
    surface.setTypingEnabled(false)
    XCTAssertFalse(try button("keyboard-key-q", in: surface).isEnabled)
    XCTAssertTrue(try button("keyboard-microphone-key", in: surface).isEnabled)
    surface.setTypingEnabled(true)
    XCTAssertTrue(try button("keyboard-key-q", in: surface).isEnabled)
  }

  func testRussianKeyboardUsesApplesLayoutAndKeyHeights() throws {
    let surface = KeyboardSurfaceView(
      language: .russian, frame: CGRect(x: 0, y: 0, width: 402, height: 205))
    surface.updateInputContext(kind: .standard, returnKeyType: .default, needsInputModeSwitchKey: false)
    surface.layoutIfNeeded()
    let й = try button("keyboard-key-й", in: surface)
    let э = try button("keyboard-key-э", in: surface)
    let ю = try button("keyboard-key-ю", in: surface)
    XCTAssertEqual(й.frame.height, 43, accuracy: 0.5)
    // Apple: 6.5 pt margins and 6 pt gaps on every width, letters take the rest.
    XCTAssertEqual(й.frame.width, 29.9, accuracy: 0.35)
    XCTAssertEqual(try button("keyboard-key-ц", in: surface).frame.minX - й.frame.maxX, 6, accuracy: 0.35)
    XCTAssertEqual(й.frame.minX, 6.5, accuracy: 0.35)
    surface.frame.size.width = 393
    surface.layoutIfNeeded()
    XCTAssertEqual(й.frame.width, 29.1, accuracy: 0.35, "iPhone 15/16 width")
    surface.frame.size.width = 402
    surface.layoutIfNeeded()
    XCTAssertEqual(э.frame.minY - й.frame.minY, 54, accuracy: 0.5, "row pitch is 54 pt")
    XCTAssertEqual(ю.frame.minY - й.frame.minY, 108, accuracy: 0.5)
    XCTAssertNil(findButton("keyboard-key-ё", in: surface), "ё and ъ come only from long press")
    XCTAssertNil(findButton("keyboard-key-ъ", in: surface))
    XCTAssertEqual(findButton("keyboard-space-key", in: surface)?.accessibilityLabel, "пробел")
  }

  func testReturnKeyIsAccentOnlyForActionReturnTypes() throws {
    let (surface, _) = makeSurface()
    XCTAssertEqual(try button("keyboard-return-key", in: surface).key.style, .system)
    surface.updateInputContext(kind: .standard, returnKeyType: .send, needsInputModeSwitchKey: true)
    XCTAssertEqual(try button("keyboard-return-key", in: surface).key.style, .accent)
    surface.updateInputContext(kind: .standard, returnKeyType: .next, needsInputModeSwitchKey: true)
    XCTAssertEqual(try button("keyboard-return-key", in: surface).key.style, .system)
  }

  func testContextChangesRebuildTheBottomRow() {
    let (surface, _) = makeSurface()

    surface.updateInputContext(
      kind: .email,
      returnKeyType: .send,
      needsInputModeSwitchKey: false
    )
    XCTAssertNotNil(findButton("keyboard-key-@", in: surface))
    XCTAssertNotNil(findButton("keyboard-space-key", in: surface))
    XCTAssertNil(findButton("keyboard-next-keyboard-key", in: surface))
    XCTAssertEqual(findButton("keyboard-return-key", in: surface)?.accessibilityLabel, "send")

    surface.updateInputContext(
      kind: .url,
      returnKeyType: .go,
      needsInputModeSwitchKey: true
    )
    XCTAssertNotNil(findButton("keyboard-key-.com", in: surface))
    XCTAssertNil(findButton("keyboard-space-key", in: surface))
    XCTAssertNotNil(findButton("keyboard-next-keyboard-key", in: surface))
  }

  func testRenderedPhoneLayoutHasNoAmbiguousSubviews() {
    let (surface, _) = makeSurface()
    surface.layoutIfNeeded()
    XCTAssertFalse(allSubviews(of: surface).contains(where: \.hasAmbiguousLayout))
  }

  func testRenderedPhoneLayoutFillsAvailableWidth() throws {
    let (surface, _) = makeSurface()
    surface.layoutIfNeeded()

    let q = try button("keyboard-key-q", in: surface)
    let p = try button("keyboard-key-p", in: surface)
    let qFrame = q.convert(q.bounds, to: surface)
    let pFrame = p.convert(p.bounds, to: surface)

    XCTAssertGreaterThan(qFrame.width, 25)
    XCTAssertLessThan(qFrame.minX, 10)
    XCTAssertGreaterThan(pFrame.maxX, 380)
  }

  func testWideLayoutKeepsTypingKeysAtAUsableSize() throws {
    let surface = KeyboardSurfaceView(frame: CGRect(x: 0, y: 0, width: 1_024, height: 260))
    surface.layoutIfNeeded()

    let q = try button("keyboard-key-q", in: surface)
    XCTAssertLessThan(q.bounds.width, 90)
    XCTAssertFalse(allSubviews(of: surface).contains(where: \.hasAmbiguousLayout))
  }

  func testTrailingAlternateCalloutStartsOnTheBaseCharacterAndStaysOnscreen() {
    let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 220))
    let key = UIView(frame: CGRect(x: 348, y: 90, width: 38, height: 44))
    let callout = KeyboardAlternateCalloutView()
    container.addSubview(key)

    let rightAnchoredOptions = ["ō", "õ", "ø", "œ", "ö", "ô", "ó", "ò", "o"]
    callout.show(
      options: rightAnchoredOptions,
      above: key,
      in: container,
      anchoredToTrailingEdge: true
    )

    XCTAssertEqual(callout.selectedText, "o")
    XCTAssertLessThanOrEqual(callout.frame.maxX, container.bounds.maxX - 4)
  }

  // MARK: Touch handling

  func testAKeyIsTypedOnReleaseNotOnTouchDown() {
    let (surface, delegate) = makeSurface()
    surface.touchDown(1, at: center("keyboard-key-q", in: surface))
    XCTAssertEqual(delegate.insertedText, [])
    surface.touchUp(1, at: center("keyboard-key-q", in: surface))
    XCTAssertEqual(delegate.insertedText, ["q"])
  }

  func testOverlappingThumbsLoseNoLetters() {
    let (surface, delegate) = makeSurface()
    // Thumb 1 is still down on "q" when thumb 2 lands on "w".
    surface.touchDown(1, at: center("keyboard-key-q", in: surface))
    surface.touchDown(2, at: center("keyboard-key-w", in: surface))
    XCTAssertEqual(delegate.insertedText, ["q"], "the second finger settles the first key at once")
    surface.touchUp(1, at: center("keyboard-key-q", in: surface))
    XCTAssertEqual(delegate.insertedText, ["q"], "released key is not typed twice")
    surface.touchDown(3, at: center("keyboard-key-e", in: surface))
    surface.touchUp(2, at: center("keyboard-key-w", in: surface))
    surface.touchUp(3, at: center("keyboard-key-e", in: surface))
    XCTAssertEqual(delegate.insertedText, ["q", "w", "e"])
  }

  func testSlidingOffAKeyTypesTheKeyUnderTheFingerOnRelease() {
    let (surface, delegate) = makeSurface()
    surface.touchDown(1, at: center("keyboard-key-q", in: surface))
    surface.touchMoved(1, to: center("keyboard-key-w", in: surface))
    surface.touchUp(1, at: center("keyboard-key-w", in: surface))
    XCTAssertEqual(delegate.insertedText, ["w"])
  }

  func testSlidingOntoAFunctionKeyTypesNothing() {
    let (surface, delegate) = makeSurface()
    surface.touchDown(1, at: center("keyboard-key-p", in: surface))
    surface.touchMoved(1, to: center("keyboard-delete-key", in: surface))
    surface.touchUp(1, at: center("keyboard-delete-key", in: surface))
    XCTAssertEqual(delegate.insertedText, [])
    XCTAssertEqual(delegate.deleteCount, 0, "a letter finger never presses delete")
  }

  func testTouchesInTheMarginsAndGapsHitTheNearestKey() throws {
    let (surface, delegate) = makeSurface()
    let q = try XCTUnwrap(surface.keyFrame(identifier: "keyboard-key-q"))
    let a = try XCTUnwrap(surface.keyFrame(identifier: "keyboard-key-a"))
    // The 6.5 pt screen margin left of "q".
    surface.touchDown(1, at: CGPoint(x: 1, y: q.midY))
    surface.touchUp(1, at: CGPoint(x: 1, y: q.midY))
    // The empty half-key left of "a" in the second row.
    surface.touchDown(1, at: CGPoint(x: 2, y: a.midY))
    surface.touchUp(1, at: CGPoint(x: 2, y: a.midY))
    // The gap between the first and second row, right above "a".
    surface.touchDown(1, at: CGPoint(x: a.midX, y: a.minY - 5))
    surface.touchUp(1, at: CGPoint(x: a.midX, y: a.minY - 5))
    XCTAssertEqual(delegate.insertedText.first, "q")
    XCTAssertEqual(delegate.insertedText.dropFirst().first, "a")
    XCTAssertEqual(delegate.insertedText.count, 3)
  }

  func testShiftRelabelsInPlaceWithoutRecreatingKeys() throws {
    let (surface, _) = makeSurface()
    let q = try button("keyboard-key-q", in: surface)
    let space = try button("keyboard-space-key", in: surface)
    tap("keyboard-shift-key", in: surface)
    XCTAssertTrue(
      try button("keyboard-key-Q", in: surface) === q, "same view, new title")
    XCTAssertTrue(try button("keyboard-space-key", in: surface) === space)
    XCTAssertEqual(surface.interactionState.capitalization, .shifted)
  }

  func testAFingerInFlightSurvivesShiftChangingTheCase() {
    let (surface, delegate) = makeSurface()
    let point = center("keyboard-key-w", in: surface)
    surface.touchDown(1, at: point)
    surface.applyAutomaticCapitalization(.shifted)
    surface.touchUp(1, at: point)
    XCTAssertEqual(delegate.insertedText, ["W"], "the touch is not lost; the new case applies")
  }

  func testPageKeyTapSwitchesAndLeavesTheSpaceBarUsable() {
    let (surface, delegate) = makeSurface()
    tap("keyboard-page-key", in: surface)
    XCTAssertEqual(surface.interactionState.page, .numbers)
    surface.layoutIfNeeded()
    tap("keyboard-space-key", in: surface)
    XCTAssertEqual(delegate.insertedText, [" "])
  }

  func testSpaceBarIsTypedOnReleaseAndNotWhenTheFingerSlidesOff() {
    let (surface, delegate) = makeSurface()
    tap("keyboard-space-key", in: surface)
    XCTAssertEqual(delegate.insertedText, [" "])
    surface.touchDown(1, at: center("keyboard-space-key", in: surface))
    surface.touchMoved(1, to: center("keyboard-key-m", in: surface))
    surface.touchUp(1, at: center("keyboard-key-m", in: surface))
    XCTAssertEqual(delegate.insertedText, [" "], "sliding off the space bar cancels it")
  }

  func testAThumbDriftingAlongTheSpaceBarStillTypesASpace() {
    let (surface, delegate) = makeSurface()
    let start = center("keyboard-space-key", in: surface)
    surface.touchDown(1, at: start)
    surface.touchMoved(1, to: CGPoint(x: start.x + 25, y: start.y + 2))
    surface.touchUp(1, at: CGPoint(x: start.x + 25, y: start.y + 2))
    XCTAssertEqual(delegate.insertedText, [" "])
    XCTAssertEqual(delegate.cursorOffsets, [])
    XCTAssertFalse(surface.isTrackpadActive)
  }

  func testOverlappingBurstWithDriftingThumbsTypesEveryCharacterInOrder() {
    let (surface, delegate) = makeSurface()
    let keys = ["q", "w", " ", "e", "r", " ", "t"].map {
      $0 == " " ? "keyboard-space-key" : "keyboard-key-\($0)"
    }
    // Each finger lands before the previous one lifts and drifts 12 pt sideways.
    var down: (id: Int, point: CGPoint)?
    for (index, key) in keys.enumerated() {
      let point = center(key, in: surface)
      surface.touchDown(index + 1, at: point)
      if let previous = down {
        let lifted = CGPoint(x: previous.point.x + 12, y: previous.point.y)
        surface.touchMoved(previous.id, to: lifted)
        surface.touchUp(previous.id, at: lifted)
      }
      down = (index + 1, point)
    }
    if let last = down { surface.touchUp(last.id, at: last.point) }
    XCTAssertEqual(delegate.insertedText.joined(), "qw er t")
  }

  func testLongPressOnSpaceStartsTheTrackpadInBothDirections() throws {
    let (surface, delegate) = makeSurface()
    let start = center("keyboard-space-key", in: surface)
    surface.touchDown(1, at: start)
    surface.fireTrackpadLongPress(touch: 1)
    XCTAssertTrue(surface.isTrackpadActive)
    surface.touchMoved(1, to: CGPoint(x: start.x - 20, y: start.y - 45))
    surface.touchUp(1, at: CGPoint(x: start.x - 20, y: start.y - 45))
    XCTAssertFalse(surface.isTrackpadActive)
    XCTAssertEqual(delegate.insertedText, [])
    XCTAssertEqual(delegate.cursorOffsets.reduce(0, +), -2)
    XCTAssertEqual(delegate.verticalMoves.reduce(0, +), -2)
  }

  func testLongPressOpensTheAccentPanelAndReleaseTypesTheSelection() throws {
    let surface = KeyboardSurfaceView(
      language: .russian, frame: CGRect(x: 0, y: 0, width: 402, height: 205))
    let delegate = DelegateSpy()
    surface.delegate = delegate
    surface.updateInputContext(kind: .standard, returnKeyType: .default, needsInputModeSwitchKey: false)
    surface.layoutIfNeeded()
    let e = center("keyboard-key-е", in: surface)
    surface.touchDown(1, at: e)
    surface.fireAlternatesLongPress(touch: 1)
    let panel = try XCTUnwrap(
      allSubviews(of: surface).compactMap { $0 as? KeyboardAlternateCalloutView }.first)
    // Second cell of the "е ё" panel.
    let target = CGPoint(x: panel.frame.minX + 10.3 + 37 * 1.5, y: panel.frame.midY)
    surface.touchMoved(1, to: target)
    surface.touchUp(1, at: target)
    XCTAssertEqual(delegate.insertedText, ["ё"])
    XCTAssertNil(panel.superview, "panel closes on release")
  }

  func testCancelledTouchTypesNothing() {
    let (surface, delegate) = makeSurface()
    surface.touchDown(1, at: center("keyboard-key-q", in: surface))
    surface.touchCancelled(1)
    XCTAssertEqual(delegate.insertedText, [])
  }

  func testDisabledKeysSwallowTouchesButTheMicrophoneStaysLive() {
    let (surface, delegate) = makeSurface()
    surface.setTypingEnabled(false)
    tap("keyboard-key-q", in: surface)
    tap("keyboard-space-key", in: surface)
    tap("keyboard-microphone-key", in: surface)
    XCTAssertEqual(delegate.insertedText, [])
    XCTAssertEqual(delegate.microphoneTaps, 1)
  }

  func testDeleteActsOnTouchDownThenAcceleratesToWordsWhileHeld() {
    let (surface, delegate) = makeSurface()
    surface.touchDown(1, at: center("keyboard-delete-key", in: surface))
    XCTAssertEqual(delegate.deleteCount, 1, "first deletion on touch-down")
    let t0 = ProcessInfo.processInfo.systemUptime
    surface.deleteTick(at: t0 + 0.42)
    surface.deleteTick(at: t0 + 0.50)
    XCTAssertEqual(delegate.deleteCount, 3)
    XCTAssertEqual(delegate.deleteWordCount, 0)
    surface.deleteTick(at: t0 + 1.3)
    XCTAssertEqual(delegate.deleteWordCount, 1, "after 1.2 s of holding, whole words go")
    surface.touchUp(1, at: center("keyboard-delete-key", in: surface))
    surface.deleteTick(at: t0 + 2)
    XCTAssertEqual(delegate.deleteWordCount, 1, "no repeats after release")
  }

  func testDigitPadHasNoLettersNoMicrophoneAndKeepsTheBottomRow() throws {
    let (surface, delegate) = makeSurface()
    surface.updateInputContext(
      kind: .numberPad, returnKeyType: .default, needsInputModeSwitchKey: false)
    surface.layoutIfNeeded()
    XCTAssertNil(findButton("keyboard-key-q", in: surface))
    XCTAssertNil(findButton("keyboard-microphone-key", in: surface))
    for digit in "0123456789" {
      XCTAssertNotNil(findButton("keyboard-key-\(digit)", in: surface), "\(digit)")
    }
    tap("keyboard-key-7", in: surface)
    tap("keyboard-delete-key", in: surface)
    XCTAssertEqual(delegate.insertedText, ["7"])
    XCTAssertEqual(delegate.deleteCount, 1)
  }

  func testDecimalPadCarriesTheSeparatorWhereTheGlobeWouldBe() {
    let (surface, _) = makeSurface()
    surface.updateInputContext(
      kind: .decimalPad, returnKeyType: .default, needsInputModeSwitchKey: true)
    surface.layoutIfNeeded()
    XCTAssertNotNil(findButton("keyboard-key-\(Locale.current.decimalSeparator ?? ".")", in: surface))
  }

  func testNumbersAndPunctuationFieldOpensOnNumbersEvenWithoutAKindChange() {
    let (surface, _) = makeSurface()
    surface.updateInputContext(
      kind: .standard, returnKeyType: .default, needsInputModeSwitchKey: false, startsOnNumbers: true)
    XCTAssertNotNil(findButton("keyboard-key-1", in: surface))
  }

  func testWebSearchKeepsTheSpaceBarWithAPeriodKey() {
    let (surface, delegate) = makeSurface()
    surface.updateInputContext(kind: .webSearch, returnKeyType: .search, needsInputModeSwitchKey: false)
    surface.layoutIfNeeded()
    XCTAssertNotNil(findButton("keyboard-space-key", in: surface))
    XCTAssertNotNil(findButton("keyboard-key-.", in: surface))
    XCTAssertNotNil(findButton("keyboard-microphone-key", in: surface))
    tap("keyboard-space-key", in: surface)
    XCTAssertEqual(delegate.insertedText, [" "])
  }

  func testReturnKeyStaysOffUntilThereIsText() {
    let (surface, delegate) = makeSurface()
    surface.setReturnKeyEnabled(false)
    tap("keyboard-return-key", in: surface)
    XCTAssertEqual(delegate.insertedText, [])
    surface.setReturnKeyEnabled(true)
    tap("keyboard-return-key", in: surface)
    XCTAssertEqual(delegate.insertedText, ["\n"])
  }

  func testFunctionKeyLabelsAreRussianOnARussianSystemAndEnglishOtherwise() {
    XCTAssertEqual(KeyboardAccessibilityStrings.forPreferredLanguages(["ru-RU", "en"]).delete, "удалить")
    XCTAssertEqual(KeyboardAccessibilityStrings.forPreferredLanguages(["en-US", "ru"]).delete, "delete")
  }

  private func makeSurface() -> (KeyboardSurfaceView, DelegateSpy) {
    let surface = KeyboardSurfaceView(frame: CGRect(x: 0, y: 0, width: 390, height: 205))
    let delegate = DelegateSpy()
    surface.delegate = delegate
    surface.updateInputContext(
      kind: .standard,
      returnKeyType: .default,
      needsInputModeSwitchKey: true
    )
    surface.layoutIfNeeded()
    return (surface, delegate)
  }

  private func button(
    _ identifier: String,
    in surface: KeyboardSurfaceView,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> KeyboardKeyButton {
    try XCTUnwrap(findButton(identifier, in: surface), file: file, line: line)
  }

  private func findButton(
    _ identifier: String,
    in surface: KeyboardSurfaceView
  ) -> KeyboardKeyButton? {
    allSubviews(of: surface)
      .compactMap { $0 as? KeyboardKeyButton }
      .first { $0.accessibilityIdentifier == identifier }
  }

  /// Center of a key in surface coordinates.
  private func center(_ identifier: String, in surface: KeyboardSurfaceView) -> CGPoint {
    let frame = surface.keyFrame(identifier: identifier) ?? .zero
    return CGPoint(x: frame.midX, y: frame.midY)
  }

  private func press(
    _ identifier: String, in surface: KeyboardSurfaceView, finger: Int, release shouldRelease: Bool
  ) {
    surface.touchDown(finger, at: center(identifier, in: surface))
    if shouldRelease { release(identifier, in: surface, finger: finger) }
  }

  private func release(_ identifier: String, in surface: KeyboardSurfaceView, finger: Int) {
    surface.touchUp(finger, at: center(identifier, in: surface))
  }

  /// A complete tap with one finger.
  private func tap(_ identifier: String, in surface: KeyboardSurfaceView) {
    press(identifier, in: surface, finger: 1, release: true)
  }

  private func allSubviews(of view: UIView) -> [UIView] {
    view.subviews + view.subviews.flatMap(allSubviews)
  }
}

@MainActor
private final class DelegateSpy: KeyboardSurfaceViewDelegate {
  var insertedText: [String] = []
  var deleteCount = 0
  var cursorOffsets: [Int] = []
  var clickCount = 0
  var microphoneTaps = 0
  var deleteWordCount = 0
  var verticalMoves: [Int] = []

  func keyboardSurface(_ surface: KeyboardSurfaceView, insertText text: String) {
    insertedText.append(text)
  }

  func keyboardSurfaceDeleteBackward(_ surface: KeyboardSurfaceView) {
    deleteCount += 1
  }

  func keyboardSurfaceDeleteWordBackward(_ surface: KeyboardSurfaceView) {
    deleteWordCount += 1
  }

  func keyboardSurface(_ surface: KeyboardSurfaceView, moveCursorVerticallyBy lines: Int) {
    verticalMoves.append(lines)
  }

  func keyboardSurface(_ surface: KeyboardSurfaceView, adjustTextPositionBy offset: Int) {
    cursorOffsets.append(offset)
  }

  func keyboardSurfacePlayInputClick(_ surface: KeyboardSurfaceView) {
    clickCount += 1
  }

  func keyboardSurfaceMicrophoneTapped(_ surface: KeyboardSurfaceView) {
    microphoneTaps += 1
  }

  func keyboardSurface(
    _ surface: KeyboardSurfaceView,
    showInputModeListFrom button: UIButton,
    event: UIEvent
  ) {}
}
