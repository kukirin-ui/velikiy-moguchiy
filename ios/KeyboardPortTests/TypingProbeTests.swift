import XCTest

final class TypingProbeTests: XCTestCase {
  func testSingleTapTimings() {
    var probe = TypingProbe()
    probe.touchBegan(1, at: 10.000, receivedAt: 10.010)
    probe.touchEnded(1, at: 10.080)
    probe.noteOutput(at: 10.082)
    let samples = probe.takeSettled(now: 10.1, wallClock: 5)
    XCTAssertEqual(samples.count, 1)
    XCTAssertEqual(samples[0].deliveryMs, 10, accuracy: 0.01)
    XCTAssertEqual(samples[0].releaseToOutputMs ?? -1, 2, accuracy: 0.01)
    XCTAssertEqual(samples[0].pressToOutputMs ?? -1, 82, accuracy: 0.01)
    XCTAssertFalse(samples[0].overlapped)
  }

  func testRolloverSettlesTheFirstKeyBeforeItLifts() {
    var probe = TypingProbe()
    probe.touchBegan(1, at: 0, receivedAt: 0.01)
    probe.touchBegan(2, at: 0.05, receivedAt: 0.06)
    probe.noteOutput(at: 0.061)
    probe.touchEnded(1, at: 0.1)
    probe.touchEnded(2, at: 0.15)
    probe.noteOutput(at: 0.152)
    let samples = probe.takeSettled(now: 0.2, wallClock: 0)
    XCTAssertEqual(samples.count, 2)
    XCTAssertNil(samples[0].releaseToOutputMs, "settled by the next finger, not by lifting")
    XCTAssertEqual(samples[0].pressToOutputMs ?? -1, 61, accuracy: 0.01)
    XCTAssertTrue(samples[1].overlapped)
    XCTAssertEqual(samples[1].releaseToOutputMs ?? -1, 2, accuracy: 0.01)
  }

  func testATapWithoutOutputCountsAsLostOnlyAfterAQuietPause() {
    var probe = TypingProbe()
    probe.touchBegan(1, at: 0, receivedAt: 0.01)
    probe.touchEnded(1, at: 0.05)
    XCTAssertEqual(probe.takeSettled(now: 0.3, wallClock: 0), [])
    let samples = probe.takeSettled(now: 0.7, wallClock: 0)
    XCTAssertEqual(samples.count, 1)
    XCTAssertFalse(samples[0].producedOutput)
  }

  func testCancelledTouchIsNotATap() {
    var probe = TypingProbe()
    probe.touchBegan(1, at: 0, receivedAt: 0.01)
    probe.touchCancelled(1)
    XCTAssertEqual(probe.takeSettled(now: 5, wallClock: 0), [])
  }

  func testStatsKeepTheLast200AndSurviveStorage() {
    var stats = TypingStats()
    for i in 0..<250 {
      stats.append(
        TypingSample(
          deliveryMs: Double(i), pressToOutputMs: i % 10 == 0 ? nil : 80, releaseToOutputMs: 2,
          overlapped: i % 2 == 0, recordedAt: Double(i)))
    }
    XCTAssertEqual(stats.samples.count, 200)
    XCTAssertEqual(TypingStats(encoded: stats.encoded), stats)
    let summary = stats.summary
    XCTAssertEqual(summary.withoutOutput, 20)
    XCTAssertEqual(summary.overlapped, 100)
    XCTAssertEqual(summary.delivery, TypingStats.Spread(median: 149, p95: 239))
    XCTAssertEqual(stats.since(240).samples.count, 10)
  }
}
