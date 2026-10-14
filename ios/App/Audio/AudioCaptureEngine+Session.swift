import AVFoundation
import Foundation

extension AudioCaptureEngine {
  var sessionConfigurations: [SessionConfiguration] {
    [
      SessionConfiguration(
        name: "AirPods high-quality",
        mode: .default,
        options: [.mixWithOthers, .allowBluetoothHFP, .bluetoothHighQualityRecording]
      ),
      SessionConfiguration(
        name: "Bluetooth mixed",
        mode: .default,
        options: [.mixWithOthers, .allowBluetoothHFP, .allowBluetoothA2DP]
      ),
      SessionConfiguration(
        name: "Bluetooth hands-free",
        mode: .default,
        options: [.mixWithOthers, .allowBluetoothHFP]
      ),
      SessionConfiguration(
        name: "Built-in mixed",
        mode: .default,
        options: [.mixWithOthers]
      ),
    ]
  }

  func reportRecoverableRecordings() {
    guard let container = VoiceAppGroup.appDataDirectory else { return }
    let directory = container.appendingPathComponent("Recordings", isDirectory: true)
    guard
      let urls = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      )
    else { return }

    let recoverableCount = urls.filter {
      $0.lastPathComponent.hasPrefix("completed-")
        && $0.pathExtension.lowercased() == "wav"
    }.count
    if recoverableCount > 0 {
      NSLog("AUDIO_RECOVERABLE_RECORDINGS_PRESERVED count=%d", recoverableCount)
    }
  }

  /// IO buffer length: long while the microphone only waits (fewer wake-ups,
  /// less battery), short while a dictation is being captured.
  enum CaptureProfile {
    case idle
    case dictating

    var preferredIOBufferDuration: TimeInterval {
      self == .idle ? 0.1 : 0.02
    }
  }

  func applyCaptureProfile(_ profile: CaptureProfile) {
    let session = AVAudioSession.sharedInstance()
    try? session.setPreferredIOBufferDuration(profile.preferredIOBufferDuration)
    NSLog(
      "AUDIO_RELAY_IO_BUFFER profile=%@ requested=%.3f actual=%.3f",
      profile == .idle ? "idle" : "dictating",
      profile.preferredIOBufferDuration,
      session.ioBufferDuration
    )
  }

  func startEngine(using configuration: SessionConfiguration) throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(
      .playAndRecord,
      mode: configuration.mode,
      options: configuration.options
    )
    try? session.setPreferredSampleRate(16_000)
    try? session.setPreferredInputNumberOfChannels(1)
    try? session.setPreferredIOBufferDuration(CaptureProfile.idle.preferredIOBufferDuration)
    try session.setActive(true, options: [])

    // An engine retained across a route change can expose the old output
    // format even after session activation. Never reinstall a tap on that graph.
    replaceStoppedEngine()
    try installTapAndStartEngine()
  }

  /// Installs the tap on the current engine and starts it. The session must
  /// already be active; this never touches activation.
  func installTapAndStartEngine() throws {
    let input = engine.inputNode
    let hardwareFormat = input.inputFormat(forBus: 0)
    let format = input.outputFormat(forBus: 0)
    guard Self.isUsableInputFormat(format, hardwareFormat: hardwareFormat) else {
      NSLog("IOS_VALIDATION_FAILURE microphone route format unavailable or changing")
      throw AudioCaptureError.invalidInputFormat
    }

    input.installTap(onBus: 0, bufferSize: 2_048, format: format) { [weak self] buffer, _ in
      self?.write(buffer)
    }
    tapInstalled = true
    fileLock.lock()
    inputFormat = format
    configureStreamingConverter(from: format)
    lastBufferUptime = ProcessInfo.processInfo.systemUptime
    fileLock.unlock()

    engine.prepare()
    try engine.start()
    isRunning = true
  }

  /// Stops the engine and the tap. `deactivateSession` is true only for a real
  /// stop of the relay: a background process generally cannot activate a
  /// recording session again, so recovery paths must keep it active.
  func tearDownEngine(deactivateSession: Bool = true) {
    // Stop delivery before removing the tap and releasing converter state.
    engine.stop()
    if tapInstalled {
      engine.inputNode.removeTap(onBus: 0)
      tapInstalled = false
    }
    if deactivateSession {
      try? AVAudioSession.sharedInstance().setActive(
        false,
        options: [.notifyOthersOnDeactivation]
      )
    }
    fileLock.lock()
    inputFormat = nil
    streamingConverter = nil
    streamingOutputFormat = nil
    streamingChunker.reset()
    audioChunkHandler = nil
    audioStreamingFailureHandler = nil
    didReportStreamingFailure = false
    fileLock.unlock()
    isRunning = false
    activeConfigurationName = ""
  }

  // MARK: Notifications

  func handleInterruption(_ notification: Notification) {
    guard shouldBeRunning,
      let event = AudioRecoveryMachine.interruptionEvent(from: notification.userInfo)
    else { return }
    NSLog("AUDIO_RELAY_INTERRUPTION event=%@ route=%@", String(describing: event), routeDescription)
    if case .interruptionEnded = event {
      // Give iOS a moment to hand the hardware back before the first attempt.
      scheduleRecovery(event: event, delay: AudioRecoveryMachine.firstResumeDelay)
    } else {
      recoveryWorkItem?.cancel()
      recoveryWorkItem = nil
      process(event)
    }
  }

  func handleRouteChange(_ notification: Notification) {
    guard shouldBeRunning,
      let event = AudioRecoveryMachine.routeChangeEvent(from: notification.userInfo)
    else { return }
    NSLog("AUDIO_RELAY_ROUTE_CHANGE route=%@", routeDescription)
    scheduleRecovery(event: event)
  }

  /// Route and configuration changes arrive in bursts; the last one wins.
  func scheduleRecovery(event: AudioRecoveryMachine.Event, delay: TimeInterval = 0.35) {
    guard shouldBeRunning, !isConfiguring else { return }
    recoveryWorkItem?.cancel()

    let workItem = DispatchWorkItem { [weak self] in
      guard let self, self.shouldBeRunning, !self.isConfiguring else { return }
      self.recoveryWorkItem = nil
      self.process(event)
    }
    recoveryWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
  }

  func replaceEngineAndRecover() {
    guard shouldBeRunning else { return }
    scheduleRecovery(event: .mediaServicesReset)
  }

  static func isUsableInputFormat(
    _ format: AVAudioFormat,
    hardwareFormat: AVAudioFormat
  ) -> Bool {
    hardwareFormat.sampleRate.isFinite && hardwareFormat.sampleRate > 0
      && hardwareFormat.channelCount > 0
      && format.sampleRate == hardwareFormat.sampleRate
      && format.channelCount == hardwareFormat.channelCount
  }

  /// Call only after teardown or before a fresh session's first tap.
  func replaceStoppedEngine() {
    if let engineConfigurationObserver {
      NotificationCenter.default.removeObserver(engineConfigurationObserver)
    }
    engine = AVAudioEngine()
    observeEngineConfiguration()
  }

  func observeEngineConfiguration() {
    engineConfigurationObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange,
      object: engine,
      queue: .main
    ) { [weak self, weak observedEngine = engine] _ in
      guard let self, let observedEngine, self.engine === observedEngine else { return }
      self.scheduleRecovery(event: .engineConfigurationChanged)
    }
  }

  // MARK: Recovery

  /// Feeds one event to the state machine and carries out its decision.
  func process(_ event: AudioRecoveryMachine.Event) {
    let action = recoveryMachine.handle(event)
    perform(action, after: event)
  }

  func perform(_ action: AudioRecoveryMachine.Action, after event: AudioRecoveryMachine.Event) {
    switch action {
    case .none:
      break
    case .pauseEngine:
      pauseForInterruption()
    case .restartInPlace:
      restartInPlace(reason: reasonText(for: event))
    case .resumeAfterInterruption(let attempt):
      let delay = attempt == 1 ? 0 : AudioRecoveryMachine.retryDelay
      let workItem = DispatchWorkItem { [weak self] in
        guard let self, self.shouldBeRunning else { return }
        self.recoveryWorkItem = nil
        self.resume(attempt: attempt)
      }
      recoveryWorkItem?.cancel()
      recoveryWorkItem = workItem
      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    case .rebuildSession:
      rebuildSession(reason: reasonText(for: event))
    case .reportNeedsApp:
      recoveryHandler?(.needsApp(lastRecoveryError))
    }
  }

  private func reasonText(for event: AudioRecoveryMachine.Event) -> String {
    switch event {
    case .interruptionEnded: return "прерывания"
    case .routeChanged: return "смены наушников или маршрута"
    case .engineConfigurationChanged: return "смены аудиоустройства"
    case .engineStalled: return "остановки микрофона"
    case .mediaServicesReset: return "сброса аудиосервисов"
    case .appBecameActive: return "возврата в приложение"
    default: return "сбоя"
    }
  }

  /// An interruption began: stop the engine, drop a running dictation, but keep
  /// the audio session active so the background process stays alive and can
  /// resume without a new activation.
  func pauseForInterruption() {
    let hadSegment = hasActiveSegment
    if hadSegment { cancelSegment() }
    engine.stop()
    if tapInstalled {
      engine.inputNode.removeTap(onBus: 0)
      tapInstalled = false
    }
    isRunning = false
    recoveryHandler?(
      .paused(
        hadSegment
          ? "Звонок или другое аудио прервало диктовку: она отменена"
          : "Пауза: микрофон занят другим приложением"
      )
    )
  }

  /// Rebuilds the engine and tap on the still-active session.
  func restartInPlace(reason: String) {
    let hadSegment = hasActiveSegment
    if hadSegment { cancelSegment() }
    do {
      try restartEngineInPlace()
      completeRecovery(reason: reason, interruptedDictation: hadSegment)
    } catch {
      failRecoveryAttempt(error, reason: reason)
    }
  }

  /// Resumes after an interruption: `setActive(true)` without a prior
  /// `setActive(false)`, then the in-place restart.
  func resume(attempt: Int) {
    do {
      try AVAudioSession.sharedInstance().setActive(true, options: [])
      try restartEngineInPlace()
      completeRecovery(reason: "прерывания", interruptedDictation: false)
    } catch {
      NSLog("AUDIO_RELAY_RESUME_FAILED attempt=%d error=%@", attempt, errorSummary(error))
      failRecoveryAttempt(error, reason: "прерывания")
    }
  }

  /// Stops engine and tap without touching the session, then starts again.
  func restartEngineInPlace() throws {
    engine.stop()
    if tapInstalled {
      engine.inputNode.removeTap(onBus: 0)
      tapInstalled = false
    }
    isRunning = false
    fileLock.lock()
    streamingConverter = nil
    streamingOutputFormat = nil
    fileLock.unlock()
    replaceStoppedEngine()
    try installTapAndStartEngine()
  }

  /// Full re-setup (category, activation, engine). Foreground or after a
  /// media-services reset only; the in-place path covers everything else.
  func rebuildSession(reason: String) {
    let hadSegment = hasActiveSegment
    if hadSegment { cancelSegment() }
    tearDownEngine()
    do {
      try start()
      completeRecovery(reason: reason, interruptedDictation: hadSegment)
    } catch {
      failRecoveryAttempt(error, reason: reason)
    }
  }

  private func completeRecovery(reason: String, interruptedDictation: Bool) {
    lastRecoveryError = nil
    applyCaptureProfile(.idle)
    let action = recoveryMachine.handle(.restartSucceeded)
    NSLog("AUDIO_RELAY_RECOVERED reason=%@ route=%@", reason, routeDescription)
    perform(action, after: .restartSucceeded)
    recoveryHandler?(
      .recovered(
        interruptedDictation
          ? "Звук восстановлен после \(reason); прерванная диктовка отменена"
          : "Звук восстановлен после \(reason)"
      )
    )
  }

  private func failRecoveryAttempt(_ error: Error, reason: String) {
    lastRecoveryError = error
    NSLog("AUDIO_RELAY_RECOVERY_FAILED reason=%@ error=%@", reason, errorSummary(error))
    let action = recoveryMachine.handle(.restartFailed)
    perform(action, after: .restartFailed)
  }

  // MARK: Liveness

  /// `AVAudioEngine.isRunning` can lie after the app was suspended, so the
  /// audio itself is the evidence: no tap buffer for `stallThreshold` seconds
  /// while the engine should be running means it is dead. Called from the poll
  /// loop and when the app returns to the foreground.
  static let stallThreshold: TimeInterval = 2.5

  func checkLiveness(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
    guard shouldBeRunning, tapInstalled, isRunning, !isConfiguring,
      recoveryMachine.phase == .running
    else { return }
    fileLock.lock()
    let age = now - lastBufferUptime
    fileLock.unlock()
    if age > Self.stallThreshold {
      NSLog("AUDIO_RELAY_STALLED age=%.1f", age)
      lastBufferUptime = now
      process(.engineStalled)
    } else if recoveryMachine.stallRestarts > 0 {
      process(.buffersFlowing)
    }
  }

  /// The app came to the foreground: the one moment a lost microphone can be
  /// rebuilt for sure.
  func applicationDidBecomeActive() {
    guard shouldBeRunning else { return }
    checkLiveness()
    process(.appBecameActive)
  }

  var hasActiveSegment: Bool {
    fileLock.lock()
    defer { fileLock.unlock() }
    return activeFile != nil
  }

  var routeDescription: String {
    let route = AVAudioSession.sharedInstance().currentRoute
    let inputs = route.inputs.map { "\($0.portType.rawValue):\($0.portName)" }
    let outputs = route.outputs.map { "\($0.portType.rawValue):\($0.portName)" }
    return "input=[\(inputs.joined(separator: ","))] output=[\(outputs.joined(separator: ","))]"
  }

  func errorSummary(_ error: Error) -> String {
    let nsError = error as NSError
    return "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
  }
}
