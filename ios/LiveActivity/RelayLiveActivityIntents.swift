import ActivityKit
import AppIntents
import Foundation

/// Bridge between the Live Activity buttons and the running relay. A
/// `LiveActivityIntent` executes in the app's process, where `RelayController`
/// installs these handlers; in the widget extension they stay `nil`.
@MainActor
final class RelayLiveActivityControl {
  static let shared = RelayLiveActivityControl()

  var stop: (() -> Void)?
  var extend: (() -> Void)?

  /// Fallback when no relay is alive: an orphaned activity must not linger.
  static func endAllActivities() async {
    for activity in Activity<VelikiyMoguchiyRelayAttributes>.activities {
      await activity.end(nil, dismissalPolicy: .immediate)
    }
  }
}

struct StopRelayIntent: LiveActivityIntent {
  static let title: LocalizedStringResource = "Выключить микрофон"
  static let description = IntentDescription("Выключает приём голоса «Великого & Могучего».")

  @MainActor
  func perform() async throws -> some IntentResult {
    if let stop = RelayLiveActivityControl.shared.stop {
      stop()
    } else {
      await RelayLiveActivityControl.endAllActivities()
    }
    return .result()
  }
}

struct ExtendRelayIntent: LiveActivityIntent {
  static let title: LocalizedStringResource = "Продлить микрофон"
  static let description = IntentDescription("Откладывает автоматическое выключение микрофона.")

  @MainActor
  func perform() async throws -> some IntentResult {
    RelayLiveActivityControl.shared.extend?()
    return .result()
  }
}
