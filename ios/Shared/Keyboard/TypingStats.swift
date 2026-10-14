import Foundation

/// One key press as the keyboard saw it. Times are milliseconds measured from
/// the touch's own hardware timestamp, so they include any delay iOS adds
/// before the keyboard gets the touch.
struct TypingSample: Equatable {
  /// Touch-down → the keyboard's code received the touch.
  var deliveryMs: Double
  /// Touch-down → the key's text (or action) was handed to the field.
  /// `nil`: the press produced nothing.
  var pressToOutputMs: Double?
  /// Finger lifted → output. `nil` when nothing came out, or when another
  /// finger landing settled the key before this one lifted.
  var releaseToOutputMs: Double?
  /// Another finger was still down when this one landed.
  var overlapped: Bool
  /// Seconds since 1970, to drop samples older than a reset.
  var recordedAt: TimeInterval

  var producedOutput: Bool { pressToOutputMs != nil }
}

/// The most recent presses of one keyboard, stored where the app can read them.
struct TypingStats: Equatable {
  static let capacity = 200

  private(set) var samples: [TypingSample] = []

  mutating func append(_ sample: TypingSample) {
    samples.append(sample)
    if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
  }

  func since(_ date: TimeInterval) -> TypingStats {
    var stats = TypingStats()
    stats.samples = samples.filter { $0.recordedAt >= date }
    return stats
  }

  // MARK: Storage (a flat plist array: works over App Group and pasteboards)

  private static let fieldsPerSample = 5

  var encoded: [Double] {
    samples.flatMap {
      [
        $0.deliveryMs, $0.pressToOutputMs ?? -1, $0.releaseToOutputMs ?? -1,
        $0.overlapped ? 1 : 0, $0.recordedAt,
      ]
    }
  }

  init() {}

  init(encoded values: [Double]) {
    let n = Self.fieldsPerSample
    for start in stride(from: 0, to: values.count - n + 1, by: n) {
      let v = values[start..<start + n].map { $0 }
      append(
        TypingSample(
          deliveryMs: v[0], pressToOutputMs: v[1] < 0 ? nil : v[1],
          releaseToOutputMs: v[2] < 0 ? nil : v[2], overlapped: v[3] == 1, recordedAt: v[4]))
    }
  }

  // MARK: Summary

  struct Spread: Equatable {
    var median: Double
    var p95: Double
  }

  struct Summary: Equatable {
    var presses: Int
    var withoutOutput: Int
    var overlapped: Int
    var delivery: Spread?
    var pressToOutput: Spread?
    var releaseToOutput: Spread?
  }

  var summary: Summary {
    Summary(
      presses: samples.count,
      withoutOutput: samples.filter { !$0.producedOutput }.count,
      overlapped: samples.filter(\.overlapped).count,
      delivery: Self.spread(samples.map(\.deliveryMs)),
      pressToOutput: Self.spread(samples.compactMap(\.pressToOutputMs)),
      releaseToOutput: Self.spread(samples.compactMap(\.releaseToOutputMs))
    )
  }

  /// Nearest-rank percentiles.
  static func spread(_ values: [Double]) -> Spread? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    func rank(_ p: Double) -> Double {
      sorted[min(sorted.count - 1, max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1))]
    }
    return Spread(median: rank(0.5), p95: rank(0.95))
  }
}
