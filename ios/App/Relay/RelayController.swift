import AVFoundation
import Combine
import Darwin
import Foundation
import ObjectiveC
import UIKit

enum RelayIdleShutdownPolicy {
  static func canStop(
    relayIsRunning: Bool,
    operationIsBusy: Bool,
    hasPendingHandoff: Bool,
    hasPendingCommand: Bool
  ) -> Bool {
    relayIsRunning
      && !operationIsBusy
      && !hasPendingHandoff
      && !hasPendingCommand
  }
}

@MainActor
final class RelayController: ObservableObject {
  static let maximumDictationDuration: TimeInterval = 5 * 60

  struct PendingHostReturn: Equatable {
    let requestID: String
    let bundleIdentifier: String?
  }

  #if VELIKIY_MOGUCHIY_PERSONAL_DEVICE
    struct HostReactivationResult {
      let accepted: Bool
      let stage: String
    }

    // Keep the image resident for the process lifetime. Releasing this handle
    // immediately after invoking LaunchServices adds an avoidable loader race
    // while SpringBoard is still acting on the asynchronous activation request.
    static let coreServicesFrameworkHandle = dlopen(
      "/System/Library/Frameworks/CoreServices.framework/CoreServices",
      RTLD_LAZY | RTLD_LOCAL
    )
  #endif

  @Published var isRelayRunning = false
  @Published var isRelayStarting = false
  @Published var idleShutdownDeadline: Date?
  @Published var status: RelayStatus = .offline
  @Published var statusMessage = "Приём выключен"
  @Published var history: [TranscriptHistoryItem] = []
  @Published var recoverableRecordings: [RecoverableRecording] = []
  @Published var retryingRecordingID: UUID?
  @Published var activeStartedAt: Date?
  @Published var isKeyboardHandoffActive = false
  @Published var requiresManualKeyboardReturn = false
  @Published var audioLevel: Double = 0
  @Published var isNoteCapturePresented = false
  @Published var noteCapturePhase: NoteCapturePhase = .preparing
  @Published var notePreviewText = ""
  @Published var historyError: String?
  var noteStartupID: UUID?

  let configuration: AppConfiguration
  let store: SharedRelayStore
  let capture: AudioCaptureEngine
  let transcriber: DashScopeRecordingTranscriber
  let recoveryStore: RecoverableRecordingStore
  let historyStore: TranscriptHistoryStore
  let pollingQueue = DispatchQueue(label: "VelikiyMoguchiy.relay-polling")

  var pollTimer: DispatchSourceTimer?
  var idleShutdownWorkItem: DispatchWorkItem?
  var lastHandledSequence = 0
  var heartbeatTick = 0
  var activeRequestID: String?
  var activeDictationAction: RelayDictationAction?
  var maximumDurationWorkItem: DispatchWorkItem?
  var pendingFinishWorkItem: DispatchWorkItem?
  var returnToKeyboardWorkItem: DispatchWorkItem?
  var returnToKeyboardGeneration = 0
  var pendingHostReturn: PendingHostReturn?
  var hostReturnAttemptCount = 0
  var systemNavigationReturnDeadline: Date?
  var systemNavigationReturnAccepted = false
  var transcriptionBackgroundTaskIdentifier: UIBackgroundTaskIdentifier = .invalid
  var pendingLaunchRequest: RelayLaunchRequest?
  var relayStartupGeneration = 0
  var transcriptionGeneration = 0
  var transcriptionTask: Task<Void, Never>?
  var processingRequestID: String?
  var processingRecordingID: UUID?
  var recoveryRetryTask: Task<Void, Never>?
  var relaySessionID: String?
  var liveRequestID: String?
  var activeLiveSession: DashScopeRealtimeSession?
  var liveConnectionTask: Task<Void, Error>?
  var lastLivePreviewAt = Date.distantPast
  var pendingAudioRecoveryError: Error?
  var lastKeyboardSeenHandled: Date?
  var lastHeartbeatAt = Date.distantPast
  var currentPollInterval: DispatchTimeInterval = .seconds(1)
  var pollTickCount = 0
  /// An interruption paused the engine; it resumes by itself.
  var isAudioPaused = false
  /// iOS would not give the microphone back; the app has to come forward.
  var audioNeedsApp = false
  let powerMonitor: RelayPowerMonitor
  /// Overridable in tests; production reads the battery and Low Power Mode.
  var powerStateProvider: () -> RelayPowerState
  let liveActivity = RelayLiveActivityController()

