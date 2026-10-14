import AVFoundation
import Combine
import Foundation
import UIKit

extension RelayController {
  func cancelAutomaticReturnToKeyboard() {
    returnToKeyboardWorkItem?.cancel()
    returnToKeyboardWorkItem = nil
    returnToKeyboardGeneration += 1
    pendingHostReturn = nil
    hostReturnAttemptCount = 0
    systemNavigationReturnDeadline = nil
    systemNavigationReturnAccepted = false
  }

  func cancelDictation(message: String? = nil) {
    if activeDictationAction == .note {
      failNoteCapture("Запись отменена. Заметка не сохранена.")
    }
    cancelAutomaticReturnToKeyboard()
    pendingAudioRecoveryError = nil
    maximumDurationWorkItem?.cancel()
    maximumDurationWorkItem = nil
    pendingFinishWorkItem?.cancel()
    pendingFinishWorkItem = nil
    let hadLiveStream = liveRequestID == activeRequestID
    if let activeRequestID {
      cancelLiveStream(matching: activeRequestID)
    }
    capture.cancelSegment()
    audioLevel = 0
    activeRequestID = nil
    activeDictationAction = nil
    activeStartedAt = nil
    isKeyboardHandoffActive = false
    publish(
      .idle,
      message: message
        ?? (hadLiveStream
          ? "Приём остановлен, результат отброшен — готово"
          : "Диктовка отменена — готово")
    )
    markRelayActivityAndScheduleIdleShutdown()
  }

  func cancelTranscription(requestID: String) {
    guard status == .transcribing,
      processingRequestID == requestID
    else { return }

    transcriptionGeneration += 1
    transcriptionTask?.cancel()
    transcriptionTask = nil
    cancelLiveStream(matching: requestID)

    let recordingID = processingRecordingID
    processingRequestID = nil
    processingRecordingID = nil
    endTranscriptionBackgroundTaskIfNeeded()

    if let recordingID {
      do {
        try recoveryStore.remove(id: recordingID)
      } catch {
        recoveryStore.markFailed(
          id: recordingID,
          message: "Обработка остановлена, но сохранённую запись не удалось удалить: \(error.localizedDescription)"
        )
        refreshRecoverableRecordings()
        publish(
          .error,
          message: "Обработка остановлена, но сохранённую запись не удалось удалить"
        )
        markRelayActivityAndScheduleIdleShutdown()
        return
      }
    }
    refreshRecoverableRecordings()

    if applyPendingAudioRecoveryFailureIfNeeded() {
      return
    }
    publish(.idle, message: "Обработка отменена — готово")
    markRelayActivityAndScheduleIdleShutdown()
  }

