import Foundation

/// One DashScope Qwen-Omni realtime dictation. The containing app creates a
/// session per keyboard request, streams 100 ms PCM chunks while the user
/// speaks (`enqueueAudio`), and calls `finish()` to commit the audio and read
/// back the punctuated text.
///
/// The actor serializes socket setup, queued audio, server events, Finish,
/// Cancel and close, mirroring the contract of the Gemini actor this replaced:
/// `connect` / `enqueueAudio` / `invalidateAudioStream` / `finish` / `cancel`.
actor DashScopeRealtimeSession {
  typealias SocketFactory = @Sendable (DashScopeEndpoint) -> any DashScopeSocket

  /// Bounded waits (seconds). Kept as statics so tests can reason about them.
  static let setupTimeout: TimeInterval = 10
  static let responseTimeout: TimeInterval = 40
  /// After `response.text.done` the service normally sends `response.done`
  /// immediately; do not hang if only the latter is lost.
  static let doneGrace: TimeInterval = 1.5

  let language: DictationLanguage
  let progressHandler: (@Sendable (String) -> Void)?
  let socketFactory: SocketFactory
  nonisolated let audioStream: AsyncStream<Data>
  nonisolated let audioContinuation: AsyncStream<Data>.Continuation

  var socket: (any DashScopeSocket)?
  var receiveTask: Task<Void, Never>?
  var audioConsumerTask: Task<Void, Never>?
  var pendingAudio: [Data] = []
  var pendingAudioByteCount = 0
  var sentAudioByteCount = 0
  var sawLikelySpeech = false
  var isConfigured = false
  var isFlushingPendingAudio = false
  var sessionCreated = false
  var sessionUpdated = false
  var isFinishing = false
  var isClosed = false
  var terminalError: Error?

  var previewText = ""
  var completedTranscript = ""
  var streamedResponseText = ""
  var responseTextDone: String?
  var responseTextDoneAt: Date?
  var responseDone = false

  init(
    language: DictationLanguage,
    socketFactory: @escaping SocketFactory = { endpoint in
      URLSessionDashScopeSocket(endpoint: endpoint)
    },
    progressHandler: (@Sendable (String) -> Void)? = nil
  ) {
    let streamPair = AsyncStream<Data>.makeStream(
      bufferingPolicy: .bufferingNewest(500)
    )
    self.language = language
    self.socketFactory = socketFactory
    self.progressHandler = progressHandler
    self.audioStream = streamPair.stream
    self.audioContinuation = streamPair.continuation
  }

  // MARK: Connection

  func connect(apiKey: String, region: DashScopeRegion) async throws {
    guard socket == nil, !isClosed else {
      throw DashScopeSpeechError.alreadyConnected
    }

    let endpoint = try DashScopeProtocol.endpoint(apiKey: apiKey, region: region)
    let socket = socketFactory(endpoint)
    self.socket = socket
    await socket.start()

    receiveTask = Task { [weak self] in
      await self?.receiveMessages()
    }
    audioConsumerTask = Task { [weak self, audioStream] in
      for await data in audioStream {
        guard !Task.isCancelled else { return }
        await self?.acceptAudio(data)
      }
    }

    do {
      try await waitUntil(timeout: Self.setupTimeout, failure: "DashScope не создал сеанс.") {
        await self.sessionCreated
      }
      try await send(DashScopeProtocol.sessionUpdateMessage(language: language), over: socket)
      try await waitUntil(
        timeout: Self.setupTimeout,
        failure: "DashScope не подтвердил настройки сеанса."
      ) {
        await self.sessionUpdated
      }
      try await flushPendingAudio(over: socket)
      isConfigured = true
    } catch {
      terminalError = terminalError ?? error
      await close(code: .goingAway)
      throw terminalError ?? error
    }
  }

  private func waitUntil(
    timeout: TimeInterval,
    failure: String,
    _ condition: @escaping () async -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      try Task.checkCancellation()
      if let terminalError { throw terminalError }
      if await condition() { return }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    throw DashScopeSpeechError.connectionClosed(failure)
  }

  // MARK: Audio

  nonisolated func enqueueAudio(_ data: Data) {
    guard !data.isEmpty else { return }
    switch audioContinuation.yield(data) {
    case .enqueued:
      break
    case .dropped:
      Task { await markAudioBackpressureFailure() }
    case .terminated:
      break
    @unknown default:
      Task { await markAudioBackpressureFailure() }
    }
  }

  func invalidateAudioStream(_ reason: String) {
    guard terminalError == nil, !isClosed else { return }
    terminalError = DashScopeSpeechError.service(reason)
  }

  /// Sends PCM directly (used to replay a saved recording, where the caller
  /// can await each send instead of relying on the bounded live stream).
  func sendPCM(_ data: Data) async throws {
    guard let socket, isConfigured, !isClosed else {
      throw DashScopeSpeechError.connectionClosed("")
    }
    try await sendAudio(data, over: socket)
  }

  func acceptAudio(_ data: Data) async {
    guard !data.isEmpty, !isClosed, terminalError == nil else { return }
    guard isConfigured, !isFlushingPendingAudio, let socket else {
      bufferPendingAudio(data)
      return
    }
    do {
      try await sendAudio(data, over: socket)
    } catch {
      terminalError = DashScopeSpeechError.connectionClosed("поток звука прервался.")
    }
  }

  private func bufferPendingAudio(_ data: Data) {
    // Setup normally resolves in about a second. Keep a generous bounded
    // buffer for startup jitter without retaining an entire long recording.
    let maximumBufferedBytes = 1_500_000
    guard pendingAudioByteCount + data.count <= maximumBufferedBytes else {
      terminalError = DashScopeSpeechError.service(
        "DashScope слишком долго соединялся. Будет использована сохранённая запись."
      )
      pendingAudio.removeAll(keepingCapacity: false)
      pendingAudioByteCount = 0
      return
    }
    pendingAudio.append(data)
    pendingAudioByteCount += data.count
  }

  private func markAudioBackpressureFailure() {
    guard terminalError == nil, !isClosed else { return }
    terminalError = DashScopeSpeechError.service(
      "Поток звука не успевает за сетью. Будет использована сохранённая запись."
    )
  }

  private func flushPendingAudio(over socket: any DashScopeSocket) async throws {
    isFlushingPendingAudio = true
    defer { isFlushingPendingAudio = false }
    while !pendingAudio.isEmpty {
      let batch = pendingAudio
      pendingAudio.removeAll(keepingCapacity: true)
      pendingAudioByteCount = 0
      for chunk in batch {
        try Task.checkCancellation()
        try await sendAudio(chunk, over: socket)
      }
    }
  }

  private func sendAudio(_ data: Data, over socket: any DashScopeSocket) async throws {
    try await send(DashScopeProtocol.audioAppendMessage(data), over: socket)
    sentAudioByteCount += data.count
    if DashScopeProtocol.containsLikelySpeech(data) {
      sawLikelySpeech = true
    }
  }

  private func send(
    _ object: [String: Any],
    over socket: any DashScopeSocket
  ) async throws {
    let data: Data
    do {
      data = try JSONSerialization.data(withJSONObject: object)
    } catch {
      throw DashScopeSpeechError.invalidMessage
    }
    guard let text = String(data: data, encoding: .utf8) else {
      throw DashScopeSpeechError.invalidMessage
    }
    do {
      try await dashScopeWithTimeout(nanoseconds: 8_000_000_000) {
        try await socket.send(text: text)
      }
    } catch is DashScopeTimeoutError {
      await socket.close(code: .goingAway)
      throw DashScopeSpeechError.connectionClosed("соединение перестало отвечать.")
    }
  }

  // MARK: Events

  private func receiveMessages() async {
    guard let socket else { return }
    while !Task.isCancelled, !isClosed {
      do {
        let data = try await socket.receive()
        try process(data)
      } catch is CancellationError {
        return
      } catch {
        guard !isClosed else { return }
        // A normal close after response.done is not a failure.
        if responseDone { return }
        terminalError =
          error is DashScopeSpeechError || (error as NSError).domain == NSURLErrorDomain
          ? error
          : DashScopeSpeechError.connectionClosed("сетевое соединение прервано.")
        return
      }
    }
  }

  func process(_ data: Data) throws {
    for event in try DashScopeProtocol.events(from: data) {
      switch event {
      case .sessionCreated:
        sessionCreated = true
      case .sessionUpdated:
        sessionUpdated = true
      case .previewTranscription(let text):
        previewText = text
        if !TranscriptFormatter.cleaned(text).isEmpty {
          progressHandler?(text)
        }
      case .completedTranscription(let transcript):
        completedTranscript = transcript
      case .responseTextDelta(let delta):
        streamedResponseText += delta
      case .responseTextDone(let text):
        responseTextDone = text
        responseTextDoneAt = Date()
      case .responseDone:
        responseDone = true
      case .serviceError(let code, let message):
        terminalError = DashScopeSpeechError.provider(code: code, message: message)
      }
    }
  }

  // MARK: Finish / cancel

  var finalText: String {
    let candidates = [responseTextDone ?? "", streamedResponseText, completedTranscript]
    for candidate in candidates {
      let cleaned = Self.cleanedDictation(candidate)
      if !cleaned.isEmpty { return cleaned }
    }
    return ""
  }

  static func cleanedDictation(_ raw: String) -> String {
    var value = TranscriptFormatter.cleaned(raw)
    // The prompt example is written in guillemets; some answers echo them.
    if value.hasPrefix("«"), value.hasSuffix("»"), value.count >= 2 {
      let inner = String(value.dropFirst().dropLast())
      if !inner.contains("«"), !inner.contains("»") {
        value = TranscriptFormatter.cleaned(inner)
      }
    }
    return value
  }

  func finish() async throws -> String {
    try await withTaskCancellationHandler {
      try await finishAfterDrainingAudio()
    } onCancel: { [weak self] in
      Task { await self?.cancel() }
    }
  }

  private func finishAfterDrainingAudio() async throws -> String {
    guard !isClosed else {
      let text = finalText
      guard !text.isEmpty else { throw DashScopeSpeechError.emptyResult }
      return text
    }
    guard !isFinishing else {
      throw DashScopeSpeechError.connectionClosed("поток уже завершается.")
    }
    isFinishing = true

    // Stop accepting new chunks, then wait until every chunk already yielded
    // by AudioCaptureEngine has reached the WebSocket before committing.
    audioContinuation.finish()
    if let audioConsumerTask {
      do {
        try await dashScopeWithTimeout(nanoseconds: 10_000_000_000) {
          await audioConsumerTask.value
        }
      } catch is CancellationError {
        await close(code: .goingAway)
        throw CancellationError()
      } catch {
        await close(code: .goingAway)
        throw DashScopeSpeechError.connectionClosed("звук не успел отправиться.")
      }
    }
    self.audioConsumerTask = nil

    if let terminalError {
      await close(code: .goingAway)
      throw terminalError
    }
    guard let socket, isConfigured else {
      await close(code: .goingAway)
      throw DashScopeSpeechError.connectionClosed("")
    }
    // Committing an empty or silent buffer makes the model invent text.
    guard sentAudioByteCount >= PCM16StreamChunker.targetBytesPerChunk, sawLikelySpeech else {
      await close(code: .normalClosure)
      throw DashScopeSpeechError.noSpeech
    }

    do {
      try await send(DashScopeProtocol.commitMessage(), over: socket)
      try await send(DashScopeProtocol.responseCreateMessage(), over: socket)
    } catch {
      terminalError = error
      await close(code: .goingAway)
      throw error
    }

    let deadline = Date().addingTimeInterval(Self.responseTimeout)
    while Date() < deadline {
      try Task.checkCancellation()
      if let terminalError {
        await close(code: .goingAway)
        throw terminalError
      }
      if responseDone { break }
      if let doneAt = responseTextDoneAt,
        Date().timeIntervalSince(doneAt) >= Self.doneGrace
      {
        break
      }
      try await Task.sleep(nanoseconds: 50_000_000)
    }

    let text = finalText
    await close(code: .normalClosure)
    guard !text.isEmpty else {
      throw responseDone || responseTextDone != nil
        ? DashScopeSpeechError.emptyResult
        : DashScopeSpeechError.connectionClosed("DashScope не вернул итоговый текст.")
    }
    return text
  }

  func cancel() async {
    audioContinuation.finish()
    audioConsumerTask?.cancel()
    audioConsumerTask = nil
    await close(code: .goingAway)
  }

  func close(code: URLSessionWebSocketTask.CloseCode) async {
    guard !isClosed else { return }
    isClosed = true
    audioContinuation.finish()
    audioConsumerTask?.cancel()
    audioConsumerTask = nil
    receiveTask?.cancel()
    receiveTask = nil
    if let socket {
      await socket.close(code: code)
    }
    socket = nil
    pendingAudio.removeAll(keepingCapacity: false)
    pendingAudioByteCount = 0
  }
}
