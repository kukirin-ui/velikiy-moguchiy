import XCTest

@testable import VelikiyMoguchiy

final class DictationFailureTests: XCTestCase {
  func testSilenceIsNotKeptAndSaysSo() {
    let failure = DictationFailure(DashScopeSpeechError.noSpeech)
    XCTAssertEqual(failure.kind, .noSpeech)
    XCTAssertFalse(failure.keepsRecording)
    XCTAssertFalse(failure.keyboardText.contains("сохранена"))
  }

  func testAnEmptyAnswerToRealSpeechKeepsTheRecording() {
    let failure = DictationFailure(DashScopeSpeechError.emptyResult)
    XCTAssertEqual(failure.kind, .notRecognized)
    XCTAssertTrue(failure.keepsRecording)
  }

  func testHandshakeStatusesMapToTheirCause() {
    XCTAssertEqual(DictationFailure(DashScopeSpeechError.rejected(httpStatus: 401)).kind, .invalidKey)
    XCTAssertEqual(DictationFailure(DashScopeSpeechError.rejected(httpStatus: 403)).kind, .account)
    XCTAssertEqual(DictationFailure(DashScopeSpeechError.rejected(httpStatus: 429)).kind, .rateLimited)
    XCTAssertEqual(DictationFailure(DashScopeSpeechError.rejected(httpStatus: 503)).kind, .serviceDown)
    XCTAssertEqual(DictationFailure(DashScopeSpeechError.rejected(httpStatus: 401)).code, "http401")
  }

  func testProviderErrorsAreRecognisedByCodeOrText() {
    func kind(_ code: String?, _ message: String) -> DictationFailure.Kind {
      DictationFailure(DashScopeSpeechError.provider(code: code, message: message)).kind
    }
    XCTAssertEqual(kind("InvalidApiKey", "Invalid API-key provided."), .invalidKey)
    XCTAssertEqual(kind("Arrearage", "Access denied, please make sure your account is in good standing."), .account)
    XCTAssertEqual(kind(nil, "Access denied, please make sure your account is in good standing."), .account)
    XCTAssertEqual(kind("AllocationQuota.FreeTierOnly", "The free tier of the model has been exhausted."), .account)
    XCTAssertEqual(kind("Throttling.RateQuota", "Requests rate limit exceeded."), .rateLimited)
    XCTAssertEqual(kind("InternalError", "An internal error has occured."), .serviceDown)
    let unknown = DictationFailure(DashScopeSpeechError.provider(code: "InvalidParameter", message: "x"))
    XCTAssertEqual(unknown.kind, .other)
    XCTAssertTrue(unknown.keyboardText.contains("InvalidParameter"))
  }

  func testNetworkErrorsDistinguishOfflineTimeoutAndDrop() {
    XCTAssertEqual(DictationFailure(URLError(.notConnectedToInternet)).kind, .offline)
    XCTAssertEqual(DictationFailure(URLError(.cannotFindHost)).kind, .offline)
    XCTAssertEqual(DictationFailure(URLError(.timedOut)).kind, .timedOut)
    XCTAssertEqual(DictationFailure(URLError(.networkConnectionLost)).kind, .connectionLost)
    XCTAssertEqual(DictationFailure(URLError(.notConnectedToInternet)).code, "net-1009")
  }

  func testEveryTextIsRussianAndHasNoRawProviderMessage() {
    let kinds: [DictationFailure.Kind] = [
      .noSpeech, .notRecognized, .missingKey, .invalidKey, .account, .rateLimited,
      .offline, .timedOut, .connectionLost, .serviceDown, .other,
    ]
    for kind in kinds {
      let failure = DictationFailure(kind: kind, code: "x")
      XCTAssertNotNil(failure.keyboardText.range(of: "[а-яё]", options: .regularExpression))
      XCTAssertNotNil(failure.detail.range(of: "[а-яё]", options: .regularExpression))
      XCTAssertLessThanOrEqual(failure.keyboardText.count, 56, "\(kind) does not fit the keyboard row")
    }
  }
}
