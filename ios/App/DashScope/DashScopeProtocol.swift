import Foundation

enum DashScopeSpeechError: LocalizedError {
  case missingCredential
  case invalidEndpoint
  case invalidMessage
  case alreadyConnected
  case connectionClosed(String)
  /// A local reason the stream was abandoned (backpressure, slow setup).
  case service(String)
  /// An `error` event from DashScope, with its code when it sent one.
  case provider(code: String?, message: String)
  /// The WebSocket handshake was answered with this HTTP status.
  case rejected(httpStatus: Int)
  /// The model answered, but with no text.
  case emptyResult
  /// Nothing loud enough to be speech was recorded; nothing was sent.
  case noSpeech

  var errorDescription: String? {
    switch self {
    case .missingCredential:
      return "Добавьте ключ DashScope в приложении «Великий & Могучий»."
    case .invalidEndpoint:
      return "Не удалось создать защищённое соединение с DashScope."
    case .invalidMessage:
      return "DashScope вернул ответ, который не удалось прочитать."
    case .alreadyConnected:
      return "Сеанс DashScope уже запущен."
    case .connectionClosed(let reason):
      return reason.isEmpty
        ? "Соединение с DashScope закрылось до конца распознавания."
        : "Соединение с DashScope закрыто: \(reason)"
    case .service(let message):
      return message
    case .provider(let code, let message):
      return code.map { "DashScope: \(message) (\($0))" } ?? "DashScope: \(message)"
    case .rejected(let httpStatus):
      return "DashScope отклонил подключение (HTTP \(httpStatus))."
    case .emptyResult:
      return "Речь не распознана."
    case .noSpeech:
      return "Речь не слышна."
    }
  }
}

/// A resolved realtime connection target. The API key travels only in the
/// `Authorization` header of the WebSocket handshake, never in the URL.
struct DashScopeEndpoint: Equatable, Sendable {
  let url: URL
  let headers: [String: String]
}

/// The pure message layer of the DashScope Qwen-Omni realtime protocol
/// (`/api-ws/v1/realtime`). Verified against the live service:
///
/// 1. `session.created`  (server)  -> send `session.update` (voice `Serena` is
///    mandatory even for text-only output) -> `session.updated`.
/// 2. `input_audio_buffer.append` with base64 PCM16 mono 16 kHz, ~100 ms each.
/// 3. While speaking: `conversation.item.input_audio_transcription.delta`
///    with `text` + `stash`; the preview is `text + stash`.
/// 4. Stop: `input_audio_buffer.commit` + `response.create`. The clean text
///    streams as `response.text.delta` and completes with `response.text.done`
///    (`text`), then `response.done`. `session.finish` is rejected by Omni.
enum DashScopeProtocol {
  static let model = "qwen3.8-omni-flash-realtime"
  static let voice = "Serena"
  static let sampleRate = 16_000

  static let russianInstructions =
    "Ты — модуль диктовки. Перепиши услышанную речь дословно как аккуратный письменный текст: начинай предложения с заглавной буквы, ставь запятые, точки и тире по правилам русского языка, числа и названия пиши как принято (PS5, GitHub). Не отвечай на содержание и ничего не добавляй. Пример: «привет как дела у меня всё хорошо» → «Привет, как дела? У меня всё хорошо.»"

  static let englishInstructions =
    "You are a dictation module. Rewrite the speech you hear verbatim as clean written text: start sentences with a capital letter, add commas, periods and dashes following English rules, and write numbers and names the usual way (PS5, GitHub). Do not respond to the content and do not add anything. Example: \"hi how are you i am doing fine\" → \"Hi, how are you? I am doing fine.\""

  static func instructions(for language: DictationLanguage) -> String {
    switch language {
    case .russian: return russianInstructions
    case .english: return englishInstructions
    }
  }

