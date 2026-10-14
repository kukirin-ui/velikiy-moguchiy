import CryptoKit
import Darwin
import UIKit

extension KeyboardViewController {
  func refreshFromSharedState() {
    defer {
      updateActionVisibility()
      updatePollingCadenceIfNeeded()
    }
    if mode == .openingHost {
      let trackedAge =
        trackedRequestCreatedAt.map {
          Date().timeIntervalSince($0)
        } ?? .infinity
      if trackedAge > RelayLaunchRequest.defaultMaximumAge {
        if let activeRequestID {
          store.clearLaunchAuthorization(for: activeRequestID)
        }
        clearTrackedRequest()
        mode = .idle
        hostLaunchFailureExpiresAt = Date().addingTimeInterval(8)
      }
    }

    let snapshot = store.snapshot()
    observeResult(in: snapshot)
    pickUpFallbackResultIfNeeded(snapshot)
    reconcileDictationState(with: snapshot)
    issueDeferredStartIfReady(with: snapshot)
    updateActionVisibility()
    updateCancelAccessibility()
    updateRecordingPresentation(with: snapshot)
    updateProcessingPresentation(with: snapshot)

    if mode == .recording, let startedAt = snapshot.recordingStartedAt {
      let elapsed = max(0, Int(Date().timeIntervalSince(startedAt)))
      timerLabel.text = String(format: "%d:%02d", elapsed / 60, elapsed % 60)
      timerLabel.isHidden = false
    } else {
      timerLabel.isHidden = true
    }

    guard hasFullAccess else {
      setStatus(
        "Включите «Разрешить полный доступ» в настройках", color: .systemOrange, isAdvice: true)
      microphoneButton.isEnabled = true
      cancelButton.isEnabled = false
      return
    }

    guard keyboardHasUsableAPIKey,
      snapshot.offlineReason != .missingAPIKey
    else {
      presentMissingCredential()
      return
    }

    guard snapshot.hostIsOnline(), snapshot.status != .offline else {
      if mode == .openingHost {
        if let activeRequestID,
          let activeDictationAction,
          let trackedRequestCreatedAt,
          hostLaunchAttemptedForRequestID != activeRequestID
        {
          resolveHostAndOpenContainingApp(
            requestID: activeRequestID,
            dictationAction: activeDictationAction,
            createdAt: trackedRequestCreatedAt
          )
        }
        let launchFailed = hostLaunchFailureExpiresAt.map { $0 > Date() } ?? false
        let unavailableMessage =
          snapshot.offlineReason == .unavailable
          ? snapshot.message
          : nil
        setStatus(
          unavailableMessage.map { "\($0) — × отменяет" }
            ?? (launchFailed
              ? "Откройте «Великий & Могучий» вручную — × отменяет"
              : "Открываю «Великий & Могучий» — × отменяет"),
          color: unavailableMessage != nil || launchFailed ? .systemOrange : .systemBlue
        )
        configureMicrophone(.opening)
        microphoneButton.isEnabled = false
        cancelButton.isEnabled = true
      } else {
        let launchFailed = hostLaunchFailureExpiresAt.map { $0 > Date() } ?? false
        // Every reason the app switched itself off carries its own explanation
        // (timeout, battery, Low Power Mode, a call took the microphone ...).
        let unavailableMessage: String?
        switch snapshot.offlineReason {
        case .unavailable?, .idleTimeout?, .lowBattery?, .lowPowerMode?, .needsApp?, .stopped?:
          unavailableMessage = snapshot.message
        case .missingAPIKey?, nil:
          unavailableMessage = nil
        }
        setStatus(
          unavailableMessage
            ?? (launchFailed
              ? "iOS не дала переключиться — откройте «Великий & Могучий» вручную"
              : "Приём выключен. Нажмите микрофон, чтобы открыть «Великий & Могучий» и включить снова"),
          color: .systemOrange,
          isAdvice: !launchFailed
        )
        configureMicrophone(.openAndDictate)
        microphoneButton.isEnabled = true
        cancelButton.isEnabled = false
      }
      return
    }

    switch mode {
    case .openingHost:
      setStatus("Запускаю диктовку — × отменяет", color: .systemBlue)
      configureMicrophone(.starting)
      microphoneButton.isEnabled = false
      cancelButton.isEnabled = true
    case .recording:
      let livePreview =
        snapshot.activeRequestID == activeRequestID
          && RelayRecordingMessage.isShownWhileRecording(snapshot.message)
        ? snapshot.message
        : nil
      setStatus(livePreview ?? "Слушаю… микрофон вставляет текст, × отменяет", color: .systemRed)
      configureMicrophone(.finish)
      microphoneButton.isEnabled = true
      cancelButton.isEnabled = true
    case .cancelling:
      setStatus("Останавливаю и отбрасываю результат", color: .systemOrange)
      configureMicrophone(.dictate)
      microphoneButton.isEnabled = false
      cancelButton.isEnabled = false
    case .transcribing:
      if snapshot.status == .error {
        cancelButton.isEnabled = false
        mode = .idle
        clearTrackedRequest()
        // The failure of the dictation just made: keep it up for a while.
        revealAdvice(for: 6)
        setStatus(snapshot.message, color: .systemOrange)
        configureMicrophone(.tryAgain)
        microphoneButton.isEnabled = true
      } else {
        cancelButton.isEnabled = true
        setStatus(snapshot.message, color: .systemBlue)
        configureMicrophone(.transcribing)
        microphoneButton.isEnabled = false
      }
    case .resultWaiting:
      setStatus("Поле ввода изменилось — нажмите «Вставить»", color: .systemBlue)
      configureMicrophone(.dictate)
      microphoneButton.isEnabled = true
      cancelButton.isEnabled = false
    case .idle:
      setStatus(
        snapshot.status == .error ? snapshot.message : "",
        color: snapshot.status == .error ? .systemOrange : .systemBlue,
        isAdvice: true)
      configureMicrophone(.dictate)
      microphoneButton.isEnabled = true
      cancelButton.isEnabled = false
    }
  }

