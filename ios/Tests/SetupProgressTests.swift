import XCTest

@testable import VelikiyMoguchiy

final class SetupProgressTests: XCTestCase {
  private func progress(
    hasKey: Bool = true, microphone: SetupProgress.Microphone = .granted,
    addedKeyboards: Int? = 2, keyboardReported: Bool = true
  ) -> SetupProgress {
    SetupProgress(
      hasKey: hasKey, keyVerified: false, microphone: microphone,
      addedKeyboards: addedKeyboards, totalKeyboards: 2, keyboardReported: keyboardReported)
  }

  func testANewInstallHasNothingDone() {
    let fresh = progress(
      hasKey: false, microphone: .undetermined, addedKeyboards: 0, keyboardReported: false)
    XCTAssertEqual(fresh.completedSteps, 0)
    XCTAssertFalse(fresh.isComplete)
  }

  func testAKeyboardThatReportedInProvesItWasAddedWithFullAccess() {
    let reported = progress(addedKeyboards: nil, keyboardReported: true)
    XCTAssertTrue(reported.keyboardAdded)
    XCTAssertTrue(reported.fullAccess)
    XCTAssertTrue(reported.isComplete)
  }

  func testAnAddedKeyboardWithoutFullAccessIsHalfWay() {
    let added = progress(addedKeyboards: 1, keyboardReported: false)
    XCTAssertTrue(added.keyboardAdded)
    XCTAssertFalse(added.fullAccess)
    XCTAssertEqual(added.completedSteps, 3)
  }

  func testAnUnverifiedKeyStillCountsAndADeniedMicrophoneDoesNot() {
    XCTAssertEqual(progress(microphone: .denied).completedSteps, 3)
    XCTAssertTrue(progress().hasKey)
  }
}
