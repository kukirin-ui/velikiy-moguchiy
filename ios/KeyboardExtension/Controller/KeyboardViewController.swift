import CryptoKit
import Darwin
import UIKit

#if VELIKIY_MOGUCHIY_KK
  import KeyboardKit

  /// The Великий & Могучий KK keyboards run on KeyboardKit's controller, which keeps its
  /// keyboard context in sync with the text field.
  typealias KeyboardBaseViewController = KeyboardInputViewController
#else
  typealias KeyboardBaseViewController = UIInputViewController
#endif

extension KeyboardLayoutLanguage {
  init(dictationLanguage: DictationLanguage) {
    self = dictationLanguage == .russian ? .russian : .english
  }
}

/// Mirrors the state of the dictation key that lives inside the key grid (in
/// Apple's emoji-key slot) so the relay-state code can keep treating the
/// microphone like a button.
final class MicrophoneKeyProxy {
  weak var surface: KeyboardSurfaceView?
  private(set) var presentation = KeyboardSurfaceView.MicrophonePresentation() {
    didSet { surface?.setMicrophone(presentation) }
  }

  var isEnabled: Bool {
    get { presentation.isEnabled }
    set { presentation.isEnabled = newValue }
  }

  var accessibilityLabel: String? {
    get { presentation.accessibilityLabel }
    set { presentation.accessibilityLabel = newValue ?? "" }
  }

  var accessibilityHint: String?

  func update(systemImage: String, isActive: Bool) {
    presentation.systemImage = systemImage
    presentation.isActive = isActive
  }

  func attach(to surface: KeyboardSurfaceView) {
    self.surface = surface
    surface.setMicrophone(presentation)
  }
}

final class KeyboardViewController: KeyboardBaseViewController, UIInputViewAudioFeedback {
  enum LocalKey {
    static let consumedResultSequence = "keyboard.consumed-result-sequence"
    static let activeRequestID = "keyboard.active-request-id"
    static let activeRequestAction = "keyboard.active-request-action"
    static let activeRequestCreatedAt = "keyboard.active-request-created-at"
    static let activeRequestIsCancelling = "keyboard.active-request-is-cancelling"
    static let activeDocumentIdentifier = "keyboard.active-document-identifier"
    static let contextBeforeFingerprint = "keyboard.active-context-before-fingerprint"
    static let contextAfterFingerprint = "keyboard.active-context-after-fingerprint"
    static let awaitsKeyboardReactivation = "keyboard.active-awaits-reactivation"
    static let legacyContextBefore = "keyboard.active-context-before"
    static let legacyContextAfter = "keyboard.active-context-after"
  }

  enum DictationMode {
    case idle
    case openingHost
    case recording
    case cancelling
    case transcribing
    case resultWaiting
  }

  let store = SharedRelayStore()
  var pollingTimer: Timer?
  var mode: DictationMode = .idle
  var keyboardIsVisible = false
  var lastSpaceInsertedAt: Date?
  var stopIssuedAt: Date?
  var lastFallbackCheckAt = Date.distantPast

  var activeRequestID: String?
  var activeDocumentIdentifier: UUID?
  var contextBeforeFingerprintAtRequest: String?
  var contextAfterFingerprintAtRequest: String?
  var lastObservedResultSequence = 0
  var pendingTranscript: String?
  var pendingResultSequence: Int?
  var pendingResultKind: RelayResultKind?
  var activeDictationAction: RelayDictationAction?
  var trackedRequestCreatedAt: Date?
  var hostLaunchFailureExpiresAt: Date?
  var hostLaunchAttemptedForRequestID: String?
  var hostResolutionPendingForRequestID: String?
  var hostResolutionGeneration = 0
  var recentArbiterHosts: [Int32: (bundleIdentifier: String, observedAt: Date)] = [:]
  #if VELIKIY_MOGUCHIY_PERSONAL_DEVICE
    static var keyboardArbiterEnabledOverrideInstalled = false
  #endif
  var awaitsKeyboardReactivation = false
  var keyboardReactivationIsReady = false
  var keyboardActivationGeneration = 0
  var keyboardSettleWorkItem: DispatchWorkItem?

