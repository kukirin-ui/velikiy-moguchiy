import CryptoKit
import Darwin
import UIKit

extension KeyboardViewController {
  /// Darwin notifications wake the keyboard when the app writes; this timer is
  /// only the safety net. Idle: once a second. While a dictation is on the way:
  /// four times a second, which also keeps the recording clock moving.
  static let idlePollingInterval: TimeInterval = 1
  static let busyPollingInterval: TimeInterval = 0.25

  var desiredPollingInterval: TimeInterval {
    mode == .idle && !awaitsKeyboardReactivation
      ? Self.idlePollingInterval : Self.busyPollingInterval
  }

  func startPolling() {
    pollingTimer?.invalidate()
    let interval = desiredPollingInterval
    currentPollingInterval = interval
    let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.refreshFromSharedState()
      }
    }
    timer.tolerance = interval * 0.2
    RunLoop.main.add(timer, forMode: .common)
    pollingTimer = timer
  }

  func updatePollingCadenceIfNeeded() {
    guard pollingTimer != nil, desiredPollingInterval != currentPollingInterval else { return }
    startPolling()
  }

  func persistTrackedRequest() {
    guard let activeRequestID, let activeDictationAction else { return }
    let createdAt = trackedRequestCreatedAt ?? Date()
    trackedRequestCreatedAt = createdAt
    store.trackedRequest = KeyboardTrackedRequest(
      requestID: activeRequestID,
      actionRawValue: activeDictationAction.rawValue,
      createdAt: createdAt.timeIntervalSince1970,
      isCancelling: mode == .cancelling,
      documentIdentifier: activeDocumentIdentifier?.uuidString,
      contextBeforeFingerprint: contextBeforeFingerprintAtRequest,
      contextAfterFingerprint: contextAfterFingerprintAtRequest,
      awaitsKeyboardReactivation: awaitsKeyboardReactivation
    )
    // Older builds kept these in the extension's own defaults.
    removeLegacyTrackedRequestKeys()
  }

  /// Adopts the request another keyboard of ours (or an earlier process of this
  /// one) left in the shared store.
  func restoreTrackedRequest() {
    guard let request = store.trackedRequest, let action = request.action else {
      clearTrackedRequest()
      return
    }

    activeRequestID = request.requestID
    activeDictationAction = action
    trackedRequestCreatedAt = Date(timeIntervalSince1970: request.createdAt)
    activeDocumentIdentifier = request.documentIdentifier.flatMap(UUID.init(uuidString:))
    contextBeforeFingerprintAtRequest = request.contextBeforeFingerprint
    contextAfterFingerprintAtRequest = request.contextAfterFingerprint
    awaitsKeyboardReactivation = request.awaitsKeyboardReactivation
    keyboardReactivationIsReady = false
    removeLegacyTrackedRequestKeys()
    mode = request.isCancelling ? .cancelling : .openingHost
  }

  func clearTrackedRequest() {
    if hostResolutionPendingForRequestID == activeRequestID {
      hostResolutionGeneration += 1
      hostResolutionPendingForRequestID = nil
    }
    if hostLaunchAttemptedForRequestID == activeRequestID {
      hostLaunchAttemptedForRequestID = nil
    }
    activeRequestID = nil
    activeDictationAction = nil
    trackedRequestCreatedAt = nil
    activeDocumentIdentifier = nil
    contextBeforeFingerprintAtRequest = nil
    contextAfterFingerprintAtRequest = nil
    awaitsKeyboardReactivation = false
    keyboardReactivationIsReady = false
    store.trackedRequest = nil
    removeLegacyTrackedRequestKeys()
  }

  private func removeLegacyTrackedRequestKeys() {
    let defaults = UserDefaults.standard
    [
      LocalKey.activeRequestID,
      LocalKey.activeRequestAction,
      LocalKey.activeRequestCreatedAt,
      LocalKey.activeRequestIsCancelling,
      LocalKey.activeDocumentIdentifier,
      LocalKey.contextBeforeFingerprint,
      LocalKey.contextAfterFingerprint,
      LocalKey.awaitsKeyboardReactivation,
      LocalKey.legacyContextBefore,
      LocalKey.legacyContextAfter,
    ].forEach(defaults.removeObject(forKey:))
  }
}
