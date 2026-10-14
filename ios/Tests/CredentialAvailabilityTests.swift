import XCTest

@testable import VelikiyMoguchiy

final class CredentialAvailabilityTests: XCTestCase {
  func testRejectsMissingAndPlaceholderCredentials() {
    XCTAssertFalse(CredentialAvailability.isUsable(""))
    XCTAssertFalse(CredentialAvailability.isUsable("   \n"))
    XCTAssertFalse(CredentialAvailability.isUsable("YOUR_DASHSCOPE_API_KEY"))
  }

  func testAcceptsConfiguredCredentialAfterTrimmingWhitespace() {
    XCTAssertTrue(
      CredentialAvailability.isUsable("  test-configured-key  ")
    )
  }
}
