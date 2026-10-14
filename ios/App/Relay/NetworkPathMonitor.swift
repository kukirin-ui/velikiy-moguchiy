import Foundation
import Network

/// Whether the device has a usable network path right now, so a dictation can
/// warn up front instead of failing after the user has spoken for a minute.
final class NetworkPathMonitor: @unchecked Sendable {
  static let shared = NetworkPathMonitor()

  private let monitor = NWPathMonitor()
  private let lock = NSLock()
  private var satisfied = true

  private init() {
    monitor.pathUpdateHandler = { [weak self] path in
      guard let self else { return }
      lock.lock()
      satisfied = path.status == .satisfied
      lock.unlock()
    }
    monitor.start(queue: DispatchQueue(label: "VelikiyMoguchiy.network-path"))
  }

  var isOffline: Bool {
    lock.lock()
    defer { lock.unlock() }
    return !satisfied
  }
}