  init(
    configuration: AppConfiguration,
    store: SharedRelayStore = SharedRelayStore(),
    capture: AudioCaptureEngine = AudioCaptureEngine(),
    transcriber: DashScopeRecordingTranscriber = DashScopeRecordingTranscriber(),
    recoveryStore: RecoverableRecordingStore = RecoverableRecordingStore(),
    historyStore: TranscriptHistoryStore = TranscriptHistoryStore(),
    powerMonitor: RelayPowerMonitor? = nil
  ) {
    let monitor = powerMonitor ?? RelayPowerMonitor()
    self.powerMonitor = monitor
    self.powerStateProvider = { monitor.state }
    self.configuration = configuration
    self.store = store
    self.capture = capture
    self.transcriber = transcriber
    self.recoveryStore = recoveryStore
    self.historyStore = historyStore
    history = historyStore.items
    recoverableRecordings = recoveryStore.recordings
    applyHistoryRetention()

    monitor.onChange = { [weak self] in self?.evaluatePowerConstraint() }
    configureLiveActivityControls()
    // Start watching the network now, so the first dictation already knows.
    _ = NetworkPathMonitor.shared

    capture.levelHandler = { [weak self] level in
      DispatchQueue.main.async { [weak self] in
        guard let self,
          self.status == .recording,
          let requestID = self.activeRequestID
        else { return }
        self.audioLevel = level
        self.store.publishAudioLevel(level, requestID: requestID)
      }
    }
  }

  func applicationDidBecomeActive() async {
    guard UIApplication.shared.applicationState == .active else { return }
    applyHistoryRetention()
    if pendingLaunchRequest == nil {
      pendingLaunchRequest = store.pendingLaunchRequest()
    }
    if let pendingLaunchRequest {
      if !noteCapturePhase.isBusy { isNoteCapturePresented = false }
      isKeyboardHandoffActive = true
      requiresManualKeyboardReturn = manualReturnRequired(
        for: pendingLaunchRequest
      )
    }

    if isRelayRunning {
      // The one moment a lost microphone can be rebuilt for sure.
      capture.applicationDidBecomeActive()
      recoverIdleStateForPendingLaunchIfNeeded()
      preparePendingLaunchHandoffIfNeeded()
      scheduleIdleShutdownIfEligible()
    } else {
      await startRelay()
    }
  }

  func startRelay() async {
    guard !isRelayRunning, !isRelayStarting else { return }
    if UIApplication.shared.applicationState == .active,
      pendingLaunchRequest == nil
    {
      pendingLaunchRequest = store.pendingLaunchRequest()
    }
    relayStartupGeneration += 1
    let startupGeneration = relayStartupGeneration
    isRelayStarting = true
    defer { isRelayStarting = false }

    guard configuration.hasUsableAPIKey else {
      discardPendingLaunchRequest()
      publishUnavailable(
        message: CredentialAvailability.appMessage,
        offlineReason: .missingAPIKey
      )
      return
    }

    capture.recoveryHandler = { [weak self] event in
      Task { @MainActor [weak self] in
        guard let self,
          self.relayStartupGeneration == startupGeneration
        else {
          return
        }
        self.handleAudioRecovery(event)
      }
    }

    setLocalStatus(.offline, message: "Запрашиваю доступ к микрофону…")
    let permissionGranted = await requestMicrophonePermission()
    guard startupGeneration == relayStartupGeneration else { return }
    guard permissionGranted else {
      discardPendingLaunchRequest()
      publishUnavailable(
        message: "Доступ к микрофону выключен. Включите его в Настройках iOS и попробуйте снова"
      )
      return
    }

    do {
      try capture.start()
      isRelayRunning = true
      isAudioPaused = false
      audioNeedsApp = false
      pendingAudioRecoveryError = nil
      relaySessionID = UUID().uuidString

      let snapshot = store.snapshot()
      lastHandledSequence = snapshot.handledCommandSequence
      // Pasteboard transport: the keyboard's Darwin signal wakes the poll loop.
      store.onRemoteChange = { [weak self] in
        Task { @MainActor [weak self] in self?.pollRelayStore() }
      }
      lastKeyboardSeenHandled = store.keyboardLastSeen
      lastHeartbeatAt = .distantPast
      beginPolling()
      if status == .offline {
        publish(.idle, message: "Готово — переключитесь на клавиатуру «Великий & Могучий»")
      }
      preparePendingLaunchHandoffIfNeeded()
      pollRelayStore()
      scheduleIdleShutdownIfEligible(trigger: .armed)
      liveActivity.begin(state: liveActivityState)
    } catch {
      discardPendingLaunchRequest()
      publishUnavailable(message: error.localizedDescription)
    }
  }

  func credentialAvailabilityDidChange() {
    guard !configuration.hasUsableAPIKey else { return }
    stopRelay(
      message: CredentialAvailability.appMessage,
      offlineReason: .missingAPIKey
    )
  }

