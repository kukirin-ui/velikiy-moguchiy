import Foundation

/// How long the microphone stays armed ("тёплым") after the last use. Chosen by
/// the user in the app's settings; the default is 15 minutes, like Wispr Flow's.
enum RelaySessionLength: String, CaseIterable, Codable, Equatable, Identifiable {
  case afterDictation
  case minutes5
  case minutes15
  case hour1
  case untilStopped

  static let defaultsKey = "configuration.relay-session-length"
  static let `default`: RelaySessionLength = .minutes15

  var id: String { rawValue }

  /// Restores a stored value; a missing or unknown one means the default.
  static func resolve(_ stored: String?) -> RelaySessionLength {
    stored.flatMap(RelaySessionLength.init(rawValue:)) ?? .default
  }

  var title: String {
    switch self {
    case .afterDictation: return "Сразу выключать"
    case .minutes5: return "5 мин"
    case .minutes15: return "15 мин"
    case .hour1: return "1 час"
    case .untilStopped: return "Пока не выключу"
    }
  }

  /// "после 15 минут простоя" and so on, for status messages.
  var idleDescription: String {
    switch self {
    case .afterDictation: return "после диктовки"
    case .minutes5: return "после 5 минут простоя"
    case .minutes15: return "после 15 минут простоя"
    case .hour1: return "после часа простоя"
    case .untilStopped: return "вручную"
    }
  }

  /// Seconds of idleness before the session ends; `nil` means never.
  var idleTimeout: TimeInterval? {
    switch self {
    case .afterDictation: return RelaySessionPolicy.afterDictationGrace
    case .minutes5: return 5 * 60
    case .minutes15: return 15 * 60
    case .hour1: return 60 * 60
    case .untilStopped: return nil
    }
  }
}

/// What restarted the idle countdown.
enum RelaySessionTrigger: Equatable {
  /// The session was just armed (app opened, "Включить" pressed).
  case armed
  /// The keyboard was shown or used for typing.
  case keyboardActivity
  /// A dictation (or its processing) just ended.
  case dictationFinished
  /// "Продлить" in the Live Activity or the app.
  case extended
}

/// Result of asking the policy for a deadline.
enum RelaySessionDeadline: Equatable {
  /// No automatic shutdown.
  case never
  /// Keep whatever deadline is running.
  case unchanged
  /// Shut down after this many seconds.
  case after(TimeInterval)
}

enum RelaySessionPolicy {
  /// "Сразу выключать": the microphone is released this long after the result
  /// was published, long enough for the keyboard to pick the text up.
  static let afterDictationGrace: TimeInterval = 3
  /// With "Сразу выключать" an armed session that nobody uses yet still needs a
  /// window for the first dictation to begin.
  static let firstUseWindow: TimeInterval = 60

  static func deadline(
    length: RelaySessionLength,
    trigger: RelaySessionTrigger
  ) -> RelaySessionDeadline {
    switch length {
    case .untilStopped:
      return .never
    case .afterDictation:
      switch trigger {
      case .armed, .extended: return .after(firstUseWindow)
      // Showing the keyboard must not stretch a shutdown that is already due.
      case .keyboardActivity: return .unchanged
      case .dictationFinished: return .after(afterDictationGrace)
      }
    case .minutes5, .minutes15, .hour1:
      return .after(length.idleTimeout ?? 0)
    }
  }

  /// A power constraint turns any setting into "right after the dictation".
  static func effectiveLength(
    configured: RelaySessionLength,
    constraint: RelayPowerConstraint?
  ) -> RelaySessionLength {
    constraint == nil ? configured : .afterDictation
  }

  /// Wall-clock check used by the poll loop next to the scheduled work item, so
  /// a throttled main queue cannot keep a due session alive.
  static func isDue(deadline: Date?, now: Date = Date()) -> Bool {
    guard let deadline else { return false }
    return now >= deadline
  }

  /// Status line the keyboard shows after the idle shutdown.
  static func idleShutdownMessage(length: RelaySessionLength) -> String {
    switch length {
    case .afterDictation:
      return "Приём выключен после диктовки. Нажмите микрофон, чтобы включить снова"
    case .untilStopped:
      return "Приём выключен. Нажмите микрофон, чтобы включить снова"
    default:
      return "Приём выключен \(length.idleDescription). Нажмите микрофон, чтобы включить снова"
    }
  }
}

// MARK: - Power

struct RelayPowerState: Equatable {
  /// 0...1, or a negative value when unknown (Simulator, monitoring off).
  var batteryLevel: Float
  var isCharging: Bool
  var isLowPowerModeEnabled: Bool

  static let unknown = RelayPowerState(
    batteryLevel: -1, isCharging: false, isLowPowerModeEnabled: false)
}

enum RelayPowerConstraint: String, Equatable {
  case lowBattery
  case lowPowerMode

  var offlineReason: RelayOfflineReason {
    self == .lowBattery ? .lowBattery : .lowPowerMode
  }

  var shutdownMessage: String {
    switch self {
    case .lowBattery:
      return "Приём выключен: заряд ниже 10 %. Нажмите микрофон — диктовка сработает один раз"
    case .lowPowerMode:
      return "Приём выключен: включён режим энергосбережения. Нажмите микрофон — диктовка сработает один раз"
    }
  }
}

enum RelayPowerPolicy {
  static let lowBatteryThreshold: Float = 0.10

  /// Why the armed microphone should not be kept on, if at all. A charging
  /// phone is never "low on battery"; Low Power Mode only counts when the user
  /// left "Выключать в режиме энергосбережения" on.
  static func constraint(
    state: RelayPowerState,
    stopInLowPowerMode: Bool
  ) -> RelayPowerConstraint? {
    if state.batteryLevel >= 0, state.batteryLevel < lowBatteryThreshold, !state.isCharging {
      return .lowBattery
    }
    if stopInLowPowerMode, state.isLowPowerModeEnabled { return .lowPowerMode }
    return nil
  }

  /// A constraint ends an idle session at once, but never a dictation that is
  /// running or about to start (a pending keyboard handoff).
  static func shouldStopNow(
    constraint: RelayPowerConstraint?,
    operationIsBusy: Bool,
    hasPendingHandoff: Bool
  ) -> Bool {
    constraint != nil && !operationIsBusy && !hasPendingHandoff
  }
}
