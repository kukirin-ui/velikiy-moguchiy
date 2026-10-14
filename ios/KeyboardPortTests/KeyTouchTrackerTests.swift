import CoreGraphics
import XCTest

final class KeyTouchTrackerTests: XCTestCase {
  /// Two rows of three keys: q w e / a s d, 40 x 40 with 6 pt gaps.
  private func makeTracker(
    disabled: Set<KeyID> = [], alternates: Set<KeyID> = []
  ) -> KeyTouchTracker {
    var tracker = KeyTouchTracker()
    var targets: [KeyTarget] = []
    for row in 0..<2 {
      for column in 0..<3 {
        let id = KeyID(row: row, column: column)
        targets.append(
          KeyTarget(
            id: id,
            frame: CGRect(x: CGFloat(column) * 46, y: CGFloat(row) * 46, width: 40, height: 40),
            kind: .character, isEnabled: !disabled.contains(id),
            hasAlternates: alternates.contains(id)))
      }
    }
    // Bottom row: space, delete, shift.
    targets.append(
      KeyTarget(id: KeyID(row: 2, column: 0), frame: CGRect(x: 0, y: 92, width: 86, height: 40), kind: .space))
    targets.append(
      KeyTarget(id: KeyID(row: 2, column: 1), frame: CGRect(x: 92, y: 92, width: 40, height: 40), kind: .delete))
    targets.append(
      KeyTarget(id: KeyID(row: 3, column: 0), frame: CGRect(x: 0, y: 138, width: 40, height: 40), kind: .function))
    tracker.targets = targets
    return tracker
  }

  private func center(_ row: Int, _ column: Int) -> CGPoint {
    switch (row, column) {
    case (2, 0): return CGPoint(x: 43, y: 112)
    case (2, 1): return CGPoint(x: 112, y: 112)
    case (3, 0): return CGPoint(x: 20, y: 158)
    default: return CGPoint(x: CGFloat(column) * 46 + 20, y: CGFloat(row) * 46 + 20)
    }
  }

  private let q = KeyID(row: 0, column: 0)
  private let w = KeyID(row: 0, column: 1)
  private let e = KeyID(row: 0, column: 2)
  private let a = KeyID(row: 1, column: 0)
  private let space = KeyID(row: 2, column: 0)
  private let delete = KeyID(row: 2, column: 1)
  private let shift = KeyID(row: 3, column: 0)

  // MARK: Hit testing

  func testNearestKeyContainingThePointWins() {
    XCTAssertEqual(KeyHitTester.nearestKey(to: center(0, 1), in: makeTracker().targets)?.id, w)
  }

  func testGapsAndMarginsBelongToTheNearestKey() {
    let targets = makeTracker().targets
    XCTAssertEqual(KeyHitTester.nearestKey(to: CGPoint(x: 43, y: 20), in: targets)?.id, q, "gap, nearer to q")
    XCTAssertEqual(KeyHitTester.nearestKey(to: CGPoint(x: 44, y: 20), in: targets)?.id, w, "gap, nearer to w")
    XCTAssertEqual(KeyHitTester.nearestKey(to: CGPoint(x: -3, y: 20), in: targets)?.id, q, "left margin")
    XCTAssertEqual(KeyHitTester.nearestKey(to: CGPoint(x: 20, y: 43), in: targets)?.id, q, "row gap, above")
    XCTAssertEqual(KeyHitTester.nearestKey(to: CGPoint(x: 20, y: 44), in: targets)?.id, a, "row gap, below")
  }

  func testTouchFarOutsideTheKeyboardHitsNothing() {
    let targets = makeTracker().targets
    XCTAssertNil(KeyHitTester.nearestKey(to: CGPoint(x: 20, y: -80), in: targets))
    XCTAssertNil(KeyHitTester.nearestKey(to: CGPoint(x: 600, y: 20), in: targets))
    XCTAssertNotNil(KeyHitTester.nearestKey(to: CGPoint(x: 20, y: -30), in: targets), "a thumb a bit above still counts")
  }

  // MARK: Plain taps

  func testTapCommitsOnReleaseNotOnPress() {
    var tracker = makeTracker()
    XCTAssertEqual(tracker.began(touch: 1, at: center(0, 0)), [.pressed(touch: 1, key: q)])
    XCTAssertEqual(tracker.ended(touch: 1, at: center(0, 0)), [.commit(touch: 1, key: q)])
    XCTAssertEqual(tracker.activeTouchCount, 0)
  }

