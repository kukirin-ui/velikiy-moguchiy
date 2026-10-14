import AVFoundation
import XCTest

@testable import VelikiyMoguchiy

final class AudioCaptureEngineTests: XCTestCase {
  func testRejectsStaleRouteFormatBeforeInstallingTap() throws {
    let oldRoute = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
    let newRoute = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let stereoRoute = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
    XCTAssertFalse(AudioCaptureEngine.isUsableInputFormat(oldRoute, hardwareFormat: newRoute))
    XCTAssertFalse(AudioCaptureEngine.isUsableInputFormat(newRoute, hardwareFormat: stereoRoute))
    XCTAssertTrue(AudioCaptureEngine.isUsableInputFormat(newRoute, hardwareFormat: newRoute))
  }

  @MainActor
  func testReplacedEngineIgnoresOldConfigurationNotifications() {
    let capture = AudioCaptureEngine()
    let oldEngine = capture.engine
    capture.replaceStoppedEngine()
    XCTAssertFalse(oldEngine === capture.engine)
    capture.shouldBeRunning = true
    NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: oldEngine)
    XCTAssertNil(capture.recoveryWorkItem)
    NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: capture.engine)
    XCTAssertNotNil(capture.recoveryWorkItem)
    capture.stop()
    XCTAssertNil(capture.recoveryWorkItem)
  }

  func testRecoverableRecordingScanRunsOnlyOncePerRelayInstance() {
    var gate = RecoverableRecordingScanGate()

    XCTAssertTrue(gate.claim())
    XCTAssertFalse(gate.claim(), "Route recovery must not rescan a finalized recovery WAV")
  }

  func testSimulatorReportsMicrophoneCaptureAsUnavailableWithoutStartingAudioIO() {
    #if targetEnvironment(simulator)
      XCTAssertFalse(AudioCaptureEngine.isMicrophoneCaptureAvailable)
      XCTAssertThrowsError(try AudioCaptureEngine().start()) { error in
        guard case AudioCaptureError.simulatorMicrophoneUnavailable = error else {
          return XCTFail("Unexpected error: \(error)")
        }
      }
    #else
      XCTAssertTrue(AudioCaptureEngine.isMicrophoneCaptureAvailable)
    #endif
  }

  func testPCMChunkerProducesRouteIndependentHundredMillisecondPackets() {
    var chunker = PCM16StreamChunker()
    let first = chunker.append(Data(repeating: 0x11, count: 1_100))
    let second = chunker.append(Data(repeating: 0x22, count: 5_500))

    XCTAssertTrue(first.isEmpty)
    XCTAssertEqual(second.map(\.count), [3_200, 3_200])
    XCTAssertEqual(chunker.bufferedData.count, 200)
    XCTAssertEqual(chunker.finish()?.count, 200)
    XCTAssertTrue(chunker.bufferedData.isEmpty)
  }

  func testPCMChunkerResetDiscardsCancelledSegmentTail() {
    var chunker = PCM16StreamChunker()
    XCTAssertTrue(chunker.append(Data(repeating: 0x33, count: 900)).isEmpty)
    chunker.reset()
    XCTAssertNil(chunker.finish())
  }
}
