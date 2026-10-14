import AVFoundation
import Combine
import Foundation
import UIKit

extension RelayController {
  func scheduleFinishDictation(requestID: String) {
    guard pendingFinishWorkItem == nil,
      status == .recording,
      activeRequestID == requestID
    else { return }

    // Give a nearly simultaneous keyboard cancellation one
    // polling turn to supersede Finish before any network task can exist.
    maximumDurationWorkItem?.cancel()
    maximumDurationWorkItem = nil
    let workItem = DispatchWorkItem { [weak self] in
      Task { @MainActor [weak self] in
        guard let self,
          self.status == .recording,
          self.activeRequestID == requestID
        else { return }
        self.finishDictationAndTranscribe(requestID: requestID)
      }
    }
    pendingFinishWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: workItem)
  }

  func beginTranscriptionBackgroundTaskIfNeeded() {
    guard transcriptionBackgroundTaskIdentifier == .invalid else { return }
    transcriptionBackgroundTaskIdentifier = UIApplication.shared.beginBackgroundTask(
      withName: "Finish VelikiyMoguchiy transcription"
    ) { [weak self] in
      Task { @MainActor [weak self] in
        self?.transcriptionBackgroundTimeExpired()
      }
    }
  }

  func transcriptionBackgroundTimeExpired() {
    transcriptionGeneration += 1
    transcriptionTask?.cancel()
    transcriptionTask = nil
    processingRequestID = nil
    processingRecordingID = nil
    recoveryRetryTask?.cancel()
    recoveryRetryTask = nil
    cancelLiveStream()
    let message = "Время обработки вышло — запись сохранена. Повторите в приложении «Великий & Могучий»."
    if isRelayRunning {
      publish(.error, message: message)
      markRelayActivityAndScheduleIdleShutdown()
    } else {
      statusMessage = message
    }
    endTranscriptionBackgroundTaskIfNeeded()
  }

  func endTranscriptionBackgroundTaskIfNeeded() {
    guard transcriptionBackgroundTaskIdentifier != .invalid else { return }
    UIApplication.shared.endBackgroundTask(transcriptionBackgroundTaskIdentifier)
    transcriptionBackgroundTaskIdentifier = .invalid
  }

  func applyPendingAudioRecoveryFailureIfNeeded() -> Bool {
    guard let error = pendingAudioRecoveryError else { return false }
    pendingAudioRecoveryError = nil
    var needsApp = false
    if case AudioCaptureError.needsApp = error { needsApp = true }
    giveUpAudio(
      message: error.localizedDescription,
      offlineReason: needsApp ? .needsApp : .unavailable,
      error: error
    )
    return true
  }
}