  let suggestionBar = SuggestionBarView()
  let suggestionEngine = SuggestionEngine(
    language: KeyboardLayoutLanguage(dictationLanguage: KeyboardViewController.dictationLanguage))
  var suggestionGeneration = 0
  var pendingSuggestion: (context: String?, generation: Int)?
  var suggestionJobRunning = false
  /// The last automatic replacement, kept until the next key so ⌫ can undo it.
  var lastReplacement: (plan: BoundaryReplacement, boundary: String)?
  var autocorrectEnabled = false
  var currentInputKind = KeyboardInputKind.standard
  var currentPollingInterval: TimeInterval = 1
  var toolbarHeightConstraint: NSLayoutConstraint?
  var gridHeightConstraint: NSLayoutConstraint?
  var gridBottomConstraint: NSLayoutConstraint?
  var statusOverlayHeightConstraint: NSLayoutConstraint?
  let statusOverlay = StatusOverlayView()
  /// Set from the text field: Apple drops the strip in some technical fields.
  var showsSuggestionStrip = true
  /// Idle hints ("Приём выключен …", a missing key) show only for a moment
  /// after a microphone tap, so the strip looks like Apple's the rest of the time.
  var adviceRevealedUntil: Date?
  var statusIsAdvice = false
  lazy var typingMonitor = TypingMonitor(
    stored: store.typingStats(keyboard: Self.typingStatsID)
  ) { [weak self] stats in
    self?.store.saveTypingStats(stats, keyboard: Self.typingStatsID)
  }
  var lastActivityNoteAt = Date.distantPast

  let rootStack = UIStackView()
  let keyboardSurface = KeyboardSurfaceView(
    language: KeyboardLayoutLanguage(dictationLanguage: KeyboardViewController.dictationLanguage)
  )
  var keyboardHeightConstraint: NSLayoutConstraint?
  let processingStatusStack = UIStackView()
  let processingIndicator = UIActivityIndicatorView(style: .medium)
  let processingLabel = UILabel()
  let timerLabel = UILabel()
  let microphoneButton = MicrophoneKeyProxy()
  let cancelButton = KeyboardButton(type: .system)
  let insertLatestButton = KeyboardButton(type: .system)

  /// Current key-feedback decision, refreshed from the shared settings and
  /// Full Access in `viewWillAppear`.
  private(set) var keyFeedbackPolicy = KeyFeedbackPolicy.initial

  /// Input clicks need the visible input view to adopt `UIInputViewAudioFeedback`;
  /// the system then still honors Settings → Sounds → Keyboard Clicks.
  var enableInputClicksWhenVisible: Bool { keyFeedbackPolicy.shouldPlayClick }

  #if VELIKIY_MOGUCHIY_KK
    /// KeyboardKit would cover the whole controller view with its keyboard;
    /// here its keys live inside `keyboardSurface`, under our strip.
    override func viewWillSetupKeyboardView() {}
  #endif

  /// Same view class UIKit would create (a keyboard-style `UIInputView`), but
  /// one that adopts `UIInputViewAudioFeedback`.
  override func loadView() {
    view = KeyboardInputView(frame: .zero, inputViewStyle: .keyboard)
  }

  /// Reads the haptics / click settings (shared with the app) and Full Access.
  /// Cheap; runs once per keyboard appearance, never per keystroke.
  func refreshKeyFeedbackPolicy() {
    keyFeedbackPolicy = KeyFeedbackPolicy(
      hasFullAccess: hasFullAccess,
      hapticsEnabled: store.keyHapticsEnabled,
      clickSoundEnabled: store.keyClickSoundEnabled
    )
    keyboardSurface.feedbackPolicy = keyFeedbackPolicy
    (view as? KeyboardInputView)?.clicksEnabled = keyFeedbackPolicy.shouldPlayClick
    keyboardSurface.feedback.prepare()
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    // This keyboard has its own dictation key; without this iOS draws a second
    // (system) microphone next to ours.
    hasDictationKey = true
    lastObservedResultSequence = store.consumedResultSequence
    restoreTrackedRequest()
    store.onRemoteChange = { [weak self] in
      DispatchQueue.main.async { [weak self] in
        self?.store.refreshFromRemote()
        self?.refreshFromSharedState()
      }
    }
    keyboardSurface.delegate = self
    suggestionBar.onSelect = { [weak self] suggestion in self?.applySuggestion(suggestion) }
    buildInterface()
    loadTextReplacements()
    registerForTraitChanges([UITraitVerticalSizeClass.self]) { (controller: Self, _) in
      controller.updateKeyboardHeight()
    }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    autocorrectEnabled = store.autocorrectEnabled
    refreshKeyFeedbackPolicy()
    syncKeyboardSurfaceContext()
    updateAutomaticCapitalization()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    keyboardActivationGeneration += 1
    keyboardIsVisible = true
    // The other VelikiyMoguchiy keyboard may have started or finished a dictation while
    // this one was in the background; the request lives in the shared store.
    lastObservedResultSequence = max(lastObservedResultSequence, store.consumedResultSequence)
    if activeRequestID == nil, store.trackedRequest != nil {
      restoreTrackedRequest()
    }
    if awaitsKeyboardReactivation {
      keyboardReactivationIsReady = false
    }
    // Showing the keyboard counts as use: the app restarts its idle countdown.
    store.noteKeyboardActive(minimumInterval: 5)
    removeEdgeTouchDelay()
    refreshFromSharedState()
    startPolling()
    scheduleKeyboardSettleIfNeeded(after: 0.22)
    refreshSuggestions()
  }

