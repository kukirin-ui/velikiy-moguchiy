import XCTest

@testable import VelikiyMoguchiy

@MainActor
final class DashScopeRegionTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!
  private var service: String!

  override func setUp() async throws {
    suiteName = "VelikiyMoguchiyRegionTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    service = "com.example.velikiy-moguchiy.tests.\(UUID().uuidString)"
  }

  override func tearDown() async throws {
    APIKeyStore(service: service).saveAPIKey("")
    defaults.removePersistentDomain(forName: suiteName)
  }

  private func makeConfiguration() -> AppConfiguration {
    AppConfiguration(
      defaults: defaults,
      credentialStore: APIKeyStore(service: service),
      relayStore: SharedRelayStore(defaults: defaults)
    )
  }

  func testNewInstallStartsInternationalAndStaysThereAfterAddingAKey() {
    let configuration = makeConfiguration()
    XCTAssertEqual(configuration.dashScopeRegion, .international)
    configuration.apiKeyOverride = "sk-new"
    XCTAssertEqual(makeConfiguration().dashScopeRegion, .international)
  }

  func testAnInstallThatAlreadyHadAKeyKeepsTheChinaEndpoint() {
    XCTAssertEqual(DashScopeRegion.resolve(stored: nil, hasExistingKey: true), .china)
    XCTAssertEqual(DashScopeRegion.resolve(stored: nil, hasExistingKey: false), .international)
    XCTAssertEqual(DashScopeRegion.resolve(stored: "intl", hasExistingKey: true), .international)
    XCTAssertEqual(DashScopeRegion.resolve(stored: "cn", hasExistingKey: false), .china)
  }

  func testTheChosenRegionPersists() {
    makeConfiguration().dashScopeRegion = .china
    XCTAssertEqual(makeConfiguration().dashScopeRegion, .china)
  }

  func testVerificationIsClearedByAnyChangeOfKeyOrRegion() {
    let configuration = makeConfiguration()
    configuration.apiKeyOverride = "sk-1"
    configuration.apply(.works)
    XCTAssertTrue(configuration.isKeyVerified)
    configuration.dashScopeRegion = .china
    XCTAssertFalse(configuration.isKeyVerified)
    configuration.apply(.works)
    configuration.apiKeyOverride = "sk-2"
    XCTAssertFalse(configuration.isKeyVerified)
  }

  func testAKeyFromTheOtherRegionSwitchesTheRegion() {
    let configuration = makeConfiguration()
    configuration.apiKeyOverride = "sk-1"
    configuration.apply(.worksInOtherRegion(.china))
    XCTAssertEqual(configuration.dashScopeRegion, .china)
    XCTAssertTrue(configuration.isKeyVerified)
  }

  func testKeyCheckFindsTheRegionTheKeyBelongsTo() async {
    let check = DashScopeKeyCheck(socketFactory: { endpoint in
      endpoint.url.host == DashScopeRegion.china.host
        ? FakeDashScopeSocket(script: .init(finalText: "x")) as any DashScopeSocket
        : RejectingDashScopeSocket(status: 401)
    })
    let fromChina = await check.run(apiKey: "sk-1", region: .china)
    XCTAssertEqual(fromChina, DashScopeKeyCheck.Outcome.works)
    let fromInternational = await check.run(apiKey: "sk-1", region: .international)
    XCTAssertEqual(fromInternational, DashScopeKeyCheck.Outcome.worksInOtherRegion(.china))
  }

  func testKeyCheckReportsAWrongKeyAndAnAccountWithoutBalance() async {
    let wrong = await DashScopeKeyCheck(socketFactory: { _ in RejectingDashScopeSocket(status: 401) })
      .run(apiKey: "sk-1", region: .international)
    XCTAssertEqual(wrong, .failed(DictationFailure(kind: .invalidKey, code: "http401")))
    let unpaid = await DashScopeKeyCheck(socketFactory: { _ in RejectingDashScopeSocket(status: 403) })
      .run(apiKey: "sk-1", region: .international)
    guard case .failed(let failure) = unpaid else { return XCTFail("\(unpaid)") }
    XCTAssertEqual(failure.kind, .account)
  }
}

/// A server that refuses the WebSocket handshake with an HTTP status.
final class RejectingDashScopeSocket: DashScopeSocket, @unchecked Sendable {
  let status: Int
  init(status: Int) { self.status = status }
  func start() async {}
  func send(text: String) async throws {}
  func receive() async throws -> Data { throw DashScopeSpeechError.rejected(httpStatus: status) }
  func close(code: URLSessionWebSocketTask.CloseCode) async {}
}