  func issueDeferredStartIfReady(with snapshot: RelaySnapshot) {
    guard keyboardHasUsableAPIKey,
      snapshot.offlineReason != .missingAPIKey,
      keyboardReactivationIsReady,
      let activeRequestID,
      let activeDictationAction,
      let trackedRequestCreatedAt
    else {
      return
    }

    let pendingLaunchRequest = store.pendingLaunchRequest()
    guard
      RelayKeyboardStartGate.canIssueStart(
        requestID: activeRequestID,
        action: activeDictationAction,
        createdAt: trackedRequestCreatedAt,
        pendingLaunchRequest: pendingLaunchRequest,
        snapshot: snapshot,
        keyboardIsVisible: keyboardIsVisible,
        keyboardIsAttached: view.window != nil,
        startAlreadyIssued: !awaitsKeyboardReactivation
      )
    else {
      return
    }

    // The controller or UITextDocumentProxy can be recreated while the
    // containing app is foreground. Capture the insertion anchor only after
    // this returned keyboard is attached to the active text field.
    activeDocumentIdentifier = textDocumentProxy.documentIdentifier
    contextBeforeFingerprintAtRequest = Self.contextFingerprint(
      textDocumentProxy.documentContextBeforeInput
    )
    contextAfterFingerprintAtRequest = Self.contextFingerprint(
      textDocumentProxy.documentContextAfterInput
    )
    persistTrackedRequest()

    store.issue(
      .start,
      requestID: activeRequestID,
      dictationAction: activeDictationAction,
      language: Self.dictationLanguage
    )
    awaitsKeyboardReactivation = false
    keyboardReactivationIsReady = false
    persistTrackedRequest()
  }

  func reconcileDictationState(with snapshot: RelaySnapshot) {
    guard snapshot.hostIsOnline(), snapshot.status != .offline else {
      let failureIsForTrackedRequest =
        mode == .openingHost
        && snapshot.status == .offline
        && snapshot.offlineReason == .unavailable
        && snapshot.heartbeat.map { heartbeat in
          trackedRequestCreatedAt.map { heartbeat >= $0 } ?? false
        } == true
      if failureIsForTrackedRequest {
        if let activeRequestID {
          store.clearLaunchAuthorization(for: activeRequestID)
        }
        clearTrackedRequest()
        mode = .idle
      }
      if mode == .recording || mode == .cancelling || mode == .transcribing {
        mode = .idle
        clearTrackedRequest()
      }
      return
    }

    switch snapshot.status {
    case .recording:
      guard let relayRequestID = snapshot.activeRequestID else { return }
      if mode == .openingHost,
        let activeRequestID,
        activeRequestID != relayRequestID
      {
        return
      }
      if mode == .cancelling, activeRequestID == relayRequestID {
        return
      }
      if mode == .transcribing, activeRequestID == relayRequestID {
        // A stop command is in flight; wait for the host to acknowledge
        // `.transcribing` instead of re-enabling Finish.
        return
      }
      if activeRequestID != relayRequestID {
        activeRequestID = relayRequestID
        activeDocumentIdentifier = textDocumentProxy.documentIdentifier
        contextBeforeFingerprintAtRequest = Self.contextFingerprint(
          textDocumentProxy.documentContextBeforeInput
        )
        contextAfterFingerprintAtRequest = Self.contextFingerprint(
          textDocumentProxy.documentContextAfterInput
        )
      }
      activeDictationAction = snapshot.activeDictationAction ?? .transcribe
      store.clearLaunchAuthorization(for: relayRequestID)
      persistTrackedRequest()
      mode = .recording
    case .transcribing:
      guard let relayRequestID = snapshot.activeRequestID else { return }
      if mode == .openingHost,
        let activeRequestID,
        activeRequestID != relayRequestID
      {
        return
      }
      if mode == .cancelling, activeRequestID == relayRequestID {
        return
      }
      activeRequestID = relayRequestID
      activeDictationAction = snapshot.activeDictationAction ?? activeDictationAction
      persistTrackedRequest()
      mode = .transcribing
    case .idle:
      if mode == .openingHost {
        // `.idle` can be a transient snapshot while the containing app
        // starts. Wait for a matching `.recording` acknowledgement or
        // the launch timeout instead of enabling a second request.
        return
      }
      if mode == .recording || mode == .cancelling || mode == .transcribing {
        clearTrackedRequest()
        mode = .idle
      }
    case .error:
      if mode == .openingHost,
        snapshot.activeRequestID != activeRequestID
      {
        // This is the previous request's error snapshot. The relay has
        // not acknowledged the new start command yet.
        return
      }
      if mode == .openingHost || mode == .recording || mode == .cancelling || mode == .transcribing
      {
        clearTrackedRequest()
        mode = .idle
      }
    case .offline:
      break
    }
  }