  func stopRelay(
    message: String = "Приём выключен. Нажмите микрофон, чтобы включить снова",
    offlineReason: RelayOfflineReason = .stopped
  ) {
    failNoteCapture("Запись остановлена. Начните новую заметку, когда будете готовы.")
    noteStartupID = nil
    relayStartupGeneration += 1
    transcriptionGeneration += 1
    transcriptionTask?.cancel()
    transcriptionTask = nil
    processingRequestID = nil
    processingRecordingID = nil
    recoveryRetryTask?.cancel()
    recoveryRetryTask = nil
    maximumDurationWorkItem?.cancel()
    maximumDurationWorkItem = nil
    pendingFinishWorkItem?.cancel()
    pendingFinishWorkItem = nil
    idleShutdownWorkItem?.cancel()
    idleShutdownWorkItem = nil
    idleShutdownDeadline = nil
    cancelAutomaticReturnToKeyboard()
    activeRequestID = nil
    activeDictationAction = nil
    activeStartedAt = nil
    pendingAudioRecoveryError = nil
    cancelLiveStream()
    discardPendingLaunchRequest()
    idleShutdownWorkItem?.cancel()
    idleShutdownWorkItem = nil
    idleShutdownDeadline = nil

    capture.stop()
    pollTimer?.cancel()
    pollTimer = nil
    isRelayRunning = false
    relaySessionID = nil
    audioLevel = 0
    publish(.offline, message: message, offlineReason: offlineReason)
    isKeyboardHandoffActive = false
    endTranscriptionBackgroundTaskIfNeeded()
    isAudioPaused = false
    audioNeedsApp = false
    liveActivity.end(finalMessage: message)
  }

  func applicationDidEnterBackground() {
    cancelAutomaticReturnToKeyboard()
    isKeyboardHandoffActive = false
  }

  func cancelKeyboardHandoff() {
    if status == .recording, activeRequestID != nil {
      cancelDictation()
      return
    }
    discardPendingLaunchRequest()
    isKeyboardHandoffActive = false
  }

  func handleAudioRecovery(_ event: AudioCaptureEvent) {
    guard isRelayRunning else { return }

    // A delayed route-change result can arrive after capture has ended while
    // the complete request is finalizing. Preserve that result, then apply
    // any microphone failure after the transcript has been published.
    if status == .transcribing {
      switch event {
      case .recovered, .paused:
        pendingAudioRecoveryError = nil
      case .needsApp(let error):
        pendingAudioRecoveryError = error ?? AudioCaptureError.needsApp
      case .failed(let error):
        pendingAudioRecoveryError = error
      }
      return
    }

    failNoteCapture("Запись прервана сменой аудио. Начните новую заметку.")

    maximumDurationWorkItem?.cancel()
    maximumDurationWorkItem = nil
    pendingFinishWorkItem?.cancel()
    pendingFinishWorkItem = nil
    activeRequestID = nil
    activeDictationAction = nil
    activeStartedAt = nil
    cancelLiveStream()
    audioLevel = 0
    isKeyboardHandoffActive = false

    switch event {
    case .recovered(let message):
      guard status != .transcribing else { return }
      isAudioPaused = false
      publish(.idle, message: "\(message) — готово")
      markRelayActivityAndScheduleIdleShutdown()
    case .paused(let message):
      isAudioPaused = true
      // The session stays active and the relay stays armed; the keyboard shows
      // why dictation is unavailable until the engine resumes.
      publish(.error, message: message)
      liveActivity.update(state: liveActivityState)
    case .needsApp(let error):
      giveUpAudio(
        message: AudioCaptureError.needsApp.localizedDescription,
        offlineReason: .needsApp,
        error: error
      )
    case .failed(let error):
      giveUpAudio(
        message: error.localizedDescription,
        offlineReason: .unavailable,
        error: error
      )
    }
  }

  /// The microphone could not be brought back from the background. The relay
  /// goes offline with a message the keyboard understands; the Live Activity is
  /// kept (a new one cannot be started from the background) and shows that the
  /// app must come forward.
  func giveUpAudio(message: String, offlineReason: RelayOfflineReason, error: Error?) {
    transcriptionGeneration += 1
    transcriptionTask?.cancel()
    transcriptionTask = nil
    pollTimer?.cancel()
    pollTimer = nil
    idleShutdownWorkItem?.cancel()
    idleShutdownWorkItem = nil
    idleShutdownDeadline = nil
    isAudioPaused = false
    audioNeedsApp = offlineReason == .needsApp
    // Reset the audio layer so the next foreground start begins from scratch.
    capture.stop()
    isRelayRunning = false
    publishUnavailable(message: message, offlineReason: offlineReason)
    endTranscriptionBackgroundTaskIfNeeded()
    liveActivity.update(state: liveActivityState)
  }

  deinit {
    transcriptionTask?.cancel()
    recoveryRetryTask?.cancel()
    idleShutdownWorkItem?.cancel()
    pollTimer?.cancel()
    capture.stop()
  }
}
