import Foundation

struct PCM16StreamChunker {
  static let bytesPerFrame = 2
  static let targetFramesPerChunk = 1_600
  static let targetBytesPerChunk = bytesPerFrame * targetFramesPerChunk

  private(set) var bufferedData = Data()

  mutating func append(_ data: Data) -> [Data] {
    guard !data.isEmpty else { return [] }
    bufferedData.append(data)

    var chunks: [Data] = []
    while bufferedData.count >= Self.targetBytesPerChunk {
      chunks.append(Data(bufferedData.prefix(Self.targetBytesPerChunk)))
      bufferedData.removeFirst(Self.targetBytesPerChunk)
    }
    return chunks
  }

  mutating func finish() -> Data? {
    guard !bufferedData.isEmpty else { return nil }
    let finalChunk = bufferedData
    bufferedData.removeAll(keepingCapacity: true)
    return finalChunk
  }

  mutating func reset() {
    bufferedData.removeAll(keepingCapacity: true)
  }
}

struct RecoverableRecordingScanGate {
  private(set) var hasRun = false

  mutating func claim() -> Bool {
    guard !hasRun else { return false }
    hasRun = true
    return true
  }
}

enum AudioCaptureError: LocalizedError {
  case sharedContainerUnavailable
  case invalidInputFormat
  case relayNotRunning
  case alreadyRecording
  case notRecording
  case simulatorMicrophoneUnavailable
  case writeFailed(String)
  case sessionUnavailable(String)
  case secureStorageUnavailable(String)
  /// iOS would not let a background process resume the microphone.
  case needsApp

  var errorDescription: String? {
    switch self {
    case .sharedContainerUnavailable:
      return "Общая папка приложения и клавиатуры недоступна. Переподпишите приложение вместе с клавиатурами: им нужна общая группа App Group."
    case .invalidInputFormat:
      return "Микрофон вернул неподдерживаемый формат звука."
    case .relayNotRunning:
      return "Сначала включите приём (микрофон не готов)."
    case .alreadyRecording:
      return "Диктовка уже идёт."
    case .notRecording:
      return "Нет активной диктовки, которую можно остановить."
    case .simulatorMicrophoneUnavailable:
      return
        "Для записи с микрофона нужен настоящий iPhone: в симуляторе доступны только настройки."
    case .writeFailed(let message):
      return "Не удалось записать звук: \(message)"
    case .sessionUnavailable(let details):
      return "Не удалось запустить микрофон. \(details)"
    case .needsApp:
      return "Нажмите микрофон, чтобы включить снова"
    case .secureStorageUnavailable(let details):
      return "Защищённое хранилище записей недоступно. \(details)"
    }
  }
}

struct CapturedAudioSegment {
  let requestID: String
  let url: URL
  let startedAt: Date
  let endedAt: Date
  var languageCode: String = DictationLanguage.defaultLanguage.code

  var duration: TimeInterval {
    endedAt.timeIntervalSince(startedAt)
  }
}

/// The containing app owns this engine because Apple forbids microphone access
/// from custom keyboard extensions. The engine stays active while the relay is on,
/// allowing the app's declared audio background mode to receive keyboard commands.