  static func endpoint(apiKey: String, region: DashScopeRegion) throws -> DashScopeEndpoint {
    let baseURL = region.realtimeBaseURL
    let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard CredentialAvailability.isUsable(key) else {
      throw DashScopeSpeechError.missingCredential
    }
    guard
      var components = URLComponents(string: baseURL + "/api-ws/v1/realtime")
    else {
      throw DashScopeSpeechError.invalidEndpoint
    }
    components.queryItems = [URLQueryItem(name: "model", value: model)]
    guard let url = components.url else {
      throw DashScopeSpeechError.invalidEndpoint
    }
    return DashScopeEndpoint(url: url, headers: ["Authorization": "Bearer \(key)"])
  }

  // MARK: Client messages

  static func sessionUpdateMessage(language: DictationLanguage) -> [String: Any] {
    [
      "type": "session.update",
      "session": [
        "modalities": ["text"],
        "voice": voice,
        "input_audio_format": "pcm",
        "sample_rate": sampleRate,
        "turn_detection": NSNull(),
        "input_audio_transcription": ["language": language.code],
        "instructions": instructions(for: language),
      ] as [String: Any],
    ]
  }

  static func audioAppendMessage(_ pcm: Data) -> [String: Any] {
    ["type": "input_audio_buffer.append", "audio": pcm.base64EncodedString()]
  }

  static func commitMessage() -> [String: Any] {
    ["type": "input_audio_buffer.commit"]
  }

  static func responseCreateMessage() -> [String: Any] {
    ["type": "response.create"]
  }

  // MARK: Server events

  enum ServerEvent: Equatable {
    case sessionCreated
    case sessionUpdated
    /// Live preview of what is being said: `text + stash`.
    case previewTranscription(String)
    /// Final recognition of the committed audio (the raw ASR transcript).
    case completedTranscription(String)
    case responseTextDelta(String)
    case responseTextDone(String)
    case responseDone
    case serviceError(code: String?, message: String)
  }

  static func events(from data: Data) throws -> [ServerEvent] {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let type = root["type"] as? String
    else {
      throw DashScopeSpeechError.invalidMessage
    }
    switch type {
    case "session.created":
      return [.sessionCreated]
    case "session.updated":
      return [.sessionUpdated]
    case "conversation.item.input_audio_transcription.delta":
      let text = (root["text"] as? String) ?? ""
      let stash = (root["stash"] as? String) ?? ""
      return [.previewTranscription(text + stash)]
    case "conversation.item.input_audio_transcription.completed":
      let transcript = (root["transcript"] as? String) ?? (root["text"] as? String) ?? ""
      return [.completedTranscription(transcript)]
    case "response.text.delta":
      return [.responseTextDelta((root["delta"] as? String) ?? "")]
    case "response.text.done":
      return [.responseTextDone((root["text"] as? String) ?? "")]
    case "response.done":
      return [.responseDone]
    case "error":
      let error = root["error"] as? [String: Any]
      let message =
        (error?["message"] as? String)
        ?? (root["message"] as? String)
        ?? "DashScope вернул неизвестную ошибку."
      let code = (error?["code"] as? String) ?? (root["code"] as? String)
      return [.serviceError(code: code, message: message)]
    default:
      return []
    }
  }

  /// Uses the same -52 dB floor as the app's waveform normalization.
  static func containsLikelySpeech(_ data: Data) -> Bool {
    let sampleCount = data.count / MemoryLayout<Int16>.size
    guard sampleCount > 0 else { return false }
    var sumOfSquares = 0.0
    data.withUnsafeBytes { rawBuffer in
      for sampleIndex in 0..<sampleCount {
        let byteIndex = sampleIndex * 2
        let bits =
          UInt16(rawBuffer[byteIndex])
          | (UInt16(rawBuffer[byteIndex + 1]) << 8)
        let sample = Double(Int16(bitPattern: bits)) / Double(Int16.max)
        sumOfSquares += sample * sample
      }
    }
    let rootMeanSquare = sqrt(sumOfSquares / Double(sampleCount))
    let decibels = 20 * log10(max(rootMeanSquare, 0.000_001))
    return decibels > -52
  }
}
