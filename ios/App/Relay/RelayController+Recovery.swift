import AVFoundation
import Combine
import Foundation
import UIKit

extension RelayController {
  func clearHistory() {
    do {
      try historyStore.clear()
      history = historyStore.items
      historyError = nil
    } catch {
      historyError = error.localizedDescription
    }
  }

  func deleteHistoryItem(_ item: TranscriptHistoryItem) {
    do {
      try historyStore.remove(id: item.id)
      history = historyStore.items
      historyError = nil
    } catch {
      historyError = error.localizedDescription
    }
  }

  func applyHistoryRetention() {
    do {
      try historyStore.removeExpired(retentionDays: configuration.historyRetentionDays)
      history = historyStore.items
      historyError = nil
    } catch {
      historyError = "Не удалось обновить историю: \(error.localizedDescription)"
    }
  }

  func retryRecording(_ recording: RecoverableRecording) {
    guard retryingRecordingID == nil,
      status != .recording,
      status != .transcribing,
      recording.transcriptSaved != true,
      configuration.hasUsableAPIKey,
      let audioURL = recoveryStore.fileURL(for: recording)
    else { return }

    let retryRequestID = UUID().uuidString
    markRelayActivityAndSuspendIdleShutdown()
    retryingRecordingID = recording.id
    recoveryStore.markFailed(
      id: recording.id,
      message: "Повторное распознавание…",
      incrementRetryCount: true
    )
    refreshRecoverableRecordings()
    if isRelayRunning {
      publish(
        .transcribing,
        message: "Повторно распознаю сохранённую запись…",
        activeRequestID: retryRequestID,
        activeDictationAction: recording.action
      )
    } else {
      statusMessage = "Повторно распознаю сохранённую запись…"
    }
    beginTranscriptionBackgroundTaskIfNeeded()

    let apiKey = configuration.apiKey
    let region = configuration.dashScopeRegion
    let language = DictationLanguage.resolve(recording.languageCode)
    recoveryRetryTask = Task { [weak self] in
      guard let self else { return }
      defer {
        retryingRecordingID = nil
        recoveryRetryTask = nil
        endTranscriptionBackgroundTaskIfNeeded()
      }

      do {
        let outputText = try await fallbackResult(
          from: audioURL,
          language: language,
          apiKey: apiKey,
          region: region
        )
        try Task.checkCancellation()
        try completeTranscription(outputText, requestID: retryRequestID, action: recording.action)
        configuration.markKeyVerified()
        do {
          try recoveryStore.remove(id: recording.id)
        } catch {
          recoveryStore.markTranscriptSaved(
            id: recording.id,
            cleanupError: "Текст сохранён, но аудио удалить не удалось: \(error.localizedDescription)"
          )
          refreshRecoverableRecordings()
          statusMessage = error.localizedDescription
          if isRelayRunning {
            publish(.error, message: error.localizedDescription)
            markRelayActivityAndScheduleIdleShutdown()
          }
          return
        }
        refreshRecoverableRecordings()
        if isRelayRunning {
          publish(.idle, message: recording.action == .note ? "Заметка сохранена в истории" : "Запись распознана — готово")
          markRelayActivityAndScheduleIdleShutdown()
        } else {
          statusMessage = "Запись распознана"
        }
      } catch is CancellationError {
        recoveryStore.markFailed(
          id: recording.id,
          message: "Повтор приостановлен; запись сохранена"
        )
        refreshRecoverableRecordings()
      } catch {
        let failure = DictationFailure(error)
        NSLog(
          "RETRY_FAILED code=%@ error=%@",
          failure.code,
          String(describing: error)
        )
        let keptRecording = keepOrDiscardFailedRecording(recording.id, failure: failure)
        let silentMessage = "В записи не слышно речи — она удалена"
        if isRelayRunning {
          publish(
            .error,
            message: keptRecording ? failure.keyboardText : silentMessage,
            activeRequestID: retryRequestID,
            activeDictationAction: recording.action
          )
          markRelayActivityAndScheduleIdleShutdown()
        }
        statusMessage = keptRecording ? failure.detail : silentMessage
      }
    }
  }

  func deleteRecording(_ recording: RecoverableRecording) {
    guard retryingRecordingID != recording.id else { return }
    do {
      try recoveryStore.remove(id: recording.id)
      refreshRecoverableRecordings()
      if isRelayRunning, status == .error {
        publish(.idle, message: "Сохранённая запись удалена — готово")
        markRelayActivityAndScheduleIdleShutdown()
      }
    } catch {
      recoveryStore.markFailed(id: recording.id, message: error.localizedDescription)
      refreshRecoverableRecordings()
      statusMessage = error.localizedDescription
      if isRelayRunning {
        publish(.error, message: error.localizedDescription)
        markRelayActivityAndScheduleIdleShutdown()
      }
    }
  }

  func refreshRecoverableRecordings() {
    recoverableRecordings = recoveryStore.recordings
  }

  @discardableResult
  func addToHistory(_ text: String) throws -> TranscriptHistoryItem {
    try historyStore.removeExpired(retentionDays: configuration.historyRetentionDays)
    let item = try historyStore.add(text: text)
    history = historyStore.items
    return item
  }
}
