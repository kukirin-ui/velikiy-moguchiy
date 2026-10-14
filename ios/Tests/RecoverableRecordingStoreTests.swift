import XCTest

@testable import VelikiyMoguchiy

final class RecoverableRecordingStoreTests: XCTestCase {
  private var directoryURL: URL!

  override func setUpWithError() throws {
    directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true
    )
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directoryURL)
  }

  func testFailedRecordingSurvivesStoreReload() throws {
    let requestID = UUID().uuidString
    let audioURL = directoryURL.appendingPathComponent("completed-note-en-\(requestID).wav")
    try Data([0x52, 0x49, 0x46, 0x46]).write(to: audioURL)
    let segment = CapturedAudioSegment(
      requestID: requestID,
      url: audioURL,
      startedAt: Date(timeIntervalSince1970: 100),
      endedAt: Date(timeIntervalSince1970: 103)
    )

    let firstStore = RecoverableRecordingStore(directoryURL: directoryURL)
    let item = try firstStore.stage(
      segment,
      action: .note,
      languageCode: "en"
    )
    firstStore.markFailed(id: item.id, message: "The connection was lost")

    let reloaded = RecoverableRecordingStore(directoryURL: directoryURL)
    XCTAssertEqual(reloaded.recordings.count, 1)
    XCTAssertEqual(reloaded.recordings[0].id, item.id)
    XCTAssertEqual(reloaded.recordings[0].action, .note)
    XCTAssertEqual(reloaded.recordings[0].languageCode, "en")
    XCTAssertEqual(reloaded.recordings[0].lastError, "The connection was lost")
    XCTAssertEqual(reloaded.recordings[0].duration, 3)
  }

  func testSuccessfulRetryRemovesMetadataAndAudio() throws {
    let requestID = UUID().uuidString
    let audioURL = directoryURL.appendingPathComponent("completed-transcribe-en-\(requestID).wav")
    try Data([0x01]).write(to: audioURL)
    let store = RecoverableRecordingStore(directoryURL: directoryURL)
    let item = try store.stage(
      CapturedAudioSegment(
        requestID: requestID,
        url: audioURL,
        startedAt: Date(),
        endedAt: Date()
      ),
      action: .transcribe,
      languageCode: "en"
    )

    try store.remove(id: item.id)

    XCTAssertTrue(store.recordings.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
    XCTAssertTrue(RecoverableRecordingStore(directoryURL: directoryURL).recordings.isEmpty)
  }

  func testFinalizedOrphanBecomesRetryableWithEncodedIntent() throws {
    let requestID = UUID().uuidString
    let audioURL = directoryURL.appendingPathComponent("completed-note-ru-\(requestID).wav")
    try Data([0x01, 0x02]).write(to: audioURL)

    let store = RecoverableRecordingStore(directoryURL: directoryURL)

    XCTAssertEqual(store.recordings.count, 1)
    XCTAssertEqual(store.recordings[0].requestID, requestID)
    XCTAssertEqual(store.recordings[0].action, .note)
    XCTAssertEqual(store.recordings[0].languageCode, "ru")
    XCTAssertTrue(store.recordings[0].lastError.contains("Восстановлено"))
  }

  func testUnfinishedOrLegacyOrphanIsNeverOfferedForRetry() throws {
    let requestID = UUID().uuidString
    let unfinished = directoryURL.appendingPathComponent("in-progress-dictation-\(requestID).wav")
    let ambiguousLegacy = directoryURL.appendingPathComponent("dictation-\(UUID().uuidString).wav")
    try Data([0x01]).write(to: unfinished)
    try Data([0x02]).write(to: ambiguousLegacy)

    let store = RecoverableRecordingStore(directoryURL: directoryURL)

    XCTAssertTrue(store.recordings.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: unfinished.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: ambiguousLegacy.path))
  }
}
