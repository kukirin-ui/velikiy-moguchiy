import Foundation

enum DashScopeTimeoutError: Error {
  case elapsed
}

final class DashScopeTimeoutGate<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, Error>?
  private var pendingResult: Result<Value, Error>?
  private var tasks: [Task<Void, Never>] = []
  private var isResolved = false

  func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
    lock.lock()
    if let pendingResult {
      lock.unlock()
      continuation.resume(with: pendingResult)
      return false
    }
    guard !isResolved else {
      lock.unlock()
      continuation.resume(throwing: CancellationError())
      return false
    }
    self.continuation = continuation
    lock.unlock()
    return true
  }

  func register(_ tasks: [Task<Void, Never>]) {
    lock.lock()
    if isResolved {
      lock.unlock()
      for task in tasks {
        task.cancel()
      }
      return
    }
    self.tasks = tasks
    lock.unlock()
  }

  func resolve(_ result: Result<Value, Error>) {
    lock.lock()
    guard !isResolved else {
      lock.unlock()
      return
    }
    isResolved = true
    let continuation = self.continuation
    self.continuation = nil
    if continuation == nil {
      pendingResult = result
    }
    let tasks = self.tasks
    self.tasks.removeAll()
    lock.unlock()

    for task in tasks {
      task.cancel()
    }
    continuation?.resume(with: result)
  }
}

func dashScopeWithTimeout<Value: Sendable>(
  nanoseconds: UInt64,
  operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
  let gate = DashScopeTimeoutGate<Value>()
  return try await withTaskCancellationHandler {
    try await withCheckedThrowingContinuation { continuation in
      guard gate.install(continuation) else { return }
      let operationTask = Task {
        do {
          gate.resolve(.success(try await operation()))
        } catch {
          gate.resolve(.failure(error))
        }
      }
      let timeoutTask = Task {
        do {
          try await Task.sleep(nanoseconds: nanoseconds)
        } catch {
          return
        }
        gate.resolve(.failure(DashScopeTimeoutError.elapsed))
      }
      gate.register([operationTask, timeoutTask])
    }
  } onCancel: {
    gate.resolve(.failure(CancellationError()))
  }
}