  /// iOS holds back touches near the screen edge to see whether they start a
  /// system gesture, so the first and last keys of a row react late. Apple's own
  /// keyboard is exempt; for ours the delay is switched off on the window's
  /// system-gesture gate recognizers. Looked up by name, and a no-op if absent.
  func removeEdgeTouchDelay() {
    view.window?.gestureRecognizers?
      .filter { String(describing: type(of: $0)).contains("SystemGestureGate") }
      .forEach { $0.delaysTouchesBegan = false }
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    keyboardActivationGeneration += 1
    hostResolutionGeneration += 1
    hostResolutionPendingForRequestID = nil
    recentArbiterHosts.removeAll()
    keyboardSettleWorkItem?.cancel()
    keyboardSettleWorkItem = nil
    keyboardIsVisible = false
    keyboardReactivationIsReady = false
    typingMonitor.flush()
    processingIndicator.stopAnimating()
    pollingTimer?.invalidate()
    pollingTimer = nil
    keyboardSurface.resetTransientState()
  }

  override func viewWillLayoutSubviews() {
    super.viewWillLayoutSubviews()
    syncKeyboardSurfaceContext()
    updateKeyboardHeight()
  }

  override func viewSafeAreaInsetsDidChange() {
    super.viewSafeAreaInsetsDidChange()
    updateKeyboardHeight()
  }

  /// iOS 26 draws its own translucent keyboard backdrop behind the view, so
  /// the view itself stays clear and the system keyboard material shows.
  static let keyboardBackgroundColor = UIColor.clear

  static let keyForegroundColor = UIColor { traits in
    traits.userInterfaceStyle == .dark ? .white : .black
  }

  override func textDidChange(_ textInput: UITextInput?) {
    super.textDidChange(textInput)
    syncKeyboardSurfaceContext()
    updateAutomaticCapitalization()
    refreshSuggestions()
    // Host apps can replace the text proxy just after the keyboard appears.
    // Restart the short settle window so the insertion anchor is captured
    // from the final proxy rather than its transition placeholder.
    scheduleKeyboardSettleIfNeeded(after: 0.16)
    // Every keystroke ends up here; the shared state is only worth reading
    // while a dictation is on the way.
    if mode != .idle || awaitsKeyboardReactivation {
      refreshFromSharedState()
    }
  }

  func scheduleKeyboardSettleIfNeeded(after delay: TimeInterval) {
    guard awaitsKeyboardReactivation, keyboardIsVisible else { return }
    let activationGeneration = keyboardActivationGeneration
    // Any proxy/context change starts a fresh quiet window. Do not let a
    // previously completed settle authorize Start while the host is still
    // replacing its text input connection.
    keyboardReactivationIsReady = false
    keyboardSettleWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      guard let self,
        self.keyboardActivationGeneration == activationGeneration,
        self.keyboardIsVisible,
        self.view.window != nil,
        self.awaitsKeyboardReactivation
      else {
        return
      }
      self.keyboardSettleWorkItem = nil
      self.keyboardReactivationIsReady = true
      self.refreshFromSharedState()
    }
    keyboardSettleWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
  }

  func updateAutomaticCapitalization() {
    let requested = AutocapitalizationRules.capitalization(
      type: textDocumentProxy.autocapitalizationType ?? .sentences,
      contextBefore: textDocumentProxy.documentContextBeforeInput
    )
    keyboardSurface.applyAutomaticCapitalization(requested)
  }

  func syncKeyboardSurfaceContext() {
    let profile = KeyboardInputProfile.resolve(
      keyboardType: textDocumentProxy.keyboardType,
      returnKeyType: textDocumentProxy.returnKeyType,
      autocorrectionType: textDocumentProxy.autocorrectionType
    )
    currentInputKind = profile.kind
    if showsSuggestionStrip != profile.showsSuggestionStrip {
      showsSuggestionStrip = profile.showsSuggestionStrip
      updateKeyboardHeight()
      updateSuggestionBarVisibility()
    }
    keyboardSurface.updateInputContext(
      kind: profile.kind,
      returnKeyType: textDocumentProxy.returnKeyType ?? .default,
      needsInputModeSwitchKey: needsInputModeSwitchKey,
      startsOnNumbers: profile.startsOnNumbers
    )
    // Apple greys out Return in fields that want text first.
    let returnWaitsForText =
      (textDocumentProxy.enablesReturnKeyAutomatically ?? false)
      && !textDocumentProxy.hasText
    keyboardSurface.setReturnKeyEnabled(!returnWaitsForText)
  }
}
