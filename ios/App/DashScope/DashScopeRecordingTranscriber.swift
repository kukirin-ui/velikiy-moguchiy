import AVFoundation
import Foundation

/// Replays a saved WAV recording through the same realtime protocol. This is
/// the fallback after a failed live stream and the path for "retry saved
/// recording" in the app, so there is no separate batch API to maintain.
struct DashScopeRecordingTranscriber: Sendable {
  var socketFactory: DashScopeRealtimeSession.SocketFactory = { endpoint in
    URLSessionDashScopeSocket(endpoint: endpoint)
  }

  func transcribe(
    recordingAt url: URL,
    language: DictationLanguage,
    apiKey: String,
    region: DashScopeRegion
  ) async throws -> String {
    let chunks = try await Task.detached(priority: .userInitiated) {
      try WAVPCMConverter.pcm16kChunks(from: url)
    }.value
    guard !chunks.isEmpty else { throw DashScopeSpeechError.noSpeech }

    let session = DashScopeRealtimeSession(language: language, socketFactory: socketFactory)
    do {
      try await session.connect(apiKey: apiKey, region: region)
      for chunk in chunks {
        try Task.checkCancellation()
        try await session.sendPCM(chunk)
      }
      return try await session.finish()
    } catch {
      await session.cancel()
      throw error
    }
  }
}

/// Converts a recorded WAV (microphone-native format) to the 16 kHz mono
/// Int16 PCM the realtime API expects, in ~100 ms chunks.
enum WAVPCMConverter {
  static func pcm16kChunks(from url: URL) throws -> [Data] {
    let file = try AVAudioFile(forReading: url)
    let inputFormat = file.processingFormat
    guard
      let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: Double(DashScopeProtocol.sampleRate),
        channels: 1,
        interleaved: true
      ),
      let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
    else {
      throw AudioCaptureError.invalidInputFormat
    }

    var chunker = PCM16StreamChunker()
    var chunks: [Data] = []
    let inputCapacity: AVAudioFrameCount = 8_192
    let ratio = outputFormat.sampleRate / inputFormat.sampleRate
    let outputCapacity = AVAudioFrameCount(Double(inputCapacity) * ratio) + 1_024

    while file.framePosition < file.length {
      guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputCapacity)
      else { throw AudioCaptureError.invalidInputFormat }
      try file.read(into: input, frameCount: inputCapacity)
      guard input.frameLength > 0 else { break }

      guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity)
      else { throw AudioCaptureError.invalidInputFormat }
      var supplied = false
      var conversionError: NSError?
      let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
        if supplied {
          inputStatus.pointee = .noDataNow
          return nil
        }
        supplied = true
        inputStatus.pointee = .haveData
        return input
      }
      if status == .error {
        throw conversionError ?? AudioCaptureError.invalidInputFormat
      }
      if let data = pcmData(from: output), !data.isEmpty {
        chunks.append(contentsOf: chunker.append(data))
      }
    }
    if let tail = chunker.finish() { chunks.append(tail) }
    return chunks
  }

  private static func pcmData(from buffer: AVAudioPCMBuffer) -> Data? {
    guard buffer.frameLength > 0,
      let channel = buffer.int16ChannelData
    else { return nil }
    return Data(bytes: channel[0], count: Int(buffer.frameLength) * MemoryLayout<Int16>.size)
  }
}
