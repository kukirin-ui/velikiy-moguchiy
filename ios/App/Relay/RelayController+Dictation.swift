import AVFoundation
import Combine
import Foundation
import UIKit

extension RelayController {
  func beginDictationFromKeyboardCommand(_ envelope: RelayCommandEnvelope) {
    guard envelope.dictationAction != .note, noteStartupID == nil else { return }
    if !noteCapturePhase.isBusy { isNoteCapturePresented = false }
    let storedPendingLaunch = store.pendingLaunchRequest()
    switch RelayStartAuthorizationPolicy.resolve(
      command: envelope,
      loadedPendingLaunch: pendingLaunchRequest,
      storedPendingLaunch: storedPendingLaunch
    ) {
    case .pendingLaunch(let launchRequest):
      pendingLaunchRequest = launchRequest
      guard store.claimPendingLaunchRequest(matching: launchRequest) == launchRequest else {
        markRelayActivityAndScheduleIdleShutdown()
        return
      }
      pendingLaunchRequest = nil
      isKeyboardHandoffActive = false
      requiresManualKeyboardReturn = false
      cancelAutomaticReturnToKeyboard()
    case .reject:
      pendingLaunchRequest = nil
      isKeyboardHandoffActive = false
      requiresManualKeyboardReturn = false
      cancelAutomaticReturnToKeyboard()
      markRelayActivityAndScheduleIdleShutdown()
      return
    case .warm:
      if pendingLaunchRequest != nil {
        discardPendingLaunchRequest()
      }
    }

    beginDictation(
      requestID: envelope.requestID,
      action: envelope.dictationAction,
      language: DictationLanguage.resolve(envelope.languageCode)
    )
  }

  func beginDictation(
    requestID: String,
    action: RelayDictationAction,
    language: DictationLanguage
  ) {
    guard configuration.hasUsableAPIKey else {
      publishUnavailable(
        message: CredentialAvailability.appMessage,
        offlineReason: .missingAPIKey
      )
      return
    }
    guard status != .transcribing, activeRequestID == nil else { return }
    markRelayActivityAndSuspendIdleShutdown()

    let liveSession = DashScopeRealtimeSession(
      language: language,
      progressHandler: { [weak self] text in
        Task { @MainActor [weak self] in
          self?.publishLivePreview(
            text,
            requestID: requestID,
            action: action
          )
        }
      }
    )
    liveRequestID = requestID
    activeLiveSession = liveSession
    lastLivePreviewAt = .distantPast
    let apiKey = configuration.apiKey
    let region = configuration.dashScopeRegion
    liveConnectionTask = Task {
      try await liveSession.connect(apiKey: apiKey, region: region)
    }

    let chunkHandler: @Sendable (Data) -> Void = { data in
      liveSession.enqueueAudio(data)
    }
    let streamingFailureHandler: @Sendable (String) -> Void = { reason in
      Task { await liveSession.invalidateAudioStream(reason) }
    }

    do {
      let startedAt = Date()
      try capture.beginSegment(
        requestID: requestID,
        action: action,
        languageCode: language.code,
        at: startedAt,
        audioChunkHandler: chunkHandler,
        audioStreamingFailureHandler: streamingFailureHandler
      )
      activeRequestID = requestID
      activeDictationAction = action
      activeStartedAt = startedAt
      let listeningMessage: String
      if NetworkPathMonitor.shared.isOffline {
        listeningMessage = RelayRecordingMessage.offline
      } else {
        listeningMessage = action == .note
          ? "Записываю заметку…"
          : "Слушаю… нажмите микрофон ещё раз, когда закончите"
      }
      publish(
        .recording,
        message: listeningMessage,
        activeRequestID: requestID,
        activeDictationAction: action,
        recordingStartedAt: startedAt
      )

      let workItem = DispatchWorkItem { [weak self] in
        Task { @MainActor [weak self] in
          guard let self, self.activeRequestID == requestID else { return }
          self.finishDictationAndTranscribe(requestID: requestID)
        }
      }
      maximumDurationWorkItem = workItem
      DispatchQueue.main.asyncAfter(
        deadline: .now() + Self.maximumDictationDuration,
        execute: workItem
      )
    } catch {
      cancelAutomaticReturnToKeyboard()
      cancelLiveStream(matching: requestID)
      publish(
        .error,
        message: error.localizedDescription,
        activeRequestID: requestID,
        activeDictationAction: action
      )
      markRelayActivityAndScheduleIdleShutdown()
    }
  }
}
