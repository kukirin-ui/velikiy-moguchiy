import UIKit
import XCTest

final class KeyFeedbackPolicyTests: XCTestCase {
  func testVibratesOnlyWithFullAccessAndTheToggleOn() {
    for (access, toggle, expected) in [
      (true, true, true), (true, false, false), (false, true, false), (false, false, false),
    ] {
      let policy = KeyFeedbackPolicy(
        hasFullAccess: access, hapticsEnabled: toggle, clickSoundEnabled: true)
      XCTAssertEqual(policy.shouldVibrate, expected, "access=\(access) toggle=\(toggle)")
    }
  }

  func testClickFollowsOnlyItsOwnToggle() {
    let noAccess = KeyFeedbackPolicy(
      hasFullAccess: false, hapticsEnabled: true, clickSoundEnabled: true)
    XCTAssertTrue(noAccess.shouldPlayClick, "clicks do not need Full Access")
    XCTAssertFalse(
      KeyFeedbackPolicy(hasFullAccess: true, hapticsEnabled: true, clickSoundEnabled: false)
        .shouldPlayClick)
  }

  func testInitialPolicyIsSilentForHapticsUntilAccessIsKnown() {
    XCTAssertFalse(KeyFeedbackPolicy.initial.shouldVibrate)
    XCTAssertTrue(KeyFeedbackPolicy.initial.shouldPlayClick)
  }

  func testStoredValueDefaultsToOn() {
    XCTAssertTrue(KeyFeedbackSettings.isEnabled(nil))
    XCTAssertFalse(KeyFeedbackSettings.isEnabled(NSNumber(value: false)))
  }
}
