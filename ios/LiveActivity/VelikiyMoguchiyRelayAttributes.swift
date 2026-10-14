import ActivityKit
import Foundation

/// Live Activity of an armed microphone: shows that the session is on and when
/// it switches itself off. Shared by the app (which starts and updates it) and
/// the widget extension (which draws it).
struct VelikiyMoguchiyRelayAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    enum Phase: String, Codable, Hashable {
      case ready
      case listening
      case transcribing
      /// A call, Siri or another app holds the microphone; resumes by itself.
      case paused
      /// iOS would not give the microphone back to the background process.
      case needsApp
    }

    var phase: Phase
    /// When the session ends by itself; `nil` for "Пока не выключу" and while busy.
    var shutdownDate: Date?
    /// "Продлить" makes sense only with a countdown running.
    var canExtend: Bool
  }

  var title = "Великий & Могучий"
}

extension VelikiyMoguchiyRelayAttributes.ContentState {
  var title: String {
    switch phase {
    case .ready: return "Микрофон включён"
    case .listening: return "Слушаю…"
    case .transcribing: return "Распознаю…"
    case .paused: return "Пауза: микрофон занят"
    case .needsApp: return "Откройте «Великий & Могучий»"
    }
  }

  var symbolName: String {
    switch phase {
    case .ready: return "mic.fill"
    case .listening: return "waveform"
    case .transcribing: return "ellipsis"
    case .paused: return "pause.circle.fill"
    case .needsApp: return "exclamationmark.circle.fill"
    }
  }
}
