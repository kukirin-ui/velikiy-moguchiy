import Foundation

/// The small socket abstraction used by production code and by tests, so the
/// protocol can be exercised without a network.
protocol DashScopeSocket: Sendable {
  func start() async
  func send(text: String) async throws
  func receive() async throws -> Data
  func close(code: URLSessionWebSocketTask.CloseCode) async
}

final class URLSessionDashScopeSocket: DashScopeSocket, @unchecked Sendable {
  private let task: URLSessionWebSocketTask

  init(endpoint: DashScopeEndpoint, session: URLSession = .shared) {
    var request = URLRequest(url: endpoint.url)
    // Governs WebSocket inactivity on current URLSession implementations. Keep
    // it above the five-minute dictation ceiling; setup and individual sends
    // have their own shorter bounded waits.
    request.timeoutInterval = 6 * 60
    for (field, value) in endpoint.headers {
      request.setValue(value, forHTTPHeaderField: field)
    }
    task = session.webSocketTask(with: request)
  }

  func start() async {
    task.resume()
  }

  func send(text: String) async throws {
    try await task.send(.string(text))
  }

  func receive() async throws -> Data {
    let message = try await task.receive()
    switch message {
    case .string(let text):
      return Data(text.utf8)
    case .data(let data):
      return data
    @unknown default:
      throw DashScopeSpeechError.invalidMessage
    }
  }

  func close(code: URLSessionWebSocketTask.CloseCode) async {
    task.cancel(with: code, reason: nil)
  }
}
