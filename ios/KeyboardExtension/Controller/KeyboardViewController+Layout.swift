import CryptoKit
import Darwin
import UIKit

extension KeyboardViewController {
  func buildInterface() {
    view.backgroundColor = Self.keyboardBackgroundColor

    let height = view.heightAnchor.constraint(
      equalToConstant: preferredKeyboardHeight
    )
    height.priority = .defaultHigh
    height.isActive = true
    keyboardHeightConstraint = height

    // The suggestion strip fills the whole width; the dictation status and its
    // buttons float on top of it and replace it while they have something to say.
    let toolbar = UIView()
    suggestionBar.translatesAutoresizingMaskIntoConstraints = false
    toolbar.addSubview(suggestionBar)
    let statusRow = makeToolbar()
    statusRow.translatesAutoresizingMaskIntoConstraints = false
    statusOverlay.addSubview(statusRow)
    for subview in [toolbar, keyboardSurface, statusOverlay] {
      subview.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(subview)
    }
    #if VELIKIY_MOGUCHIY_KK
      keyboardSurface.attach(to: self)
    #endif
    microphoneButton.attach(to: keyboardSurface)
    typingMonitor.attach(to: keyboardSurface)
    keyboardSurface.onKeyOutput = { [weak self] in self?.typingMonitor.noteOutput() }

    let toolbarHeight = toolbar.heightAnchor.constraint(
      equalToConstant: CGFloat(keyboardSurface.geometry.topHeight(showsStrip: showsSuggestionStrip)))
    let gridHeight = keyboardSurface.heightAnchor.constraint(
      equalToConstant: keyboardSurface.gridHeight)
    // Hangs from the bottom, not the top: on every globe switch iOS first gives
    // the new keyboard a much taller frame and only applies our height after
    // the first draw. Bottom-anchored keys stay put during that frame instead
    // of jumping up and leaving an empty band above the system bar.
    let gridBottom = keyboardSurface.bottomAnchor.constraint(
      equalTo: view.bottomAnchor, constant: -CGFloat(keyboardSurface.geometry.bottomPadding))
    let overlayHeight = statusOverlay.heightAnchor.constraint(
      equalToConstant: statusOverlayHeight)
    toolbarHeightConstraint = toolbarHeight
    gridHeightConstraint = gridHeight
    gridBottomConstraint = gridBottom
    statusOverlayHeightConstraint = overlayHeight

    NSLayoutConstraint.activate([
      toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      toolbar.topAnchor.constraint(greaterThanOrEqualTo: view.topAnchor),
      toolbarHeight,
      suggestionBar.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
      suggestionBar.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
      suggestionBar.topAnchor.constraint(equalTo: toolbar.topAnchor),
      suggestionBar.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
      statusOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      statusOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      statusOverlay.topAnchor.constraint(equalTo: toolbar.topAnchor),
      overlayHeight,
      statusRow.leadingAnchor.constraint(equalTo: statusOverlay.leadingAnchor, constant: 14),
      statusRow.trailingAnchor.constraint(equalTo: statusOverlay.trailingAnchor, constant: -10),
      statusRow.topAnchor.constraint(equalTo: statusOverlay.topAnchor),
      statusRow.bottomAnchor.constraint(equalTo: statusOverlay.bottomAnchor),
      keyboardSurface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      keyboardSurface.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      keyboardSurface.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
      gridHeight,
      gridBottom,
    ])
    updateStatusOverlay()
  }

  /// Phones use the shorter landscape rows when the screen is wide and low.
  var currentGeometry: KeyboardGeometry {
    let isLandscape =
      traitCollection.verticalSizeClass == .compact
      && traitCollection.userInterfaceIdiom == .phone
    return isLandscape ? .landscape : .portrait
  }

  var preferredKeyboardHeight: CGFloat {
    let geometry = currentGeometry
    return CGFloat(geometry.topHeight(showsStrip: showsSuggestionStrip))
      + keyboardSurface.topAdjustment + keyboardSurface.gridHeight + keyboardSurface.bottomPadding
  }

  /// The strip itself, or (without a strip) the space above the keys plus the
  /// top key row, which the overlay covers.
  var statusOverlayHeight: CGFloat {
    let geometry = keyboardSurface.geometry
    guard !showsSuggestionStrip else { return CGFloat(geometry.toolbarHeight) }
    return CGFloat(geometry.topHeight(showsStrip: false) + geometry.keyHeight + geometry.rowGap / 2)
  }

  func updateKeyboardHeight() {
    let geometry = currentGeometry
    if keyboardSurface.geometry != geometry {
      keyboardSurface.geometry = geometry
    }
    gridBottomConstraint?.constant = -keyboardSurface.bottomPadding
    gridHeightConstraint?.constant = keyboardSurface.gridHeight
    toolbarHeightConstraint?.constant =
      CGFloat(geometry.topHeight(showsStrip: showsSuggestionStrip)) + keyboardSurface.topAdjustment
    statusOverlayHeightConstraint?.constant = statusOverlayHeight
    let height = preferredKeyboardHeight
    guard keyboardHeightConstraint?.constant != height else { return }
    keyboardHeightConstraint?.constant = height
  }

