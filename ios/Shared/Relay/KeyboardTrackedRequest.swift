import Foundation

/// The dictation a keyboard is waiting for. It lives in the shared relay store,
/// not in each extension's own defaults, so that switching Великий & Могучий RU <-> EN with
/// the globe while a dictation runs does not lose the result: the other
/// keyboard's process picks the request up and inserts the text.
struct KeyboardTrackedRequest: Codable, Equatable {
  /// Longest a request is trusted after it was created.
  static let maximumAge: TimeInterval = 10 * 60

  var requestID: String
  var actionRawValue: String
  var createdAt: TimeInterval
  var isCancelling: Bool
  var documentIdentifier: String?
  var contextBeforeFingerprint: String?
  var contextAfterFingerprint: String?
  var awaitsKeyboardReactivation: Bool

  var action: RelayDictationAction? { RelayDictationAction(rawValue: actionRawValue) }

  func isFresh(at now: Date = Date()) -> Bool {
    let age = now.timeIntervalSince1970 - createdAt
    return createdAt > 0 && age >= -5 && age < Self.maximumAge && !requestID.isEmpty
      && action != nil
  }
}