  func testReleaseCommitsTheKeyUnderTheFingerNotTheOneItLandedOn() {
    var tracker = makeTracker()
    _ = tracker.began(touch: 1, at: center(0, 0))
    XCTAssertEqual(tracker.moved(touch: 1, to: center(0, 1)), [.slid(touch: 1, from: q, to: w)])
    XCTAssertEqual(tracker.ended(touch: 1, at: center(0, 1)), [.commit(touch: 1, key: w)])
  }

  func testSlidingBackToTheOriginalKeyCommitsIt() {
    var tracker = makeTracker()
    _ = tracker.began(touch: 1, at: center(0, 0))
    _ = tracker.moved(touch: 1, to: center(0, 1))
    _ = tracker.moved(touch: 1, to: center(0, 0))
    XCTAssertEqual(tracker.ended(touch: 1, at: center(0, 0)), [.commit(touch: 1, key: q)])
  }

  func testReleasingFarOutsideTheKeyboardTypesNothing() {
    var tracker = makeTracker()
    _ = tracker.began(touch: 1, at: center(0, 0))
    _ = tracker.moved(touch: 1, to: CGPoint(x: 20, y: -200))
    XCTAssertEqual(tracker.ended(touch: 1, at: CGPoint(x: 20, y: -200)), [.released(touch: 1, key: q)])
  }

  // MARK: Several fingers

  func testASecondFingerCommitsTheFirstKeyAtOnce() {
    var tracker = makeTracker()
    _ = tracker.began(touch: 1, at: center(0, 0))
    let second = tracker.began(touch: 2, at: center(0, 1))
    XCTAssertEqual(second, [.commit(touch: 1, key: q), .pressed(touch: 2, key: w)])
    // The committed finger's release adds nothing, the other still types on release.
    XCTAssertEqual(tracker.ended(touch: 1, at: center(0, 0)), [.released(touch: 1, key: q)])
    XCTAssertEqual(tracker.ended(touch: 2, at: center(0, 1)), [.commit(touch: 2, key: w)])
  }

  func testThreeFingersTypeInTheOrderTheyLanded() {
    var tracker = makeTracker()
    var typed: [KeyID] = []
    func collect(_ outputs: [KeyTouchOutput]) {
      for case .commit(_, let key) in outputs { typed.append(key) }
    }
    collect(tracker.began(touch: 1, at: center(0, 0)))
    collect(tracker.began(touch: 2, at: center(0, 1)))
    collect(tracker.began(touch: 3, at: center(0, 2)))
    collect(tracker.ended(touch: 3, at: center(0, 2)))
    collect(tracker.ended(touch: 1, at: center(0, 0)))
    collect(tracker.ended(touch: 2, at: center(0, 1)))
    XCTAssertEqual(typed, [q, w, e])
  }

  func testFingersAreIndependentWhenOneSlides() {
    var tracker = makeTracker()
    _ = tracker.began(touch: 1, at: center(0, 0))
    _ = tracker.began(touch: 2, at: center(1, 0))  // commits q
    _ = tracker.moved(touch: 2, to: center(0, 2))
    XCTAssertEqual(tracker.ended(touch: 2, at: center(0, 2)), [.commit(touch: 2, key: e)])
  }

  func testAFingerHoldingShiftDoesNotCommitWhenAnotherLands() {
    var tracker = makeTracker()
    _ = tracker.began(touch: 1, at: center(3, 0))  // shift (function key)
    let second = tracker.began(touch: 2, at: center(0, 0))
    XCTAssertEqual(second, [.pressed(touch: 2, key: q)])
    XCTAssertEqual(tracker.ended(touch: 1, at: center(3, 0)), [.commit(touch: 1, key: shift)])
  }

  // MARK: Function keys, delete, space

  func testFunctionKeyCommitsOnlyWhenReleasedOverItself() {
    var tracker = makeTracker()
    _ = tracker.began(touch: 1, at: center(3, 0))
    XCTAssertEqual(tracker.ended(touch: 1, at: center(3, 0)), [.commit(touch: 1, key: shift)])
    _ = tracker.began(touch: 1, at: center(3, 0))
    _ = tracker.moved(touch: 1, to: center(0, 0))
    XCTAssertEqual(tracker.ended(touch: 1, at: center(0, 0)), [.released(touch: 1, key: shift)])
  }

  func testDeleteActsOnPressAndStopsOnRelease() {
    var tracker = makeTracker()
    XCTAssertEqual(
      tracker.began(touch: 1, at: center(2, 1)),
      [.pressed(touch: 1, key: delete), .deleteBegan(touch: 1)])
    XCTAssertEqual(
      tracker.ended(touch: 1, at: center(2, 1)),
      [.released(touch: 1, key: delete), .deleteEnded(touch: 1)])
  }

