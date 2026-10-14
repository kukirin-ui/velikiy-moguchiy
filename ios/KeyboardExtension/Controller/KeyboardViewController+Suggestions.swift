import UIKit

extension KeyboardViewController {
  /// The user's text replacements (Settings → General → Keyboard → Text
  /// Replacement) come through `UILexicon`, which needs no Full Access.
  func loadTextReplacements() {
    requestSupplementaryLexicon { [weak self] lexicon in
      let pairs = lexicon.entries.map { (userInput: $0.userInput, documentText: $0.documentText) }
      guard let self else { return }
      self.suggestionEngine.queue.async {
        self.suggestionEngine.setReplacements(TextReplacementTable(pairs: pairs))
      }
    }
  }

  /// Predictions and corrections make sense in ordinary text only: not in
  /// URL / e-mail / number fields, secure fields, or fields that turn
  /// autocorrection off.
  var fieldAllowsSuggestions: Bool {
    guard !currentInputKind.isTechnical else { return false }
    if textDocumentProxy.isSecureTextEntry == true { return false }
    if textDocumentProxy.autocorrectionType == .some(.no) { return false }
    return true
  }

  var smartPunctuationSettings: SmartPunctuationSettings {
    SmartPunctuationSettings.resolve(
      quotes: textDocumentProxy.smartQuotesType,
      dashes: textDocumentProxy.smartDashesType,
      inputKind: currentInputKind
    )
  }

  /// Rebuilds the three candidates for the word before the cursor off the main
  /// thread; a stale result (the user typed on) is dropped.
  func refreshSuggestions() {
    suggestionGeneration += 1
    let generation = suggestionGeneration
    guard fieldAllowsSuggestions, mode == .idle else {
      suggestionBar.clear()
      updateSuggestionBarVisibility()
      return
    }
    // One job at a time and only for the newest text: while the dictionary is
    // busy, keystrokes replace the waiting request instead of queueing their
    // own, so a word boundary (which waits for the queue) never waits long.
    pendingSuggestion = (textDocumentProxy.documentContextBeforeInput, generation)
    guard !suggestionJobRunning else { return }
    runPendingSuggestion()
  }

  private func runPendingSuggestion() {
    guard let request = pendingSuggestion else {
      suggestionJobRunning = false
      return
    }
    pendingSuggestion = nil
    suggestionJobRunning = true
    suggestionEngine.queue.async { [weak self] in
      guard let self else { return }
      let result = self.suggestionEngine.suggestions(contextBefore: request.context)
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        if self.suggestionGeneration == request.generation {
          self.suggestionBar.show(result)
          self.updateSuggestionBarVisibility()
        }
        self.runPendingSuggestion()
      }
    }
  }

  /// The host updates `documentContextBeforeInput` asynchronously, so look at
  /// the context again on the next run loop turn.
  func refreshTextStateSoon() {
    DispatchQueue.main.async { [weak self] in
      self?.updateAutomaticCapitalization()
      self?.refreshSuggestions()
    }
  }

  /// Tap on a candidate: replace the word being typed and add a space.
  func applySuggestion(_ suggestion: Suggestion) {
    store.noteKeyboardActive()
    // An empty word means a sentence starter («Я», "I"): nothing to replace.
    let partial = WordBoundary.partialWord(contextBefore: textDocumentProxy.documentContextBeforeInput)
    for _ in 0..<partial.count { textDocumentProxy.deleteBackward() }
    textDocumentProxy.insertText(suggestion.text + " ")
    if suggestion.isTypedWord {
      // "Keep it as typed": do not correct this word again.
      suggestionEngine.queue.async { [engine = suggestionEngine] in engine.reject(partial) }
    }
    lastReplacement = nil
    lastSpaceInsertedAt = nil
    suggestionBar.clear()
    updateSuggestionBarVisibility()
    refreshTextStateSoon()
  }

  // MARK: Typing

  /// One key press worth of text: text replacements and corrections at word
  /// boundaries, smart punctuation, Apple's double-space period.
  func typeText(_ text: String) {
    store.noteKeyboardActive()
    var context = textDocumentProxy.documentContextBeforeInput
    var replaced: BoundaryReplacement?

    if WordBoundary.isBoundary(text), fieldAllowsSuggestions || !suggestionEngine.replacements.isEmpty,
      mode == .idle
    {
      let canAutocorrect = autocorrectEnabled && fieldAllowsSuggestions
      let plan = suggestionEngine.queue.sync {
        suggestionEngine.replacement(contextBefore: context, autocorrectEnabled: canAutocorrect)
      }
      if let plan {
        for _ in 0..<plan.original.count { textDocumentProxy.deleteBackward() }
        textDocumentProxy.insertText(plan.replacement)
        context = String((context ?? "").dropLast(plan.original.count)) + plan.replacement
        replaced = plan
      }
    }

    if text == " ", replaced == nil, shouldReplaceDoubleSpaceWithPeriod() {
      // Apple's "." shortcut: a second quick space after a word becomes ". ".
      textDocumentProxy.deleteBackward()
      textDocumentProxy.insertText(". ")
      lastSpaceInsertedAt = nil
      lastReplacement = nil
    } else {
      let edit = SmartPunctuation.edit(
        typing: text,
        contextBefore: context,
        language: KeyboardLayoutLanguage(dictationLanguage: Self.dictationLanguage),
        settings: smartPunctuationSettings
      )
      for _ in 0..<edit.deleteBackwardCount { textDocumentProxy.deleteBackward() }
      lastSpaceInsertedAt = text == " " ? Date() : nil
      textDocumentProxy.insertText(edit.insert)
      lastReplacement = replaced.map { ($0, text) }
    }
    refreshTextStateSoon()
  }

  func shouldReplaceDoubleSpaceWithPeriod() -> Bool {
    guard let last = lastSpaceInsertedAt, Date().timeIntervalSince(last) < 0.6,
      let context = textDocumentProxy.documentContextBeforeInput,
      context.hasSuffix(" "),
      let beforeSpace = context.dropLast().last,
      beforeSpace.isLetter || beforeSpace.isNumber
    else { return false }
    return true
  }

  /// ⌫ right after an automatic replacement puts the original word back (without
  /// the boundary character) and keeps it from being corrected again.
  func revertLastReplacementIfPossible() -> Bool {
    guard let last = lastReplacement else { return false }
    lastReplacement = nil
    let context = textDocumentProxy.documentContextBeforeInput ?? ""
    let expected = last.plan.replacement + last.boundary
    guard context.hasSuffix(expected) else { return false }
    for _ in 0..<expected.count { textDocumentProxy.deleteBackward() }
    textDocumentProxy.insertText(last.plan.original)
    if last.plan.isAutocorrect {
      suggestionEngine.queue.async { [engine = suggestionEngine] in
        engine.reject(last.plan.original)
      }
    }
    refreshTextStateSoon()
    return true
  }
}
