import XCTest

@testable import VelikiyMoguchiy

final class RelayIdleShutdownPolicyTests: XCTestCase {
  func testIdleRelayMayStop() {
    XCTAssertTrue(
      RelayIdleShutdownPolicy.canStop(
        relayIsRunning: true,
        operationIsBusy: false,
        hasPendingHandoff: false,
        hasPendingCommand: false
      )
    )
  }

  func testBusyOperationAndPendingHandoffSuspendShutdown() {
    XCTAssertFalse(
      RelayIdleShutdownPolicy.canStop(
        relayIsRunning: true,
        operationIsBusy: true,
        hasPendingHandoff: false,
        hasPendingCommand: false
      )
    )
    XCTAssertFalse(
      RelayIdleShutdownPolicy.canStop(
        relayIsRunning: true,
        operationIsBusy: false,
        hasPendingHandoff: true,
        hasPendingCommand: false
      )
    )
    XCTAssertFalse(
      RelayIdleShutdownPolicy.canStop(
        relayIsRunning: true,
        operationIsBusy: false,
        hasPendingHandoff: false,
        hasPendingCommand: true
      )
    )
  }

  func testStoppedRelayNeverSchedulesAnotherDeadline() {
    XCTAssertFalse(
      RelayIdleShutdownPolicy.canStop(
        relayIsRunning: false,
        operationIsBusy: false,
        hasPendingHandoff: false,
        hasPendingCommand: false
      )
    )
  }
}
