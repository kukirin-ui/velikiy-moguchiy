import XCTest

@testable import VelikiyMoguchiy

final class DashScopeProtocolTests: XCTestCase {
  func testSessionUpdateMatchesTheVerifiedProtocol() throws {
    let message = DashScopeProtocol.sessionUpdateMessage(language: .russian)
    XCTAssertEqual(message["type"] as? String, "session.update")
    let session = try XCTUnwrap(message["session"] as? [String: Any])
    XCTAssertEqual(session["modalities"] as? [String], ["text"])
    // Default voices are rejected by Omni; only Serena works.
    XCTAssertEqual(session["voice"] as? String, "Serena")
    XCTAssertEqual(session["input_audio_format"] as? String, "pcm")
    XCTAssertEqual(session["sample_rate"] as? Int, 16_000)
    XCTAssertTrue(session["turn_detection"] is NSNull, "manual commit needs turn_detection=null")
    let transcription = try XCTUnwrap(session["input_audio_transcription"] as? [String: Any])
    XCTAssertEqual(transcription["language"] as? String, "ru")
    XCTAssertEqual(
      session["instructions"] as? String, DashScopeProtocol.russianInstructions)

    let english = DashScopeProtocol.sessionUpdateMessage(language: .english)["session"] as? [String: Any]
    XCTAssertEqual((english?["input_audio_transcription"] as? [String: Any])?["language"] as? String, "en")
    XCTAssertEqual(english?["instructions"] as? String, DashScopeProtocol.englishInstructions)
    XCTAssertNotEqual(DashScopeProtocol.russianInstructions, DashScopeProtocol.englishInstructions)
  }

  func testRussianInstructionsAreTheTestedPrompt() {
    XCTAssertTrue(DashScopeProtocol.russianInstructions.hasPrefix("Ты — модуль диктовки."))
    XCTAssertTrue(DashScopeProtocol.russianInstructions.contains("Привет, как дела? У меня всё хорошо."))
  }

  func testEndpointUsesBearerHeaderAndKeepsTheKeyOutOfTheURL() throws {
    let endpoint = try DashScopeProtocol.endpoint(apiKey: "  sk-secret-123 \n", region: .china)
    XCTAssertEqual(endpoint.headers["Authorization"], "Bearer sk-secret-123")
    XCTAssertEqual(endpoint.url.scheme, "wss")
    XCTAssertEqual(endpoint.url.host, "dashscope.aliyuncs.com")
    XCTAssertEqual(
      try DashScopeProtocol.endpoint(apiKey: "sk-1", region: .international).url.host,
      "dashscope-intl.aliyuncs.com")
    XCTAssertEqual(endpoint.url.path, "/api-ws/v1/realtime")
    XCTAssertEqual(endpoint.url.query, "model=qwen3.8-omni-flash-realtime")
    XCTAssertFalse(endpoint.url.absoluteString.contains("sk-secret"))
  }

  func testEndpointRejectsMissingKey() {
    XCTAssertThrowsError(try DashScopeProtocol.endpoint(apiKey: "  ", region: .international)) { error in
      guard case DashScopeSpeechError.missingCredential = error else {
        return XCTFail("unexpected \(error)")
      }
    }
  }

  func testAudioAppendCarriesBase64Pcm() throws {
    let message = DashScopeProtocol.audioAppendMessage(Data([1, 2, 3, 4]))
    XCTAssertEqual(message["type"] as? String, "input_audio_buffer.append")
    XCTAssertEqual(message["audio"] as? String, Data([1, 2, 3, 4]).base64EncodedString())
  }

  func testPreviewIsTextPlusStash() throws {
    let json = #"{"type":"conversation.item.input_audio_transcription.delta","text":"Привет, ","stash":"это"}"#
    XCTAssertEqual(
      try DashScopeProtocol.events(from: Data(json.utf8)), [.previewTranscription("Привет, это")])
  }

