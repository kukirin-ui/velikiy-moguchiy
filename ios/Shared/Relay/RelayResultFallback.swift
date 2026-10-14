import Foundation
import UIKit

/// Last-resort delivery of a finished dictation when the named pasteboard
/// cannot be read by the keyboard (for example after re-signing with a
/// different team). The text goes through the general pasteboard as a custom,
/// local-only, short-lived item, and the keyboard removes it as soon as it has
/// read it. It is only used when the keyboard did not acknowledge the result
/// received through the normal channel.
enum RelayResultFallback {
  static let pasteboardType = "velikiy-moguchiy.fallback-result"
  static let lifetime: TimeInterval = 30

  private struct Payload: Codable {
    let requestID: String
    let text: String
  }

  static func publish(
    text: String, requestID: String, pasteboard: UIPasteboard = .general
  ) {
    guard let data = try? JSONEncoder().encode(Payload(requestID: requestID, text: text)) else {
      return
    }
    pasteboard.setItems(
      [[pasteboardType: data]],
      options: [
        .localOnly: true,
        .expirationDate: Date().addingTimeInterval(lifetime),
      ]
    )
  }

  /// Returns the text for `requestID` and clears it from the pasteboard.
  /// `contains(pasteboardTypes:)` does not trigger the system paste prompt, so
  /// the data is read only when our own item is there.
  static func take(requestID: String, pasteboard: UIPasteboard = .general) -> String? {
    guard pasteboard.contains(pasteboardTypes: [pasteboardType]),
      let data = pasteboard.data(forPasteboardType: pasteboardType),
      let payload = try? JSONDecoder().decode(Payload.self, from: data),
      payload.requestID == requestID
    else { return nil }
    pasteboard.items = []
    return payload.text
  }
}
