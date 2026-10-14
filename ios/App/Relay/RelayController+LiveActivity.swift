import Foundation

extension RelayController {
  var liveActivityState: VelikiyMoguchiyRelayAttributes.ContentState {
    let phase: VelikiyMoguchiyRelayAttributes.ContentState.Phase
    switch status {
    case .recording: phase = .listening
    case .transcribing: phase = .transcribing
    case .error where isAudioPaused: phase = .paused
    case .error, .idle: phase = audioNeedsApp ? .needsApp : .ready
    case .offline: phase = audioNeedsApp ? .needsApp : .ready
    }
    return VelikiyMoguchiyRelayAttributes.ContentState(
      phase: phase,
      shutdownDate: idleShutdownDeadline,
      canExtend: isRelayRunning
        && configuration.relaySessionLength != .untilStopped
        && idleShutdownDeadline != nil
    )
  }

  func syncLiveActivity() {
    guard isRelayRunning || audioNeedsApp else { return }
    liveActivity.update(state: liveActivityState)
  }

  /// "Стоп" and "Продлить" on the Live Activity run in this process.
  func configureLiveActivityControls() {
    let control = RelayLiveActivityControl.shared
    control.stop = { [weak self] in
      self?.stopRelay(
        message: "Приём выключен кнопкой «Стоп». Нажмите микрофон, чтобы включить снова",
        offlineReason: .stopped
      )
    }
    control.extend = { [weak self] in self?.extendSession() }
  }
}
