import CoreGraphics
import Foundation

/// Space-bar trackpad: converts finger movement into cursor steps.
struct TrackpadCursor: Equatable {
  /// Points of finger travel per character.
  static let horizontalStep: CGFloat = 10
  /// Points of finger travel per line.
  static let verticalStep: CGFloat = 20

  private(set) var anchor: CGPoint
  private var consumedX = 0
  private var consumedY = 0

  init(anchor: CGPoint) {
    self.anchor = anchor
  }

  /// Steps the cursor must take for a finger now at `point`:
  /// `characters` (+ right) and `lines` (+ down) since the previous call.
  mutating func steps(to point: CGPoint) -> (characters: Int, lines: Int) {
    let x = Int(((point.x - anchor.x) / Self.horizontalStep).rounded(.towardZero))
    let y = Int(((point.y - anchor.y) / Self.verticalStep).rounded(.towardZero))
    let result = (characters: x - consumedX, lines: y - consumedY)
    consumedX = x
    consumedY = y
    return result
  }

  /// Offset for `adjustTextPosition(byCharacterOffset:)` that moves the cursor
  /// one line up (`direction < 0`) or down (`> 0`) while keeping its column as
  /// far as the neighbouring line allows. Lines are the host's paragraphs (split
  /// at newlines): soft-wrapped lines are invisible to a keyboard extension, so
  /// this is an approximation.
  static func verticalOffset(
    contextBefore: String?,
    contextAfter: String?,
    direction: Int
  ) -> Int {
    let before = contextBefore ?? ""
    let after = contextAfter ?? ""
    if direction < 0 {
      guard let lastNewline = before.lastIndex(where: \.isNewline) else {
        // First line: go to its start.
        return -before.count
      }
      let currentPrefix = before[before.index(after: lastNewline)...]
      let column = currentPrefix.count
      let head = before[..<lastNewline]
      let previousLineLength: Int
      if let previousNewline = head.lastIndex(where: \.isNewline) {
        previousLineLength = head[head.index(after: previousNewline)...].count
      } else {
        previousLineLength = head.count
      }
      let target = min(column, previousLineLength)
      return -(column + 1 + (previousLineLength - target))
    } else {
      guard let firstNewline = after.firstIndex(where: \.isNewline) else {
        // Last line: go to its end.
        return after.count
      }
      let restOfLine = after[..<firstNewline].count
      let column = columnOf(before)
      let tail = after[after.index(after: firstNewline)...]
      let nextLineLength = tail.firstIndex(where: \.isNewline).map { tail[..<$0].count } ?? tail.count
      return restOfLine + 1 + min(column, nextLineLength)
    }
  }

  private static func columnOf(_ before: String) -> Int {
    guard let lastNewline = before.lastIndex(where: \.isNewline) else { return before.count }
    return before[before.index(after: lastNewline)...].count
  }
}
