import AVFoundation
import Foundation

/// Decides what the audio layer does after an interruption, a route change or a
/// dead engine. Pure, so the rules that keep the microphone alive in the
/// background can be tested without audio hardware.
///
/// The central rule: once the
/// session has been deactivated, a background process usually cannot activate a
/// recording session again. So nothing here deactivates the session. An
/// interruption pauses the engine; its end, a route change or a configuration
/// change only restarts the engine on the still-active session. When even that
/// fails the machine gives up with `needsApp`, and the keyboard asks the user to
/// press the microphone, which opens the app and rebuilds everything in the
/// foreground.
struct AudioRecoveryMachine: Equatable {
  enum Phase: Equatable {
    case running
    /// An interruption began and its end has not been seen.
    case interrupted
    case recovering(attempt: Int, limit: Int)
    /// iOS would not let a background process resume; the app must come forward.
    case needsApp
  }

  enum InterruptionReason: Equatable {
    case normal
    /// "App was suspended" interruptions are not a real loss of the microphone.
    case appWasSuspended
    case other
  }

  enum Event: Equatable {
    case interruptionBegan(InterruptionReason)
    case interruptionEnded(shouldResume: Bool)
    /// New or lost input/output device (AirPods, CarPlay, wired headset).
    case routeChanged
    case engineConfigurationChanged
    case mediaServicesReset
    /// No audio buffer arrived for too long although the engine claims to run.
    case engineStalled
    /// Buffers flow again after a restart.
    case buffersFlowing
    case restartSucceeded
    case restartFailed
    case appBecameActive
    /// A fresh `start()` brought the engine up.
    case started
  }

  enum Action: Equatable {
    case none
    /// Stop the engine and the active segment, keep the session active.
    case pauseEngine
    /// Rebuild engine and tap on the active session (no deactivation).
    case restartInPlace
    /// `setActive(true)` (never preceded by `setActive(false)`), then restart.
    case resumeAfterInterruption(attempt: Int)
    /// Full re-setup including category and activation. Foreground or after a
    /// media-services reset only.
    case rebuildSession
    case reportNeedsApp
  }

  static let maximumResumeAttempts = 3
  /// A stalled engine gets this many in-place restarts before giving up.
  static let maximumStallRestarts = 2
  static let retryDelay: TimeInterval = 1
  static let firstResumeDelay: TimeInterval = 0.35

  private(set) var phase: Phase = .running
  private(set) var stallRestarts = 0

  var needsApp: Bool { phase == .needsApp }

  mutating func handle(_ event: Event) -> Action {
    switch (phase, event) {
    case (_, .started):
      phase = .running
      stallRestarts = 0
      return .none
    // The session objects are gone: only a full rebuild helps, in any phase.
    case (_, .mediaServicesReset):
      phase = .recovering(attempt: 1, limit: 1)
      return .rebuildSession

    // MARK: running
    case (.running, .interruptionBegan(let reason)):
      guard reason != .appWasSuspended else { return .none }
      phase = .interrupted
      return .pauseEngine
    case (.running, .routeChanged), (.running, .engineConfigurationChanged):
      return .restartInPlace
    case (.running, .engineStalled):
      guard stallRestarts < Self.maximumStallRestarts else {
        phase = .needsApp
        return .reportNeedsApp
      }
      stallRestarts += 1
      return .restartInPlace
    case (.running, .buffersFlowing):
      stallRestarts = 0
      return .none
    case (.running, .restartSucceeded):
      return .none
    case (.running, .restartFailed):
      // A route that is still settling can fail once; try again before giving up.
      phase = .recovering(attempt: 2, limit: Self.maximumResumeAttempts)
      return .resumeAfterInterruption(attempt: 2)
    case (.running, .interruptionEnded), (.running, .appBecameActive):
      return .none

    // MARK: interrupted
    case (.interrupted, .interruptionBegan):
      return .none
    case (.interrupted, .interruptionEnded(let shouldResume)):
      // Without the "should resume" hint one polite attempt, with it three.
      let limit = shouldResume ? Self.maximumResumeAttempts : 1
      phase = .recovering(attempt: 1, limit: limit)
      return .resumeAfterInterruption(attempt: 1)
    case (.interrupted, .appBecameActive):
      // The end notification can be missing; in the foreground resuming is allowed.
      phase = .recovering(attempt: 1, limit: 1)
      return .rebuildSession
    case (.interrupted, _):
      return .none

    // MARK: recovering
    case (.recovering, .restartSucceeded):
      phase = .running
      stallRestarts = 0
      return .none
    case (.recovering(let attempt, let limit), .restartFailed):
      if attempt < limit {
        phase = .recovering(attempt: attempt + 1, limit: limit)
        return .resumeAfterInterruption(attempt: attempt + 1)
      }
      phase = .needsApp
      return .reportNeedsApp
    case (.recovering, .interruptionBegan(let reason)):
      guard reason != .appWasSuspended else { return .none }
      phase = .interrupted
      return .pauseEngine
    case (.recovering, .appBecameActive):
      phase = .recovering(attempt: 1, limit: 1)
      return .rebuildSession
    case (.recovering, _):
      return .none

    // MARK: needsApp
    case (.needsApp, .appBecameActive):
      phase = .recovering(attempt: 1, limit: 1)
      return .rebuildSession
    case (.needsApp, _):
      return .none
    }
  }

  // MARK: Notification parsing

  static func interruptionEvent(from userInfo: [AnyHashable: Any]?) -> Event? {
    guard let rawType = userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: rawType)
    else { return nil }
    switch type {
    case .began:
      return .interruptionBegan(reason(from: userInfo))
    case .ended:
      let rawOptions = userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
      let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
      return .interruptionEnded(shouldResume: options.contains(.shouldResume))
    @unknown default:
      return nil
    }
  }

  private static func reason(from userInfo: [AnyHashable: Any]?) -> InterruptionReason {
    // Raw values: 0 default, 1 appWasSuspended (deprecated name), 2 builtInMicMuted, ...
    guard let raw = userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt else { return .normal }
    switch raw {
    case 0: return .normal
    case 1: return .appWasSuspended
    default: return .other
    }
  }

  /// Route changes that call for an engine restart. Everything else
  /// (category change, wake from sleep, "no suitable route") must not.
  static func routeChangeEvent(from userInfo: [AnyHashable: Any]?) -> Event? {
    guard let raw = userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
      let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
    else { return nil }
    switch reason {
    case .newDeviceAvailable, .oldDeviceUnavailable, .override, .routeConfigurationChange:
      return .routeChanged
    default:
      return nil
    }
  }
}

/// What the audio layer reports to the relay.
enum AudioCaptureEvent {
  /// The engine runs again after an interruption or a route change.
  case recovered(String)
  /// An interruption (call, Siri, another app) paused the engine. The session
  /// stays active and the relay stays armed.
  case paused(String)
  /// iOS would not let the background process resume; open the app.
  case needsApp(Error?)
  /// A hard failure.
  case failed(Error)
}
