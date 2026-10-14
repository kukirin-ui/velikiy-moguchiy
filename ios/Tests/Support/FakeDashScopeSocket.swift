import Foundation

@testable import VelikiyMoguchiy

/// An in-memory DashScope realtime server. It speaks the verified protocol:
/// `session.created` on start, `session.updated` after `session.update`,
/// preview deltas while audio streams, and text events after `response.create`.
final class FakeDashScopeSocket: DashScopeSocket, @unchecked Sendable {
  struct Script {
    var finalText: String = ""
    var previewText: String = "прив"
    /// When set, the server answers `response.create` with this error event.
    var errorOnResponse: String?
    /// When true the server never answers `response.create`.
    var neverRespond = false
    var emitDoneEvent = true
  }

  private let lock = NSLock()
  private var sentMessages: [[String: Any]] = []
  private var closeCode: URLSessionWebSocketTask.CloseCode?
  private let script: Script
  private let stream: AsyncThrowingStream<Data, Error>
  private let continuation: AsyncThrowingStream<Data, Error>.Continuation
  private var iterator: AsyncThrowingStream<Data, Error>.Iterator

  init(script: Script) {
    self.script = script
    let pair = AsyncThrowingStream<Data, Error>.makeStream()
    stream = pair.stream
    continuation = pair.continuation
    iterator = pair.stream.makeAsyncIterator()
  }

  var messages: [[String: Any]] {
    lock.lock()
    defer { lock.unlock() }
    return sentMessages
  }

  var messageTypes: [String] { messages.compactMap { $0["type"] as? String } }
  var wasClosed: Bool {
    lock.lock()
    defer { lock.unlock() }
    return closeCode != nil
  }

  func start() async {
    emit(["type": "session.created", "session": ["id": "sess_fake"]])
  }

  func send(text: String) async throws {
    let object =
      try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] ?? [:]
    lock.lock()
    sentMessages.append(object)
    lock.unlock()
    switch object["type"] as? String {
    case "session.update":
      emit(["type": "session.updated"])
    case "input_audio_buffer.append":
      emit([
        "type": "conversation.item.input_audio_transcription.delta",
        "text": "", "stash": script.previewText,
      ])
    case "response.create":
      guard !script.neverRespond else { return }
      if let error = script.errorOnResponse {
        emit(["type": "error", "error": ["message": error]])
        return
      }
      emit(["type": "response.created"])
      let halves = [
        String(script.finalText.prefix(script.finalText.count / 2)),
        String(script.finalText.dropFirst(script.finalText.count / 2)),
      ]
      for half in halves where !half.isEmpty {
        emit(["type": "response.text.delta", "delta": half])
      }
      emit(["type": "response.text.done", "text": script.finalText])
      if script.emitDoneEvent { emit(["type": "response.done"]) }
    default:
      break
    }
  }

  func receive() async throws -> Data {
    guard let data = try await iterator.next() else {
      throw URLError(.networkConnectionLost)
    }
    return data
  }

  func close(code: URLSessionWebSocketTask.CloseCode) async {
    lock.lock()
    closeCode = code
    lock.unlock()
    continuation.finish()
  }

  private func emit(_ object: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: object) {
      continuation.yield(data)
    }
  }
}

enum TestAudio {
  /// 16-bit mono PCM tone, loud enough to count as speech.
  static func pcm16(seconds: Double, sampleRate: Int, amplitude: Double = 0.4) -> Data {
    let count = Int(seconds * Double(sampleRate))
    var data = Data(capacity: count * 2)
    for index in 0..<count {
      let value = sin(2 * .pi * 220 * Double(index) / Double(sampleRate)) * amplitude
      var sample = Int16(value * Double(Int16.max)).littleEndian
      withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
    }
    return data
  }

  static func writeWAV(
    to url: URL, seconds: Double, sampleRate: Int, amplitude: Double = 0.4
  ) throws {
    let pcm = pcm16(seconds: seconds, sampleRate: sampleRate, amplitude: amplitude)
    var header = Data()
    func append32(_ value: UInt32) {
      var v = value.littleEndian
      withUnsafeBytes(of: &v) { header.append(contentsOf: $0) }
    }
    func append16(_ value: UInt16) {
      var v = value.littleEndian
      withUnsafeBytes(of: &v) { header.append(contentsOf: $0) }
    }
    header.append(contentsOf: Array("RIFF".utf8))
    append32(UInt32(36 + pcm.count))
    header.append(contentsOf: Array("WAVEfmt ".utf8))
    append32(16)
    append16(1)
    append16(1)
    append32(UInt32(sampleRate))
    append32(UInt32(sampleRate * 2))
    append16(2)
    append16(16)
    header.append(contentsOf: Array("data".utf8))
    append32(UInt32(pcm.count))
    try (header + pcm).write(to: url)
  }
}
