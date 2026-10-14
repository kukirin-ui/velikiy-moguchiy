import AVFoundation
import Combine
import Foundation
import UIKit

extension RelayController {
  static let busyPollInterval: DispatchTimeInterval = .milliseconds(200)
  /// While armed and idle the keyboard's Darwin notifications do the waking;
  /// this loop is only a safety net, the heartbeat and the wall-clock deadline.
  static let idlePollInterval: DispatchTimeInterval = .seconds(1)

  func beginPolling() {
    let interval = desiredPollInterval
    currentPollInterval = interval
    let timer = DispatchSource.makeTimerSource(queue: pollingQueue)
    timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(80))
    timer.setEventHandler { [weak self] in
      Task { @MainActor [weak self] in
        self?.pollRelayStore()
      }
    }
    pollTimer = timer
    timer.resume()
  }

  /// 200 ms while something is happening (a dictation, a handoff), 1 s while
  /// the microphone just waits.
  var desiredPollInterval: DispatchTimeInterval {
    let isBusy =
      status.isBusy
      || activeRequestID != nil
      || pendingLaunchRequest != nil
      || isKeyboardHandoffActive
      || isRelayStarting
      || retryingRecordingID != nil
    return isBusy ? Self.busyPollInterval : Self.idlePollInterval
  }

  func updatePollIntervalIfNeeded() {
    let desired = desiredPollInterval
    guard desired != currentPollInterval, let pollTimer else { return }
    currentPollInterval = desired
    pollTimer.schedule(deadline: .now() + desired, repeating: desired, leeway: .milliseconds(80))
  }

  func markRelayActivityAndSuspendIdleShutdown() {
    idleShutdownWorkItem?.cancel()
    idleShutdownWorkItem = nil
    idleShutdownDeadline = nil
    syncLiveActivity()
  }

  /// A dictation (or its processing) ended: restart the countdown. After an
  /// error the keyboard still has to show the message, so "Сразу выключать"
  /// does not apply to it.
  func markRelayActivityAndScheduleIdleShutdown() {
    markRelayActivityAndSuspendIdleShutdown()
    scheduleIdleShutdownIfEligible(
      trigger: status == .error ? .armed : .dictationFinished)
  }

  var currentPowerConstraint: RelayPowerConstraint? {
    RelayPowerPolicy.constraint(
      state: powerStateProvider(),
      stopInLowPowerMode: configuration.stopInLowPowerMode
    )
  }

  func scheduleIdleShutdownIfEligible(trigger: RelaySessionTrigger = .armed) {
    let previousDeadline = idleShutdownDeadline
    idleShutdownWorkItem?.cancel()
    idleShutdownWorkItem = nil
    idleShutdownDeadline = nil
    let operationIsBusy =
      status.isBusy
      || activeRequestID != nil
      || retryingRecordingID != nil
    guard
      RelayIdleShutdownPolicy.canStop(
        relayIsRunning: isRelayRunning,
        operationIsBusy: operationIsBusy,
        hasPendingHandoff: pendingLaunchRequest != nil
          || store.pendingLaunchRequest() != nil,
        hasPendingCommand: false
      )
    else {
      syncLiveActivity()
      return
    }

    let length = RelaySessionPolicy.effectiveLength(
      configured: configuration.relaySessionLength,
      constraint: currentPowerConstraint
    )
    let interval: TimeInterval
    switch RelaySessionPolicy.deadline(length: length, trigger: trigger) {
    case .never:
      syncLiveActivity()
      return
    case .unchanged:
      guard let previousDeadline else {
        syncLiveActivity()
        return
      }
      interval = max(0, previousDeadline.timeIntervalSinceNow)
    case .after(let seconds):
      interval = seconds
    }

    let workItem = DispatchWorkItem { [weak self] in
      Task { @MainActor [weak self] in
        self?.idleShutdownDeadlineReached()
      }
    }
    idleShutdownWorkItem = workItem
    idleShutdownDeadline = Date().addingTimeInterval(interval)
    DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: workItem)
    syncLiveActivity()
  }

  /// The keyboard was shown or used: the countdown restarts from now.
  func keyboardActivityObserved(at date: Date) {
    guard isRelayRunning else { return }
    scheduleIdleShutdownIfEligible(trigger: .keyboardActivity)
    lastKeyboardSeenHandled = date
  }

  func pollKeyboardActivity() {
    guard let seen = store.keyboardLastSeen,
      seen != lastKeyboardSeenHandled
    else { return }
    keyboardActivityObserved(at: seen)
  }

  /// "Продлить": restart the countdown from now (a no-op for "Пока не выключу").
  func extendSession() {
    guard isRelayRunning else { return }
    scheduleIdleShutdownIfEligible(trigger: .extended)
  }

  func idleShutdownDeadlineReached() {
    idleShutdownWorkItem?.cancel()
    idleShutdownWorkItem = nil
    idleShutdownDeadline = nil
    let operationIsBusy =
      status.isBusy
      || activeRequestID != nil
      || retryingRecordingID != nil
    let hasPendingCommand = store.pendingCommand(after: lastHandledSequence) != nil
    if hasPendingCommand {
      let recheck = DispatchWorkItem { [weak self] in
        Task { @MainActor [weak self] in
          self?.idleShutdownDeadlineReached()
        }
      }
      idleShutdownWorkItem = recheck
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: recheck)
      return
    }
    guard
      RelayIdleShutdownPolicy.canStop(
        relayIsRunning: isRelayRunning,
        operationIsBusy: operationIsBusy,
        hasPendingHandoff: pendingLaunchRequest != nil
          || store.pendingLaunchRequest() != nil,
        hasPendingCommand: false
      )
    else { return }
    if let constraint = currentPowerConstraint {
      stopRelay(message: constraint.shutdownMessage, offlineReason: constraint.offlineReason)
    } else {
      stopRelay(
        message: RelaySessionPolicy.idleShutdownMessage(length: configuration.relaySessionLength),
        offlineReason: .idleTimeout
      )
    }
  }

  /// Battery below 10 % or Low Power Mode changed: end an idle session at once,
  /// shorten the countdown while busy.
  func evaluatePowerConstraint() {
    guard isRelayRunning else { return }
    let constraint = currentPowerConstraint
    let operationIsBusy =
      status.isBusy
      || activeRequestID != nil
      || retryingRecordingID != nil
    let hasPendingHandoff = pendingLaunchRequest != nil || store.pendingLaunchRequest() != nil
    if let constraint,
      RelayPowerPolicy.shouldStopNow(
        constraint: constraint,
        operationIsBusy: operationIsBusy,
        hasPendingHandoff: hasPendingHandoff
      )
    {
      stopRelay(message: constraint.shutdownMessage, offlineReason: constraint.offlineReason)
    } else {
      // Re-evaluate the countdown with the (possibly shorter) effective length.
      scheduleIdleShutdownIfEligible(trigger: constraint == nil ? .armed : .dictationFinished)
    }
  }

  func pollRelayStore() {
    pollTickCount += 1
    let now = Date()
    if now.timeIntervalSince(lastHeartbeatAt) >= RelaySnapshot.heartbeatInterval {
      lastHeartbeatAt = now
      store.touchHeartbeat(now)
    }
    capture.checkLiveness()
    pollKeyboardActivity()
    if RelaySessionPolicy.isDue(deadline: idleShutdownDeadline, now: now) {
      idleShutdownDeadlineReached()
      if !isRelayRunning { return }
    }
    if pollTickCount % 30 == 0 { evaluatePowerConstraint() }
    updatePollIntervalIfNeeded()

    guard let command = store.pendingCommand(after: lastHandledSequence) else {
      // A cold launch can arrive while an earlier request is finishing.
      // Once that work publishes idle, arm the return without requiring
      // another scene activation.
      preparePendingLaunchHandoffIfNeeded()
      return
    }

    lastHandledSequence = command.sequence
    store.markCommandHandled(sequence: command.sequence)
    handle(command)
  }

  func handle(_ envelope: RelayCommandEnvelope) {
    guard isRelayRunning else { return }
    let commandAge = Date().timeIntervalSince(envelope.createdAt)
    guard commandAge >= 0, commandAge <= 10 else { return }

    switch envelope.command {
    case .start:
      beginDictationFromKeyboardCommand(envelope)
    case .stop:
      guard activeRequestID == envelope.requestID else { return }
      scheduleFinishDictation(requestID: envelope.requestID)
    case .cancel:
      if activeRequestID == envelope.requestID {
        cancelDictation()
      } else if processingRequestID == envelope.requestID {
        cancelTranscription(requestID: envelope.requestID)
      } else if pendingLaunchRequest?.requestID == envelope.requestID
        || store.pendingLaunchRequest()?.requestID == envelope.requestID
      {
        discardPendingLaunchRequest()
        publish(.idle, message: "Готово — переключитесь на клавиатуру «Великий & Могучий»")
      }
    }
  }

  func preparePendingLaunchHandoffIfNeeded() {
    guard let request = pendingLaunchRequest else { return }
    guard isRelayRunning,
      status == .idle,
      activeRequestID == nil
    else {
      return
    }
    let age = Date().timeIntervalSince(request.createdAt)
    guard age >= 0,
      age <= RelayLaunchRequest.defaultMaximumAge
    else {
      discardPendingLaunchRequest()
      return
    }
    guard store.pendingLaunchRequest() == request else {
      pendingLaunchRequest = nil
      isKeyboardHandoffActive = false
      requiresManualKeyboardReturn = false
      return
    }
    isKeyboardHandoffActive = true
    // Once the bounded automatic return has been exhausted for this request,
    // the manual swipe-back guidance must stay on screen. Re-arming here on
    // every poll would clear that flag within 200 ms and loop the private
    // return attempts until the request expires. A later scene activation or
    // a new deep link resets the flag and gets a fresh bounded attempt.
    guard !requiresManualKeyboardReturn else { return }
    scheduleAutomaticReturnToKeyboard(
      requestID: request.requestID,
      originatingApplicationBundleIdentifier:
        request.originatingApplicationBundleIdentifier,
      delay: 0.35
    )
  }

  func recoverIdleStateForPendingLaunchIfNeeded() {
    guard pendingLaunchRequest != nil,
      isRelayRunning,
      activeRequestID == nil,
      status == .error
    else {
      return
    }

    // A failed prior request may leave an otherwise healthy warm
    // microphone relay displaying an error. A newly authorized keyboard
    // handoff is a fresh request, so make the relay available again before
    // scheduling the return.
    publish(.idle, message: "Готово — возврат к клавиатуре «Великий & Могучий»")
  }
}
