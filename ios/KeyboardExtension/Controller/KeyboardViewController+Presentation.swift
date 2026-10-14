import CryptoKit
import Darwin
import UIKit

extension KeyboardViewController {
  /// States of the dictation key (which sits in Apple's emoji-key slot).
  enum MicrophoneState {
    case dictate
    case finish
    case transcribing
    case tryAgain
    /// The microphone is off: pressing opens the app and starts a session.
    case openAndDictate
    case opening
    case starting
    case needsKey

    var systemImage: String {
      switch self {
      case .finish: return "arrow.up"
      case .transcribing: return "ellipsis"
      case .starting: return "waveform"
      case .needsKey: return "key.slash"
      default: return "mic.fill"
      }
    }

    var accessibilityLabel: String {
      switch self {
      case .dictate: return "Начать диктовку"
      case .finish: return "Закончить диктовку и вставить текст"
      case .transcribing: return "Распознаю речь"
      case .tryAgain: return "Начать диктовку снова"
      case .openAndDictate: return "Открыть «Великий & Могучий» и начать диктовку"
      case .opening: return "Открываю «Великий & Могучий»"
      case .starting: return "Запускаю диктовку"
      case .needsKey: return "Нужен ключ DashScope"
      }
    }

    var accessibilityHint: String? {
      self == .finish ? "Завершает запись и отправляет её на распознавание" : nil
    }
  }

  func configureMicrophone(_ state: MicrophoneState) {
    // "Finish" is the recording state: the key turns blue with an up arrow.
    microphoneButton.update(systemImage: state.systemImage, isActive: state == .finish)
    microphoneButton.accessibilityLabel = state.accessibilityLabel
    microphoneButton.accessibilityHint = state.accessibilityHint
  }

  var keyboardHasUsableAPIKey: Bool {
    store.apiKeyIsAvailable
  }

  /// Name under which this keyboard's typing measurements are stored.
  static var typingStatsID: String {
    #if VELIKIY_MOGUCHIY_KK
      let prefix = "kk-"
    #else
      let prefix = ""
    #endif
    return prefix + (dictationLanguage == .russian ? "ru" : "en")
  }

  /// Language of this keyboard, fixed by the extension's Info.plist: the RU
  /// keyboard dictates Russian, the EN keyboard English.
  static var dictationLanguage: DictationLanguage {
    DictationLanguage.resolve(
      Bundle.main.object(forInfoDictionaryKey: "VelikiyMoguchiyKeyboardLanguage") as? String
    )
  }

  func presentMissingCredential() {
    configureMicrophone(.needsKey)
    // Stays tappable: the tap is what brings up the explanation.
    microphoneButton.isEnabled = true
    cancelButton.isEnabled = false
    timerLabel.isHidden = true
    keyboardSurface.setTypingEnabled(true)
    processingIndicator.stopAnimating()
    setStatus(CredentialAvailability.keyboardMessage, color: .systemOrange, isAdvice: true)
  }

  var adviceIsRevealed: Bool {
    adviceRevealedUntil.map { $0 > Date() } ?? false
  }

  /// Shows idle hints for a few seconds, then hides them again.
  func revealAdvice(for duration: TimeInterval = 5) {
    adviceRevealedUntil = Date().addingTimeInterval(duration)
    DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) { [weak self] in
      guard let self, self.keyboardIsVisible, !self.adviceIsRevealed else { return }
      self.refreshFromSharedState()
    }
  }

  /// The × and the last-result button show only while they can be used, so an
  /// idle toolbar looks like Apple's empty predictive strip.
  func updateActionVisibility() {
    cancelButton.isHidden = !cancelButton.isEnabled
    updateSuggestionBarVisibility()
  }

  /// Suggestions take the strip whenever there is no status text to show. Plain
  /// advice ("Приём выключен …") gives way to them while a word is being typed;
  /// real news (recording, errors, results) never does.
  func updateSuggestionBarVisibility() {
    let hasStatus = !processingStatusStack.isHidden
    let suggestionsWin = hasStatus && statusIsAdvice && suggestionBar.hasContent
    suggestionBar.isHidden = !showsSuggestionStrip || (hasStatus && !suggestionsWin)
    // A digit pad has no microphone and nothing to suggest: no status either.
    processingStatusStack.alpha = (suggestionsWin || currentInputKind.isDigitPad) ? 0 : 1
    updateStatusOverlay()
  }

  func updateCancelAccessibility() {
    switch mode {
    case .openingHost:
      cancelButton.accessibilityLabel = "Отменить открытие «Великого & Могучего»"
      cancelButton.accessibilityHint = "Отменяет запрос до начала записи"
    case .recording:
      cancelButton.accessibilityLabel = "Отменить диктовку"
      cancelButton.accessibilityHint = "Останавливает и отбрасывает запись, ничего не вставляя"
    case .transcribing:
      cancelButton.accessibilityLabel = "Отменить распознавание"
      cancelButton.accessibilityHint = "Останавливает обработку и отбрасывает результат"
    case .cancelling:
      cancelButton.accessibilityLabel = "Отменяю"
      cancelButton.accessibilityHint = nil
    case .idle, .resultWaiting:
      cancelButton.accessibilityLabel = "Отмена"
      cancelButton.accessibilityHint = nil
    }
  }

  func updateRecordingPresentation(with snapshot: RelaySnapshot) {
    // The keys stay visible while dictating (like Apple's keyboard does) but
    // typing is locked so the insertion anchor cannot move under the result.
    let isBusy = mode == .recording || mode == .transcribing || mode == .cancelling
    keyboardSurface.setTypingEnabled(!isBusy)
  }

  func updateProcessingPresentation(with snapshot: RelaySnapshot) {
    if mode == .transcribing {
      let label = "Распознаю…"
      processingLabel.text = label
      processingLabel.textColor = Self.keyForegroundColor
      processingStatusStack.accessibilityLabel = label
      processingStatusStack.isHidden = false
      processingIndicator.color = .systemBlue
      processingIndicator.startAnimating()
      return
    }

    if snapshot.status == .error, mode != .idle || adviceIsRevealed {
      processingIndicator.stopAnimating()
      processingLabel.text = snapshot.message
      processingLabel.textColor = .systemOrange
      processingStatusStack.accessibilityLabel = snapshot.message
      processingStatusStack.isHidden = false
      return
    }

    processingIndicator.stopAnimating()
    processingLabel.textColor = Self.keyForegroundColor
    processingStatusStack.isHidden = true
    processingStatusStack.accessibilityLabel = nil
    statusIsAdvice = false
    updateSuggestionBarVisibility()
  }

  /// Advice is an idle hint rather than news about a running dictation; it
  /// stays hidden unless `revealAdvice()` was called a moment ago.
  func setStatus(_ text: String, color: UIColor, isAdvice: Bool = false) {
    guard !text.isEmpty else { return }
    if isAdvice, !adviceIsRevealed {
      processingStatusStack.isHidden = true
      processingStatusStack.accessibilityLabel = nil
      statusIsAdvice = false
      updateSuggestionBarVisibility()
      return
    }
    // "Приём выключен …" is advice, not an alarm: neutral color.
    let isPaused = text.hasPrefix("Приём выключен")
    statusIsAdvice = isAdvice
    processingLabel.text = text
    processingLabel.textColor = isPaused ? .secondaryLabel : color
    processingStatusStack.accessibilityLabel = text
    processingStatusStack.isHidden = false
    if mode != .transcribing && mode != .openingHost { processingIndicator.stopAnimating() }
    updateSuggestionBarVisibility()
  }
}