  func finishDictationAndTranscribe(requestID: String) {
    markRelayActivityAndSuspendIdleShutdown()
    pendingFinishWorkItem?.cancel()
    pendingFinishWorkItem = nil
    maximumDurationWorkItem?.cancel()
    maximumDurationWorkItem = nil

    let segment: CapturedAudioSegment
    let action = activeDictationAction ?? .transcribe
    if action == .note { noteCapturePhase = .processing }
    let liveSession = liveRequestID == requestID ? activeLiveSession : nil
    let connectionTask = liveRequestID == requestID ? liveConnectionTask : nil
    do {
      segment = try capture.endSegment()
      audioLevel = 0
    } catch {
      cancelLiveStream(matching: requestID)
      activeRequestID = nil
      activeDictationAction = nil
      activeStartedAt = nil
      publish(
        .error,
        message: error.localizedDescription,
        activeRequestID: requestID,
        activeDictationAction: action
      )
      markRelayActivityAndScheduleIdleShutdown()
      return
    }

    activeRequestID = nil
    activeDictationAction = nil
    activeStartedAt = nil
    isKeyboardHandoffActive = false
    let processingMessage =
      liveSession != nil
      ? "Оформляю текст…"
      : "Распознаю сохранённую запись…"
    publish(
      .transcribing,
      message: processingMessage,
      activeRequestID: requestID,
      activeDictationAction: action
    )
    beginTranscriptionBackgroundTaskIfNeeded()

    let apiKey = configuration.apiKey
    let region = configuration.dashScopeRegion
    let language = DictationLanguage.resolve(segment.languageCode)
    let recoverableRecording: RecoverableRecording
    do {
      recoverableRecording = try recoveryStore.stage(
        segment,
        action: action,
        languageCode: language.code
      )
    } catch {
      cancelLiveStream(matching: requestID)
      publish(
        .error,
        message: "Запись сохранена, но данные для повтора не записались: \(error.localizedDescription)",
        activeRequestID: requestID,
        activeDictationAction: action
      )
      markRelayActivityAndScheduleIdleShutdown()
      endTranscriptionBackgroundTaskIfNeeded()
      return
    }
    refreshRecoverableRecordings()
    processingRequestID = requestID
    processingRecordingID = recoverableRecording.id
    transcriptionGeneration += 1
    let generation = transcriptionGeneration
    transcriptionTask?.cancel()
    transcriptionTask = Task { [weak self] in
      guard let self else { return }
      defer {
        if generation == transcriptionGeneration {
          cancelLiveStream(matching: requestID)
          transcriptionTask = nil
          processingRequestID = nil
          processingRecordingID = nil
          endTranscriptionBackgroundTaskIfNeeded()
        }
      }

      do {
        try Task.checkCancellation()
        let outputText: String
        let usedLiveStream: Bool
        if let liveSession, let connectionTask {
          do {
            try await connectionTask.value
            try Task.checkCancellation()
            outputText = try await liveSession.finish()
            usedLiveStream = true
          } catch is CancellationError {
            throw CancellationError()
          } catch DashScopeSpeechError.noSpeech {
            // The replay would send the same silent audio and fail the same way.
            throw DashScopeSpeechError.noSpeech
          } catch {
            NSLog(
              "LIVE_STREAM_FALLBACK request=%@ reason=%@",
              requestID,
              Self.safeErrorSummary(error)
            )
            outputText = try await fallbackResult(
              from: segment.url,
              language: language,
              apiKey: apiKey,
              region: region
            )
            usedLiveStream = false
          }
        } else {
          outputText = try await fallbackResult(
            from: segment.url,
            language: language,
            apiKey: apiKey,
            region: region
          )
          usedLiveStream = false
        }
        try Task.checkCancellation()
        guard generation == transcriptionGeneration, isRelayRunning else {
          recoveryStore.markFailed(
            id: recoverableRecording.id,
            message: "Обработка прервана; запись сохранена"
          )
          refreshRecoverableRecordings()
          return
        }

        try completeTranscription(outputText, requestID: requestID, action: action)
        configuration.markKeyVerified()
        do {
          try recoveryStore.remove(id: recoverableRecording.id)
        } catch {
          recoveryStore.markTranscriptSaved(
            id: recoverableRecording.id,
            cleanupError: "Текст сохранён, но аудио удалить не удалось: \(error.localizedDescription)"
          )
          refreshRecoverableRecordings()
          publish(.error, message: error.localizedDescription)
          markRelayActivityAndScheduleIdleShutdown()
          return
        }
        refreshRecoverableRecordings()
        if applyPendingAudioRecoveryFailureIfNeeded() {
          return
        }
        let completionMessage: String
        if action == .note {
          completionMessage = "Заметка сохранена в истории"
        } else if usedLiveStream {
          completionMessage = "Текст вставлен — готово"
        } else {
          completionMessage = "Текст из сохранённой записи вставлен — готово"
        }
        publish(.idle, message: completionMessage)
        markRelayActivityAndScheduleIdleShutdown()
      } catch is CancellationError {
        recoveryStore.markFailed(
          id: recoverableRecording.id,
          message: "Обработка приостановлена; запись сохранена"
        )
        refreshRecoverableRecordings()
        return
      } catch {
        let failure = DictationFailure(error)
        NSLog(
          "DICTATION_FAILED request=%@ code=%@ error=%@",
          requestID,
          failure.code,
          String(describing: error)
        )
        let keptRecording = keepOrDiscardFailedRecording(recoverableRecording.id, failure: failure)
        if action == .note {
          failNoteCapture(
            keptRecording
              ? "\(failure.detail)\nЗапись сохранена, её можно повторить в «Истории»."
              : "\(failure.detail)\nЗаметка не сохранена."
          )
        }
        guard generation == transcriptionGeneration, isRelayRunning else { return }
        if applyPendingAudioRecoveryFailureIfNeeded() {
          return
        }
        publish(
          .error,
          message: failure.keyboardText,
          activeRequestID: requestID,
          activeDictationAction: action
        )
        // The keyboard row has room for one line; the app shows the whole advice.
        statusMessage = failure.detail
        markRelayActivityAndScheduleIdleShutdown()
      }
    }
  }

  /// Returns whether the recording is still kept for a retry.
  @discardableResult
  func keepOrDiscardFailedRecording(_ id: UUID, failure: DictationFailure) -> Bool {
    defer { refreshRecoverableRecordings() }
    if !failure.keepsRecording {
      do {
        try recoveryStore.remove(id: id)
        return false
      } catch {
        NSLog("SILENT_RECORDING_REMOVE_FAILED error=%@", error.localizedDescription)
      }
    }
    recoveryStore.markFailed(id: id, message: failure.detail)
    return true
  }

  func fallbackResult(
    from segmentURL: URL,
    language: DictationLanguage,
    apiKey: String,
    region: DashScopeRegion
  ) async throws -> String {
    try Task.checkCancellation()
    return try await transcriber.transcribe(
      recordingAt: segmentURL,
      language: language,
      apiKey: apiKey,
      region: region
    )
  }

  func publishLivePreview(
    _ text: String,
    requestID: String,
    action: RelayDictationAction
  ) {
    guard status == .recording, activeRequestID == requestID else { return }
    let now = Date()
    guard now.timeIntervalSince(lastLivePreviewAt) >= 0.35 else { return }
    let cleaned = TranscriptFormatter.cleaned(text)
    guard !cleaned.isEmpty else { return }
    lastLivePreviewAt = now

    if action == .note { notePreviewText = cleaned }

    let preview = String(cleaned.prefix(100))
    let message = RelayRecordingMessage.livePreviewPrefix + preview
    setLocalStatus(.recording, message: message)
    store.publishStatus(
      .recording,
      message: message,
      activeRequestID: requestID,
      activeDictationAction: action,
      recordingStartedAt: activeStartedAt
    )
  }

  func cancelLiveStream(matching requestID: String? = nil) {
    if let requestID, liveRequestID != requestID { return }
    liveConnectionTask?.cancel()
    liveConnectionTask = nil
    if let activeLiveSession {
      Task { await activeLiveSession.cancel() }
    }
    activeLiveSession = nil
    liveRequestID = nil
  }

  static func safeErrorSummary(_ error: Error) -> String {
    switch error {
    case let liveError as DashScopeSpeechError:
      return liveError.localizedDescription
    default:
      return "сбой потокового соединения"
    }
  }
}