  func testDeleteIsNotInterruptedByAnotherFingerTyping() {
    var tracker = makeTracker()
    _ = tracker.began(touch: 1, at: center(2, 1))
    let second = tracker.began(touch: 2, at: center(0, 0))
    XCTAssertEqual(second, [.pressed(touch: 2, key: q)])
    XCTAssertEqual(
      tracker.ended(touch: 1, at: center(2, 1)),
      [.released(touch: 1, key: delete), .deleteEnded(touch: 1)])
  }

  func testDisabledKeySwallowsTheTouch() {
    var tracker = makeTracker(disabled: [q])
    XCTAssertEqual(tracker.began(touch: 1, at: center(0, 0)), [])
    XCTAssertEqual(tracker.ended(touch: 1, at: center(0, 0)), [.released(touch: 1, key: q)])
  }

  func testSpaceCommitsOnReleaseEvenAfterSlidingAlongIt() {
    var tracker = makeTracker()
    _ = tracker.began(touch: 1, at: center(2, 0))
    XCTAssertEqual(tracker.ended(touch: 1, at: center(2, 0)), [.commit(touch: 1, key: space)])

    // Apple's keyboard still types the space after a 25 pt slide; only a long
    // press turns the space bar into a trackpad.
    _ = tracker.began(touch: 1, at: center(2, 0))
    XCTAssertEqual(tracker.moved(touch: 1, to: CGPoint(x: 43 + 25, y: 112)), [])
    XCTAssertEqual(tracker.mode(ofTouch: 1), .normal)
    XCTAssertEqual(tracker.ended(touch: 1, at: CGPoint(x: 68, y: 112)), [.commit(touch: 1, key: space)])
  }

  func testSmallWobbleOnTheSpaceBarStillTypesASpace() {
    var tracker = makeTracker()
    _ = tracker.began(touch: 1, at: center(2, 0))
    XCTAssertEqual(tracker.moved(touch: 1, to: CGPoint(x: 43 + 5, y: 112)), [])
    XCTAssertEqual(tracker.ended(touch: 1, at: CGPoint(x: 48, y: 112)), [.commit(touch: 1, key: space)])
  }

  func testLongPressOnSpaceStartsTheTrackpadWithHiddenLabels() {
    var tracker = makeTracker()
    _ = tracker.began(touch: 1, at: center(2, 0))
    XCTAssertEqual(
      tracker.beginTrackpad(touch: 1),
      [.released(touch: 1, key: space), .trackpadBegan(touch: 1)])
    XCTAssertEqual(tracker.mode(ofTouch: 1), .trackpad)
    XCTAssertEqual(tracker.ended(touch: 1, at: center(2, 0)), [.trackpadEnded(touch: 1)])
  }

  // MARK: Accent panel

  func testLongPressOnALetterWithAlternatesOpensThePanelAndReleaseEndsIt() {
    var tracker = makeTracker(alternates: [w])
    _ = tracker.began(touch: 1, at: center(0, 1))
    XCTAssertEqual(tracker.beginAlternates(touch: 1), [.alternatesBegan(touch: 1, key: w)])
    XCTAssertEqual(
      tracker.moved(touch: 1, to: CGPoint(x: 70, y: -40)),
      [.alternatesMoved(touch: 1, point: CGPoint(x: 70, y: -40))])
    XCTAssertEqual(
      tracker.ended(touch: 1, at: CGPoint(x: 70, y: -40)),
      [.alternatesEnded(touch: 1, point: CGPoint(x: 70, y: -40))])
  }

  func testNoPanelForAKeyWithoutAlternatesOrAfterTheFingerLeft() {
    var tracker = makeTracker(alternates: [w])
    _ = tracker.began(touch: 1, at: center(0, 0))
    XCTAssertEqual(tracker.beginAlternates(touch: 1), [])
    _ = tracker.began(touch: 2, at: center(0, 1))
    _ = tracker.moved(touch: 2, to: center(0, 2))
    XCTAssertEqual(tracker.beginAlternates(touch: 2), [], "the finger already left the key")
  }

  func testPanelCancelTypesNothing() {
    var tracker = makeTracker(alternates: [w])
    _ = tracker.began(touch: 1, at: center(0, 1))
    _ = tracker.beginAlternates(touch: 1)
    XCTAssertEqual(tracker.cancelled(touch: 1), [.alternatesCancelled(touch: 1)])
  }

  func testCancelReleasesWithoutCommitting() {
    var tracker = makeTracker()
    _ = tracker.began(touch: 1, at: center(0, 0))
    XCTAssertEqual(tracker.cancelled(touch: 1), [.released(touch: 1, key: q)])
    XCTAssertEqual(tracker.activeTouchCount, 0)
  }
}