  func observeResult(in snapshot: RelaySnapshot) {
    guard snapshot.resultSequence > lastObservedResultSequence else { return }

    // A refresh task can already be queued when the keyboard disappears.
    // Leave a matching dictation result unconsumed until viewDidAppear so
    // the returned text proxy gets a fair automatic-insertion check.
    if snapshot.resultKind == .dictation,
      snapshot.resultRequestID == activeRequestID,
      !keyboardIsVisible
    {
      return
    }
    lastObservedResultSequence = snapshot.resultSequence

    guard let transcript = snapshot.transcript,
      !TranscriptFormatter.cleaned(transcript).isEmpty
    else {
      markResultConsumed(sequence: snapshot.resultSequence)
      return
    }

    let resultIsRecent =
      snapshot.resultCreatedAt.map {
        abs(Date().timeIntervalSince($0)) < 10 * 60
      } ?? false

    if mode == .cancelling,
      snapshot.resultRequestID == activeRequestID
    {
      markResultConsumed(sequence: snapshot.resultSequence)
      clearTrackedRequest()
      mode = .idle
      return
    }

    guard let activeRequestID,
      snapshot.resultRequestID == activeRequestID
    else {
      if resultIsRecent {
        pendingTranscript = transcript
        pendingResultSequence = snapshot.resultSequence
        pendingResultKind = .dictation
                setInsertLatestVisible(true)
        mode = .resultWaiting
        return
      }
      markResultConsumed(sequence: snapshot.resultSequence)
      return
    }

    let sameDocument = textDocumentProxy.documentIdentifier == activeDocumentIdentifier
    let sameContext =
      Self.contextFingerprint(
        textDocumentProxy.documentContextBeforeInput
      ) == contextBeforeFingerprintAtRequest
      && Self.contextFingerprint(
        textDocumentProxy.documentContextAfterInput
      ) == contextAfterFingerprintAtRequest
    clearTrackedRequest()

    if keyboardIsVisible && sameDocument && sameContext {
      insertTranscript(transcript)
      markResultConsumed(sequence: snapshot.resultSequence)
      mode = .idle
    } else {
      pendingTranscript = transcript
      pendingResultSequence = snapshot.resultSequence
      pendingResultKind = .dictation
            setInsertLatestVisible(true)
      mode = .resultWaiting
    }
  }

  func insertTranscript(_ transcript: String) {
    let insertion = TranscriptFormatter.textForInsertion(
      transcript,
      contextBefore: textDocumentProxy.documentContextBeforeInput
    )
    guard !insertion.isEmpty else { return }
    textDocumentProxy.insertText(insertion)
    lastReplacement = nil
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    refreshTextStateSoon()
  }

  static func contextFingerprint(_ context: String?) -> String {
    var data = Data()
    data.append(context == nil ? 0 : 1)
    if let context {
      data.append(contentsOf: context.utf8)
    }
    return SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()
  }
}

extension KeyboardViewController {
  /// Pasteboard transport only: when the finished text has not arrived through
  /// the relay a few seconds after Finish, look for the app's last-resort item
  /// on the general pasteboard (it is removed as soon as it is read).
  func pickUpFallbackResultIfNeeded(_ snapshot: RelaySnapshot) {
    guard store.transportKind == .pasteboard,
      mode == .transcribing,
      let activeRequestID,
      let stopIssuedAt,
      Date().timeIntervalSince(stopIssuedAt) > 4.5,
      Date().timeIntervalSince(lastFallbackCheckAt) > 1
    else { return }
    lastFallbackCheckAt = Date()
    guard let text = RelayResultFallback.take(requestID: activeRequestID) else { return }
    let synthetic = RelaySnapshot(
      commandSequence: snapshot.commandSequence,
      handledCommandSequence: snapshot.handledCommandSequence,
      status: snapshot.status,
      heartbeat: snapshot.heartbeat,
      message: snapshot.message,
      offlineReason: snapshot.offlineReason,
      activeRequestID: snapshot.activeRequestID,
      activeDictationAction: snapshot.activeDictationAction,
      recordingStartedAt: snapshot.recordingStartedAt,
      audioLevel: snapshot.audioLevel,
      audioLevelUpdatedAt: snapshot.audioLevelUpdatedAt,
      resultSequence: max(snapshot.resultSequence, lastObservedResultSequence) + 1,
      resultRequestID: activeRequestID,
      resultKind: .dictation,
      resultCreatedAt: Date(),
      transcript: text
    )
    observeResult(in: synthetic)
  }
}