  /// Over the strip the status sits under the keys' popups; without a strip it
  /// covers the top row, and only while there is something to show.
  func updateStatusOverlay() {
    if showsSuggestionStrip {
      statusOverlay.backdrop.isHidden = true
      statusOverlay.isHidden = false
      view.insertSubview(statusOverlay, belowSubview: keyboardSurface)
      return
    }
    let showsStatus = !processingStatusStack.isHidden && processingStatusStack.alpha > 0
    let hasContent =
      showsStatus || !cancelButton.isHidden || !insertLatestButton.isHidden || !timerLabel.isHidden
    statusOverlay.backdrop.isHidden = !hasContent
    statusOverlay.isHidden = !hasContent
    view.bringSubviewToFront(statusOverlay)
  }

  func makeToolbar() -> UIView {
    let stack = UIStackView()
    stack.axis = .horizontal
    stack.alignment = .center
    stack.spacing = 8

    // Status text sits where Apple shows the predictive bar. It stays empty
    // while idle so the keyboard looks like the system one.
    processingStatusStack.axis = .horizontal
    processingStatusStack.alignment = .center
    processingStatusStack.spacing = 6
    processingStatusStack.isHidden = true
    processingStatusStack.isAccessibilityElement = true
    processingStatusStack.accessibilityIdentifier = "keyboard-processing-status"
    processingStatusStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
    processingStatusStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    processingIndicator.color = .systemBlue
    processingIndicator.hidesWhenStopped = true

    processingLabel.font = .systemFont(ofSize: 14, weight: .semibold)
    processingLabel.textColor = Self.keyForegroundColor
    processingLabel.lineBreakMode = .byTruncatingTail
    processingLabel.adjustsFontSizeToFitWidth = true
    processingLabel.minimumScaleFactor = 0.78
    processingLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    processingStatusStack.addArrangedSubview(processingIndicator)
    processingStatusStack.addArrangedSubview(processingLabel)

    let spacer = UIView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    timerLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    timerLabel.textColor = .systemRed
    timerLabel.textAlignment = .right
    timerLabel.isHidden = true
    let timerWidth = timerLabel.widthAnchor.constraint(equalToConstant: 44)
    timerWidth.priority = .defaultHigh
    timerWidth.isActive = true

    stack.addArrangedSubview(processingStatusStack)
    stack.addArrangedSubview(spacer)
    stack.addArrangedSubview(timerLabel)
    stack.addArrangedSubview(makeDictationRow())
    return stack
  }

  func makeDictationRow() -> UIStackView {
    let stack = UIStackView()
    stack.axis = .horizontal
    stack.alignment = .center
    stack.spacing = 6

    var cancelConfiguration = UIButton.Configuration.tinted()
    cancelConfiguration.cornerStyle = .capsule
    cancelConfiguration.baseBackgroundColor = .secondaryLabel
    cancelConfiguration.baseForegroundColor = .secondaryLabel
    cancelConfiguration.image = UIImage(systemName: "xmark")
    cancelConfiguration.contentInsets = .zero
    cancelButton.configuration = cancelConfiguration
    cancelButton.accessibilityLabel = "Отменить диктовку и отбросить результат"
    cancelButton.accessibilityHint =
      "Останавливает запись или обработку, ничего не вставляя в поле"
    cancelButton.accessibilityIdentifier = "keyboard-cancel-button"
    cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
    cancelButton.isEnabled = false
    // Matches `updateActionVisibility`, which first runs only after the first draw.
    cancelButton.isHidden = true
    prepareActionButton(cancelButton)

    var insertConfiguration = UIButton.Configuration.tinted()
    insertConfiguration.cornerStyle = .capsule
    insertConfiguration.baseBackgroundColor = .systemBlue
    insertConfiguration.baseForegroundColor = .systemBlue
    insertConfiguration.image = UIImage(systemName: "arrow.down.doc.fill")
    insertConfiguration.imagePadding = 7
    insertConfiguration.title = "Вставить"
    insertLatestButton.configuration = insertConfiguration
    insertLatestButton.accessibilityLabel = "Вставить последний продиктованный текст"
    insertLatestButton.accessibilityIdentifier = "keyboard-insert-latest-button"
    insertLatestButton.addTarget(self, action: #selector(insertLatestTapped), for: .touchUpInside)
    insertLatestButton.isHidden = true
    prepareActionButton(insertLatestButton)

    stack.addArrangedSubview(insertLatestButton)
    stack.addArrangedSubview(cancelButton)
    for button in [cancelButton] {
      NSLayoutConstraint.activate([
        button.widthAnchor.constraint(equalToConstant: 44),
        button.heightAnchor.constraint(equalToConstant: 36),
      ])
    }
    return stack
  }

  func prepareActionButton(_ button: KeyboardButton) {
    button.isExclusiveTouch = true
    button.accessibilityTraits.insert(.button)
    button.layer.cornerCurve = .continuous
  }
}
