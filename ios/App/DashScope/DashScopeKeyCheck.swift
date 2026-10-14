import Foundation

/// Checks a key the way a dictation uses it: opens a realtime session in the
/// chosen region and waits until DashScope has accepted its settings. A key
/// refused there is tried in the other region, because DashScope answers a
/// key from the wrong region exactly like a wrong key (HTTP 401).
struct DashScopeKeyCheck: Sendable {
  enum Outcome: Equatable {
    case works
    case worksInOtherRegion(DashScopeRegion)
    case failed(DictationFailure)

    var message: String {
      switch self {
      case .works:
        return "Ключ работает."
      case .worksInOtherRegion(let region):
        return "Ключ работает в регионе «\(region.title)»: регион переключён."
      case .failed(let failure):
        switch failure.kind {
        case .invalidKey:
          return "DashScope не принял ключ ни в одном регионе. Скопируйте ключ заново: он начинается с «sk-»."
        case .account:
          return "Ключ верный, но DashScope отказал в доступе: пополните баланс или включите модель в консоли Model Studio."
        default:
          return failure.detail
        }
      }
    }
  }

  var socketFactory: DashScopeRealtimeSession.SocketFactory = { endpoint in
    URLSessionDashScopeSocket(endpoint: endpoint)
  }

  func run(apiKey: String, region: DashScopeRegion) async -> Outcome {
    do {
      try await openSession(apiKey: apiKey, region: region)
      return .works
    } catch {
      let failure = DictationFailure(error)
      NSLog("KEY_CHECK_FAILED region=%@ code=%@", region.rawValue, failure.code)
      guard failure.kind == .invalidKey else { return .failed(failure) }
      do {
        try await openSession(apiKey: apiKey, region: region.other)
        return .worksInOtherRegion(region.other)
      } catch {
        return .failed(failure)
      }
    }
  }

  private func openSession(apiKey: String, region: DashScopeRegion) async throws {
    let session = DashScopeRealtimeSession(language: .russian, socketFactory: socketFactory)
    defer { Task { await session.cancel() } }
    try await session.connect(apiKey: apiKey, region: region)
  }
}
