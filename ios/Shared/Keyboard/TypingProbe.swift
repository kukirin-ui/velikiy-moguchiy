import Foundation

/// Turns raw touches and key outputs into `TypingSample`s. Outputs are matched
/// to the oldest touch that has not produced anything yet, which also covers
/// rollover (the next finger settles the previous key before it lifts).
/// Times are seconds on the touch clock (`UITouch.timestamp`, system uptime).
struct TypingProbe {
  /// A lifted finger that produced nothing for this long counts as a lost tap
  /// (or a key that does nothing, like a disabled one).
  static let quietAfterRelease: TimeInterval = 0.6

  private struct Press {
    let touch: Int
    let down: TimeInterval
    let received: TimeInterval
    let overlapped: Bool
    var up: TimeInterval?
    var output: TimeInterval?
    var cancelled = false
  }

  private var presses: [Press] = []

  mutating func touchBegan(_ touch: Int, at down: TimeInterval, receivedAt now: TimeInterval) {
    let overlapped = presses.contains { $0.up == nil && !$0.cancelled }
    presses.append(Press(touch: touch, down: down, received: now, overlapped: overlapped))
  }

  mutating func touchEnded(_ touch: Int, at up: TimeInterval) {
    guard let index = presses.lastIndex(where: { $0.touch == touch && $0.up == nil }) else { return }
    presses[index].up = up
  }

  /// The system took the touch away (a gesture, the keyboard hiding): not the user's tap.
  mutating func touchCancelled(_ touch: Int) {
    presses.removeAll { $0.touch == touch && $0.up == nil }
  }

  mutating func noteOutput(at now: TimeInterval) {
    guard let index = presses.firstIndex(where: { $0.output == nil && !$0.cancelled }) else { return }
    presses[index].output = now
  }

  /// Samples for presses that are settled by `now`, oldest first.
  mutating func takeSettled(now: TimeInterval, wallClock: TimeInterval) -> [TypingSample] {
    var settled: [TypingSample] = []
    while let first = presses.first {
      guard let up = first.up else { break }
      if first.output == nil, now - up < Self.quietAfterRelease { break }
      presses.removeFirst()
      let ms = { (seconds: TimeInterval) in (seconds * 1000 * 10).rounded() / 10 }
      settled.append(
        TypingSample(
          deliveryMs: ms(first.received - first.down),
          pressToOutputMs: first.output.map { ms($0 - first.down) },
          releaseToOutputMs: first.output.flatMap { $0 >= up ? ms($0 - up) : nil },
          overlapped: first.overlapped,
          recordedAt: wallClock
        ))
    }
    return settled
  }

  mutating func reset() {
    presses.removeAll()
  }
}