  func testResponseEventsAreParsed() throws {
    func events(_ json: String) throws -> [DashScopeProtocol.ServerEvent] {
      try DashScopeProtocol.events(from: Data(json.utf8))
    }
    XCTAssertEqual(try events(#"{"type":"response.text.delta","delta":"Пр"}"#), [.responseTextDelta("Пр")])
    XCTAssertEqual(try events(#"{"type":"response.text.done","text":"Привет."}"#), [.responseTextDone("Привет.")])
    XCTAssertEqual(try events(#"{"type":"response.done"}"#), [.responseDone])
    XCTAssertEqual(try events(#"{"type":"session.created"}"#), [.sessionCreated])
    XCTAssertEqual(try events(#"{"type":"session.updated"}"#), [.sessionUpdated])
    XCTAssertEqual(try events(#"{"type":"response.created"}"#), [])
    XCTAssertEqual(
      try events(#"{"type":"error","error":{"message":"Invalid voice"}}"#),
      [.serviceError(code: nil, message: "Invalid voice")])
    XCTAssertThrowsError(try events("[]"))
  }

  func testSpeechEnergyGate() {
    XCTAssertTrue(DashScopeProtocol.containsLikelySpeech(TestAudio.pcm16(seconds: 0.1, sampleRate: 16_000)))
    XCTAssertFalse(DashScopeProtocol.containsLikelySpeech(Data(repeating: 0, count: 3_200)))
  }
}

final class DashScopeRealtimeSessionTests: XCTestCase {
  private func makeSession(
    language: DictationLanguage = .russian,
    script: FakeDashScopeSocket.Script,
    previews: PreviewCollector = PreviewCollector()
  ) -> (DashScopeRealtimeSession, FakeDashScopeSocket, PreviewCollector) {
    let socket = FakeDashScopeSocket(script: script)
    let session = DashScopeRealtimeSession(
      language: language,
      socketFactory: { _ in socket },
      progressHandler: { previews.append($0) }
    )
    return (session, socket, previews)
  }

  private func stream(_ session: DashScopeRealtimeSession, seconds: Double) {
    let pcm = TestAudio.pcm16(seconds: seconds, sampleRate: 16_000)
    var offset = 0
    while offset < pcm.count {
      let end = min(offset + PCM16StreamChunker.targetBytesPerChunk, pcm.count)
      session.enqueueAudio(pcm.subdata(in: offset..<end))
      offset = end
    }
  }

  func testDictationFollowsTheVerifiedMessageSequence() async throws {
    let (session, socket, previews) = makeSession(
      script: .init(finalText: "Привет, это проверка. Как дела?"))
    try await session.connect(apiKey: "sk-test", region: .international)
    stream(session, seconds: 0.5)
    let text = try await session.finish()

    XCTAssertEqual(text, "Привет, это проверка. Как дела?")
    let types = socket.messageTypes
    XCTAssertEqual(types.first, "session.update")
    XCTAssertTrue(types.dropFirst().dropLast(2).allSatisfy { $0 == "input_audio_buffer.append" })
    XCTAssertEqual(Array(types.suffix(2)), ["input_audio_buffer.commit", "response.create"])
    XCTAssertFalse(types.contains("session.finish"), "Omni rejects session.finish")
    XCTAssertEqual(types.filter { $0 == "input_audio_buffer.append" }.count, 5)
    XCTAssertTrue(socket.wasClosed)
    XCTAssertFalse(previews.values.isEmpty, "live preview should reach the handler")
    XCTAssertEqual(previews.values.last, "прив")
  }

  func testEnglishKeyboardSendsEnglishLanguageAndInstructions() async throws {
    let (session, socket, _) = makeSession(
      language: .english, script: .init(finalText: "Hello, how are you?"))
    try await session.connect(apiKey: "sk-test", region: .international)
    stream(session, seconds: 0.3)
    let text = try await session.finish()
    XCTAssertEqual(text, "Hello, how are you?")
    let update = try XCTUnwrap(socket.messages.first?["session"] as? [String: Any])
    XCTAssertEqual((update["input_audio_transcription"] as? [String: Any])?["language"] as? String, "en")
    XCTAssertEqual(update["instructions"] as? String, DashScopeProtocol.englishInstructions)
  }

  func testWrappingGuillemetsAreStripped() async throws {
    let (session, _, _) = makeSession(script: .init(finalText: "«Привет, мир.»"))
    try await session.connect(apiKey: "sk-test", region: .international)
    stream(session, seconds: 0.3)
    let text = try await session.finish()
    XCTAssertEqual(text, "Привет, мир.")
  }

  func testSilenceNeverCommitsAndReportsNoSpeech() async throws {
    let (session, socket, _) = makeSession(script: .init(finalText: "invented text"))
    try await session.connect(apiKey: "sk-test", region: .international)
    for _ in 0..<5 { session.enqueueAudio(Data(count: PCM16StreamChunker.targetBytesPerChunk)) }
    do {
      _ = try await session.finish()
      XCTFail("silence must not produce text")
    } catch DashScopeSpeechError.noSpeech {
    }
    XCTAssertFalse(socket.messageTypes.contains("input_audio_buffer.commit"))
  }

  func testServiceErrorSurfaces() async throws {
    let (session, _, _) = makeSession(script: .init(errorOnResponse: "Invalid voice"))
    try await session.connect(apiKey: "sk-test", region: .international)
    stream(session, seconds: 0.3)
    do {
      _ = try await session.finish()
      XCTFail("expected a service error")
    } catch DashScopeSpeechError.provider(let code, let message) {
      XCTAssertNil(code)
      XCTAssertEqual(message, "Invalid voice")
    }
  }

  func testTextDoneWithoutResponseDoneStillCompletes() async throws {
    var script = FakeDashScopeSocket.Script(finalText: "Готово.")
    script.emitDoneEvent = false
    let (session, _, _) = makeSession(script: script)
    try await session.connect(apiKey: "sk-test", region: .international)
    stream(session, seconds: 0.3)
    let text = try await session.finish()
    XCTAssertEqual(text, "Готово.")
  }

  func testCancelClosesWithoutCommitting() async throws {
    let (session, socket, _) = makeSession(script: .init(finalText: "x"))
    try await session.connect(apiKey: "sk-test", region: .international)
    stream(session, seconds: 0.3)
    await session.cancel()
    XCTAssertTrue(socket.wasClosed)
    XCTAssertFalse(socket.messageTypes.contains("input_audio_buffer.commit"))
    XCTAssertFalse(socket.messageTypes.contains("response.create"))
  }

  func testAudioQueuedBeforeSetupIsFlushedInOrder() async throws {
    let (session, socket, _) = makeSession(script: .init(finalText: "Ок."))
    // Audio arrives while the socket is still handshaking.
    stream(session, seconds: 0.3)
    try await session.connect(apiKey: "sk-test", region: .international)
    _ = try await session.finish()
    let types = socket.messageTypes
    XCTAssertEqual(types.first, "session.update")
    XCTAssertEqual(types.filter { $0 == "input_audio_buffer.append" }.count, 3)
  }

  func testSavedRecordingReplayConvertsToSixteenKilohertzChunks() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    try TestAudio.writeWAV(to: url, seconds: 1.0, sampleRate: 44_100)

    let socket = FakeDashScopeSocket(script: .init(finalText: "Из записи."))
    let transcriber = DashScopeRecordingTranscriber(socketFactory: { _ in socket })
    let text = try await transcriber.transcribe(recordingAt: url, language: .russian, apiKey: "sk-test", region: .international)
    XCTAssertEqual(text, "Из записи.")

    let appended = socket.messages.filter { $0["type"] as? String == "input_audio_buffer.append" }
    let bytes = appended.compactMap { ($0["audio"] as? String).flatMap { Data(base64Encoded: $0) } }
    // 1 s at 16 kHz mono Int16 = 32 000 bytes (+- converter edge effects).
    let total = bytes.reduce(0) { $0 + $1.count }
    XCTAssertEqual(Double(total), 32_000, accuracy: 1_600)
    XCTAssertTrue(bytes.dropLast().allSatisfy { $0.count == PCM16StreamChunker.targetBytesPerChunk })
  }
}

final class PreviewCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String] = []
  func append(_ value: String) {
    lock.lock()
    storage.append(value)
    lock.unlock()
  }
  var values: [String] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}
