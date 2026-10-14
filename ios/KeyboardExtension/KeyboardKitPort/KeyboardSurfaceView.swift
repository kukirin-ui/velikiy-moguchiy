import UIKit

// This source ports the small subset of KeyboardKit 9.9.1 behavior that this
// sample needs, while keeping the implementation local and editable.
// Copyright (c) 2016-2025 Daniel Saidi. MIT license; see THIRD_PARTY_NOTICES.md.

protocol KeyboardSurfaceViewDelegate: AnyObject {
  func keyboardSurface(_ surface: KeyboardSurfaceView, insertText text: String)
  func keyboardSurfaceDeleteBackward(_ surface: KeyboardSurfaceView)
  /// Held ⌫ after a while: delete the word before the cursor.
  func keyboardSurfaceDeleteWordBackward(_ surface: KeyboardSurfaceView)
  func keyboardSurface(_ surface: KeyboardSurfaceView, adjustTextPositionBy offset: Int)
  /// Space-bar trackpad: move the cursor up (negative) or down (positive) a line.
  func keyboardSurface(_ surface: KeyboardSurfaceView, moveCursorVerticallyBy lines: Int)
  func keyboardSurfacePlayInputClick(_ surface: KeyboardSurfaceView)
  func keyboardSurfaceMicrophoneTapped(_ surface: KeyboardSurfaceView)
  func keyboardSurface(
    _ surface: KeyboardSurfaceView,
    showInputModeListFrom button: UIButton,
    event: UIEvent
  )
}

extension KeyboardSurfaceViewDelegate {
  func keyboardSurfaceDeleteWordBackward(_ surface: KeyboardSurfaceView) {
    surface.delegate?.keyboardSurfaceDeleteBackward(surface)
  }
  func keyboardSurface(_ surface: KeyboardSurfaceView, moveCursorVerticallyBy lines: Int) {}
}

/// The key grid. One touch handler serves every key (see `KeyTouchTracker`), so
/// fingers that overlap while typing quickly are never lost, a touch always
/// finds the nearest key, and the key under the finger on release is typed.
final class KeyboardSurfaceView: UIView, UIInputViewAudioFeedback {
  weak var delegate: KeyboardSurfaceViewDelegate?
  /// A key finished its job (text handed to the field, delete, shift ...).
  var onKeyOutput: (() -> Void)?

  private(set) var interactionState: KeyboardInteractionState
  private(set) var inputKind: KeyboardInputKind = .standard
  private(set) var needsInputModeSwitchKey = true
  private(set) var returnKeyType: UIReturnKeyType = .default
  private var startsOnNumbers = false
  /// Row heights; the controller switches between portrait and landscape.
  var geometry = KeyboardGeometry.portrait {
    didSet {
      guard geometry != oldValue else { return }
      invalidateIntrinsicContentSize()
      setNeedsLayout()
    }
  }

  private var rows: [KeyboardLayoutRow] = []
  private var rowButtons: [[KeyboardKeyButton]] = []
  private var tracker = KeyTouchTracker()
  private let inputCallout = KeyboardInputCalloutView()
  private let alternateCallout = KeyboardAlternateCalloutView()
  private var typingEnabled = true
  private var returnKeyEnabled = true
  private var microphone = MicrophonePresentation()
  private let accessibilityStrings = KeyboardAccessibilityStrings.current

  // Touch bookkeeping.
  private var touchIDs: [ObjectIdentifier: Int] = [:]
  private var nextTouchID = 1
  private var lastTouchPoints: [Int: CGPoint] = [:]
  private var calloutTouch: Int?
  private var highlightedButtons: [Int: KeyboardKeyButton] = [:]
  private var longPressTimers: [Int: Timer] = [:]
  private var activeAlternateOptions: [String] = []
  private var trackpad: TrackpadCursor?
  private var deleteRepeat = DeleteRepeatController()
  private var deleteTimer: Timer?
  private(set) var isTrackpadActive = false

  /// Hold times before a letter's accent panel and the space-bar trackpad open.
  static let alternatesDelay: TimeInterval = 0.36
  static let trackpadDelay: TimeInterval = 0.4

  /// Haptics for key presses; one reused generator pair (see `KeyFeedbackEngine`).
  let feedback = KeyFeedbackEngine()

  /// Haptic + click policy, applied by the controller on `viewWillAppear`.
  var feedbackPolicy: KeyFeedbackPolicy {
    get { feedback.policy }
    set { feedback.policy = newValue }
  }

  /// The surface also adopts the audio-feedback protocol: the system looks for
  /// an adopting view in the visible keyboard hierarchy.
  var enableInputClicksWhenVisible: Bool { feedbackPolicy.shouldPlayClick }

  /// Appearance of the dictation key that sits in Apple's emoji-key slot.
  struct MicrophonePresentation: Equatable {
    var systemImage = "mic.fill"
    var isActive = false
    var isEnabled = true
    var accessibilityLabel = "Диктовка"
  }

  init(language: KeyboardLayoutLanguage = .english, frame: CGRect = .zero) {
    interactionState = KeyboardInteractionState(language: language)
    super.init(frame: frame)
    clipsToBounds = false
    isMultipleTouchEnabled = true
    let preparer = KeyboardTouchDownPreparer()
    preparer.cancelsTouchesInView = false
    preparer.delaysTouchesBegan = false
    preparer.delaysTouchesEnded = false
    preparer.onTouchDown = { [weak self] in self?.feedback.prepare() }
    addGestureRecognizer(preparer)
    rebuild()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    nil
  }

  deinit {
    longPressTimers.values.forEach { $0.invalidate() }
    deleteTimer?.invalidate()
  }

  /// Total height of the four key rows.
  var gridHeight: CGFloat {
    guard inputKind.isDigitPad, !geometry.isLandscape else { return CGFloat(geometry.gridHeight) }
    return CGFloat(KeyboardMetrics.DigitPad.gridHeight)
  }

  /// Space between the last row and the bottom of the keyboard view.
  var bottomPadding: CGFloat {
    guard inputKind.isDigitPad, !geometry.isLandscape else { return CGFloat(geometry.bottomPadding) }
    return CGFloat(KeyboardMetrics.DigitPad.bottomPadding)
  }

  /// Added to the space above the keys (the digit pad starts a little higher).
  var topAdjustment: CGFloat {
    guard inputKind.isDigitPad, !geometry.isLandscape else { return 0 }
    return CGFloat(KeyboardMetrics.DigitPad.topAdjustment)
  }

  override var intrinsicContentSize: CGSize {
    CGSize(width: UIView.noIntrinsicMetric, height: gridHeight)
  }

  func updateInputContext(
    kind: KeyboardInputKind,
    returnKeyType: UIReturnKeyType,
    needsInputModeSwitchKey: Bool,
    startsOnNumbers: Bool = false
  ) {
    let kindChanged = inputKind != kind
    // `numbersAndPunctuation` resolves to the standard kind, so a field that
    // starts on numbers is a change of its own.
    let startChanged = self.startsOnNumbers != startsOnNumbers
    guard kindChanged || startChanged
      || self.returnKeyType != returnKeyType
      || self.needsInputModeSwitchKey != needsInputModeSwitchKey
    else { return }
    inputKind = kind
    self.returnKeyType = returnKeyType
    self.needsInputModeSwitchKey = needsInputModeSwitchKey
    self.startsOnNumbers = startsOnNumbers
    if kindChanged || startChanged, startsOnNumbers { interactionState.showNumbers() }
    rebuild()
  }

  func applyAutomaticCapitalization(_ capitalization: KeyboardCapitalization) {
    let previous = interactionState.capitalization
    interactionState.applyAutomaticCapitalization(capitalization)
    if interactionState.capitalization != previous {
      relabel()
    }
  }

  /// Dims every key but the microphone, used while a dictation is running so
  /// typed text cannot move the insertion anchor under the pending result.
  func setTypingEnabled(_ enabled: Bool) {
    guard typingEnabled != enabled else { return }
    typingEnabled = enabled
    applyTypingState()
  }

  /// Fields with "enables return key automatically" keep Return off until
  /// there is text.
  func setReturnKeyEnabled(_ enabled: Bool) {
    guard returnKeyEnabled != enabled else { return }
    returnKeyEnabled = enabled
    applyTypingState()
  }

  func setMicrophone(_ presentation: MicrophonePresentation) {
    guard microphone != presentation else { return }
    microphone = presentation
    applyMicrophone()
  }

  func resetTransientState() {
    stopDeleteRepeat()
    longPressTimers.values.forEach { $0.invalidate() }
    longPressTimers.removeAll()
    inputCallout.hide()
    alternateCallout.hide()
    activeAlternateOptions = []
    highlightedButtons.values.forEach { $0.isHighlighted = false }
    highlightedButtons.removeAll()
    calloutTouch = nil
    tracker.reset()
    touchIDs.removeAll()
    lastTouchPoints.removeAll()
    endTrackpad()
  }

  func activate(_ action: KeyboardKeyAction) {
    switch action {
    case .text(let text):
      insertText(text)
    case .shift:
      interactionState.tapShift(at: ProcessInfo.processInfo.systemUptime)
      relabel()
    case .page:
      interactionState.tapPage()
      rebuild()
    case .returnKey:
      insertText("\n", consumesShift: false)
    case .backspace:
      deleteOnce()
    case .space:
      insertText(" ", consumesShift: false)
    case .microphone:
      delegate?.keyboardSurfaceMicrophoneTapped(self)
    case .nextKeyboard, .blank:
      break
    }
  }

  // MARK: Layout

  /// Full rebuild: a new page, a new field type. Buttons are created once per
  /// structure; a change of case only relabels them (`relabel`).
  private func rebuild() {
    resetTransientState()
    rowButtons.flatMap { $0 }.forEach { $0.removeFromSuperview() }

    rows = interactionState.layout(
      inputKind: inputKind,
      needsInputModeSwitchKey: needsInputModeSwitchKey
    )
    rowButtons = rows.map { row in
      row.keys.map { key in
        let button = makeButton(for: key)
        addSubview(button)
        return button
      }
    }
    applyMicrophone()
    applyTypingState()
    setNeedsLayout()
  }

  /// Shift state changed: update titles and glyphs in place. Rebuilding every
  /// button on each capital letter dropped touches that were already in flight.
  private func relabel() {
    let newRows = interactionState.layout(
      inputKind: inputKind,
      needsInputModeSwitchKey: needsInputModeSwitchKey
    )
    guard Self.hasSameShape(rows, newRows) else {
      rebuild()
      return
    }
    rows = newRows
    for (rowIndex, row) in rows.enumerated() {
      for (columnIndex, key) in row.keys.enumerated() {
        let button = rowButtons[rowIndex][columnIndex]
        let effective = effectiveKey(for: key)
        button.update(key: effective)
        configure(button, for: effective)
      }
    }
    applyMicrophone()
    refreshTargets()
  }

  static func hasSameShape(_ old: [KeyboardLayoutRow], _ new: [KeyboardLayoutRow]) -> Bool {
    guard old.count == new.count else { return false }
    for (oldRow, newRow) in zip(old, new) {
      guard oldRow.keys.count == newRow.keys.count, oldRow.arrangement == newRow.arrangement
      else { return false }
      for (oldKey, newKey) in zip(oldRow.keys, newRow.keys) {
        guard sameKind(oldKey.action, newKey.action),
          oldKey.style == newKey.style,
          oldKey.width == newKey.width,
          oldKey.fixedPoints == newKey.fixedPoints
        else { return false }
      }
    }
    return true
  }

  private static func sameKind(_ a: KeyboardKeyAction, _ b: KeyboardKeyAction) -> Bool {
    switch (a, b) {
    case (.text, .text), (.shift, .shift), (.backspace, .backspace), (.page, .page),
      (.nextKeyboard, .nextKeyboard), (.microphone, .microphone), (.space, .space),
      (.returnKey, .returnKey), (.blank, .blank):
      return true
    default:
      return false
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard bounds.width > 0 else { return }
    let gridWidth: Double
    let inset: Double
    let scale: Double
    let margin: Double
    var rightMargin: Double?
    let gap: Double
    var keyHeight = geometry.keyHeight
    var rowGap = geometry.rowGap
    if inputKind.isDigitPad && !geometry.isLandscape {
      gridWidth = min(Double(bounds.width), 760)
      inset = (Double(bounds.width) - gridWidth) / 2
      scale = gridWidth / KeyboardMetrics.referenceWidth
      margin = KeyboardMetrics.DigitPad.leftMargin
      rightMargin = KeyboardMetrics.DigitPad.rightMargin
      gap = KeyboardMetrics.DigitPad.columnGap
      keyHeight = KeyboardMetrics.DigitPad.keyHeight
      rowGap = KeyboardMetrics.DigitPad.rowGap
    } else if geometry.isLandscape {
      // Landscape: absolute measured metrics. The grid is centered and starts
      // `gridInset` from the screen edge (the system insets the view itself by
      // an amount that varies, so the screen width is the reference).
      let screen = window?.windowScene?.screen.bounds ?? UIScreen.main.bounds
      let screenWidth = Double(max(screen.width, screen.height))
      gridWidth = min(Double(bounds.width), screenWidth - 2 * geometry.gridInset)
      inset = (Double(bounds.width) - gridWidth) / 2
      scale = 1
      margin = 0
      gap = geometry.keyGap
    } else {
      // Phones follow the measured 402 pt metrics proportionally; wide screens
      // (iPad) keep a centered, capped key grid instead of stretching it.
      gridWidth = min(Double(bounds.width), 760)
      inset = (Double(bounds.width) - gridWidth) / 2
      scale = gridWidth / KeyboardMetrics.referenceWidth
      margin = KeyboardMetrics.sideMargin
      gap = KeyboardMetrics.keyGap
    }
    let available = gridWidth - margin - (rightMargin ?? margin)
    // Letter width comes from the widest row: 10 keys in English, 11 in Russian.
    let referenceCount = Double(interactionState.language.letterRowStrings[0].count)
    let letterWidth = (available - (referenceCount - 1) * gap) / referenceCount

    for (rowIndex, row) in rows.enumerated() {
      let y = Double(rowIndex) * (keyHeight + rowGap)
      let widths = keyWidths(
        for: row, available: available, gap: gap, letterWidth: letterWidth, scale: scale)
      var x = margin
      if row.arrangement == .centered {
        let sideCount = leadingSideCount(in: row)
        let trailing = trailingSideCount(in: row)
        let middle = row.keys.count - sideCount - trailing
        let middleWidth =
          widths[sideCount..<(row.keys.count - trailing)].reduce(0, +)
          + Double(max(middle - 1, 0)) * gap
        let middleStart = margin + (available - middleWidth) / 2
        for (index, button) in rowButtons[rowIndex].enumerated() {
          let width = widths[index]
          let originX: Double
          if index < sideCount {
            originX = margin + Double(index) * (width + gap)
          } else if index >= row.keys.count - trailing {
            let fromEnd = row.keys.count - 1 - index
            originX = margin + available - width - Double(fromEnd) * (width + gap)
          } else {
            let precedingWidth = widths[sideCount..<index].reduce(0, +)
            originX = middleStart + precedingWidth + Double(index - sideCount) * gap
          }
          button.frame = CGRect(x: originX + inset, y: y, width: width, height: keyHeight).integralPixel(
            scale: traitCollection.displayScale)
        }
      } else {
        for (index, button) in rowButtons[rowIndex].enumerated() {
          button.frame = CGRect(x: x + inset, y: y, width: widths[index], height: keyHeight)
            .integralPixel(scale: traitCollection.displayScale)
          x += widths[index] + gap
        }
      }
    }
    refreshTargets()
  }

  private func leadingSideCount(in row: KeyboardLayoutRow) -> Int {
    guard row.arrangement == .centered else { return 0 }
    guard let first = row.keys.first, isSideKey(first) else { return 0 }
    return 1
  }

  private func trailingSideCount(in row: KeyboardLayoutRow) -> Int {
    guard row.arrangement == .centered else { return 0 }
    guard let last = row.keys.last, isSideKey(last), row.keys.count > 1 else { return 0 }
    return 1
  }

  private func isSideKey(_ key: KeyboardLayoutKey) -> Bool {
    key.action == .shift || key.action == .backspace
  }

  private func keyWidths(
    for row: KeyboardLayoutRow,
    available: Double,
    gap: Double,
    letterWidth: Double,
    scale: Double
  ) -> [Double] {
    // Fixed-width keys: scaled portrait points, or the measured landscape widths.
    func width(of points: Double) -> Double {
      guard geometry.isLandscape else { return points * scale }
      switch points {
      case KeyboardMetrics.sideKeyPoints: return geometry.sideKeyPoints
      case KeyboardMetrics.bottomKeyPoints: return geometry.bottomKeyPoints
      case KeyboardMetrics.returnKeyPoints: return geometry.returnKeyPoints
      case KeyboardMetrics.punctuationKeyPoints: return geometry.punctuationKeyPoints
      default: return points * 1.5
      }
    }
    switch row.arrangement {
    case .centered:
      return row.keys.map { key in
        if let points = key.fixedPoints { return width(of: points) }
        return letterWidth
      }
    case .fill:
      let fixed = row.keys.compactMap { $0.fixedPoints.map(width(of:)) }.reduce(0, +)
      let flexible = row.keys.filter { $0.fixedPoints == nil }
      let totalWeight = flexible.map(\.width).reduce(0, +)
      let gaps = Double(max(row.keys.count - 1, 0)) * gap
      let leftover = max(available - fixed - gaps, 0)
      let flexibleCount = Double(flexible.count)
      return row.keys.map { key in
        if let points = key.fixedPoints { return width(of: points) }
        if totalWeight > 0 { return leftover * key.width / totalWeight }
        return leftover / max(flexibleCount, 1)
      }
    }
  }

  private func effectiveKey(for key: KeyboardLayoutKey) -> KeyboardLayoutKey {
    guard key.action == .returnKey, returnKeyUsesAccent else { return key }
    return KeyboardLayoutKey(
      .returnKey, width: key.width, style: .accent, fixedPoints: key.fixedPoints)
  }

  private func makeButton(for key: KeyboardLayoutKey) -> KeyboardKeyButton {
    let key = effectiveKey(for: key)
    let button = KeyboardKeyButton(key: key)
    configure(button, for: key)
    if key.action == .nextKeyboard {
      // The system's input-mode machinery (tap = next, hold = list) wants the
      // globe to be a real control that receives the touches and the UIEvent.
      button.addTarget(self, action: #selector(nextKeyboardTouchDown), for: .touchDown)
      button.addTarget(
        self,
        action: #selector(nextKeyboardEvent(_:event:)),
        for: .allTouchEvents
      )
    } else {
      // Real touches never reach the other keys (`hitTest` hands them to the
      // surface); this fires only for VoiceOver activation.
      button.addTarget(self, action: #selector(accessibilityActivated(_:)), for: .touchUpInside)
    }
    return button
  }

  private func configure(_ button: KeyboardKeyButton, for key: KeyboardLayoutKey) {
    let presentation = presentation(for: key.action)
    button.configure(
      title: presentation.title,
      systemImage: presentation.systemImage,
      accessibilityLabel: presentation.accessibilityLabel
    )
    button.accessibilityIdentifier = presentation.accessibilityIdentifier
    if key.action == .space { button.setCornerText(interactionState.language.spaceCornerLabel) }
    button.isHidden = key.action == .blank
  }

  private var returnKeyUsesAccent: Bool {
    switch returnKeyType {
    case .go, .google, .join, .route, .search, .send, .yahoo, .done: return true
    default: return false
    }
  }

  private func applyMicrophone() {
    for button in rowButtons.flatMap({ $0 }) where button.key.action == .microphone {
      button.configure(
        title: nil,
        systemImage: microphone.systemImage,
        accessibilityLabel: microphone.accessibilityLabel
      )
      button.tintOverride = microphone.isActive ? .systemBlue : nil
      button.glyphColorOverride = microphone.isActive ? .white : nil
      button.isEnabled = microphone.isEnabled
    }
    refreshTargets()
  }

  private func applyTypingState() {
    for button in rowButtons.flatMap({ $0 }) where button.key.action != .microphone {
      button.isEnabled =
        typingEnabled && (button.key.action != .returnKey || returnKeyEnabled)
    }
    refreshTargets()
  }

  /// Key rectangles for the tracker; the globe is a real control and is left out.
  private func refreshTargets() {
    var targets: [KeyTarget] = []
    for (rowIndex, row) in rows.enumerated() {
      for (columnIndex, key) in row.keys.enumerated() {
        guard rowIndex < rowButtons.count, columnIndex < rowButtons[rowIndex].count else { continue }
        let kind: KeyTouchKind
        var hasAlternates = false
        switch key.action {
        case .nextKeyboard, .blank:
          continue
        case .text(let text):
          kind = .character
          hasAlternates = interactionState.alternateCharacters(for: text).count > 1
        case .space:
          kind = .space
        case .backspace:
          kind = .delete
        case .shift, .page, .returnKey, .microphone:
          kind = .function
        }
        let button = rowButtons[rowIndex][columnIndex]
        targets.append(
          KeyTarget(
            id: KeyID(row: rowIndex, column: columnIndex),
            frame: button.frame,
            kind: kind,
            isEnabled: button.isEnabled,
            hasAlternates: hasAlternates
          )
        )
      }
    }
    tracker.targets = targets
  }

  private func button(for id: KeyID) -> KeyboardKeyButton? {
    guard rowButtons.indices.contains(id.row), rowButtons[id.row].indices.contains(id.column)
    else { return nil }
    return rowButtons[id.row][id.column]
  }

  // MARK: Touches (UIKit entry points)

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    // The strip under the last row belongs to the keys too: a thumb on the very
    // bottom edge still types.
    bounds.insetBy(dx: 0, dy: -4).offsetBy(dx: 0, dy: 2).contains(point)
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    guard isUserInteractionEnabled, !isHidden, alpha > 0.01,
      self.point(inside: point, with: event)
    else { return nil }
    // The globe keeps its own touch handling (see `makeButton`).
    for button in rowButtons.flatMap({ $0 })
    where button.key.action == .nextKeyboard && !button.isHidden && button.isEnabled {
      if button.frame.insetBy(dx: -3, dy: -6).contains(point) { return button }
    }
    return self
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    for touch in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
      let id = nextTouchID
      nextTouchID += 1
      touchIDs[ObjectIdentifier(touch)] = id
      touchDown(id, at: touch.location(in: self))
    }
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    for touch in touches {
      guard let id = touchIDs[ObjectIdentifier(touch)] else { continue }
      touchMoved(id, to: touch.location(in: self))
    }
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    for touch in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
      guard let id = touchIDs.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
      touchUp(id, at: touch.location(in: self))
    }
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
    for touch in touches {
      guard let id = touchIDs.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
      touchCancelled(id)
    }
  }

  // MARK: Touches (testable core)

  func touchDown(_ id: Int, at point: CGPoint) {
    lastTouchPoints[id] = point
    apply(tracker.began(touch: id, at: point))
  }

  func touchMoved(_ id: Int, to point: CGPoint) {
    lastTouchPoints[id] = point
    apply(tracker.moved(touch: id, to: point))
  }

  func touchUp(_ id: Int, at point: CGPoint) {
    lastTouchPoints[id] = point
    apply(tracker.ended(touch: id, at: point))
    cleanUp(touch: id)
  }

  func touchCancelled(_ id: Int) {
    apply(tracker.cancelled(touch: id))
    cleanUp(touch: id)
  }

  /// The long-press timers call these; tests call them directly.
  func fireAlternatesLongPress(touch id: Int) {
    apply(tracker.beginAlternates(touch: id))
  }

  func fireTrackpadLongPress(touch id: Int) {
    apply(tracker.beginTrackpad(touch: id))
  }

  private func cleanUp(touch id: Int) {
    longPressTimers.removeValue(forKey: id)?.invalidate()
    lastTouchPoints.removeValue(forKey: id)
    if let button = highlightedButtons.removeValue(forKey: id) { button.isHighlighted = false }
  }

  private func apply(_ outputs: [KeyTouchOutput]) {
    for output in outputs {
      switch output {
      case .pressed(let touch, let key):
        pressed(touch: touch, key: key)
      case .slid(let touch, let from, let to):
        slid(touch: touch, from: from, to: to)
      case .commit(let touch, let key):
        committed(touch: touch, key: key)
        onKeyOutput?()
      case .released(let touch, let key):
        released(touch: touch, key: key)
      case .deleteBegan:
        beginDeleteRepeat()
        onKeyOutput?()
      case .deleteEnded:
        stopDeleteRepeat()
      case .alternatesBegan(let touch, let key):
        beginAlternates(touch: touch, key: key)
      case .alternatesMoved(_, let point):
        alternateCallout.updateSelection(at: point, options: activeAlternateOptions)
        feedbackIfSelectionChanged()
      case .alternatesEnded(_, _):
        endAlternates(commit: true)
        onKeyOutput?()
      case .alternatesCancelled:
        endAlternates(commit: false)
      case .trackpadBegan(let touch):
        beginTrackpad(touch: touch)
      case .trackpadMoved(_, let point):
        moveTrackpad(to: point)
      case .trackpadEnded:
        endTrackpad()
        onKeyOutput?()
      }
    }
  }

  // MARK: Reactions

  /// Haptic tick and input click, fired on key-down so they never wait for the
  /// text insertion (which happens on touch-up).
  private func keyDownFeedback() {
    feedback.keyDown()
    if feedbackPolicy.shouldPlayClick {
      delegate?.keyboardSurfacePlayInputClick(self)
    }
  }

  private func pressed(touch: Int, key: KeyID) {
    keyDownFeedback()
    guard let button = button(for: key), let target = tracker.target(for: key) else { return }
    switch target.kind {
    case .character:
      if button.key.style == .input, case .text(let text) = button.key.action {
        inputCallout.show(text: text, above: button, in: self)
        calloutTouch = touch
      } else {
        highlight(button, touch: touch)
      }
      if target.hasAlternates { scheduleLongPress(touch: touch, delay: Self.alternatesDelay) { [weak self] in
        self?.fireAlternatesLongPress(touch: touch)
      } }
    case .space:
      highlight(button, touch: touch)
      scheduleLongPress(touch: touch, delay: Self.trackpadDelay) { [weak self] in
        self?.fireTrackpadLongPress(touch: touch)
      }
    case .delete, .function:
      highlight(button, touch: touch)
    }
  }

  private func slid(touch: Int, from: KeyID, to: KeyID?) {
    guard let origin = tracker.originKey(ofTouch: touch) else { return }
    if tracker.target(for: origin)?.kind == .character {
      // The balloon follows the finger across letters.
      if let to, let button = button(for: to), tracker.target(for: to)?.kind == .character,
        button.key.style == .input, case .text(let text) = button.key.action
      {
        inputCallout.show(text: text, above: button, in: self)
        calloutTouch = touch
      } else if calloutTouch == touch {
        inputCallout.hide()
        calloutTouch = nil
      }
    } else if let button = button(for: origin) {
      button.isHighlighted = to == origin
    }
  }

  private func committed(touch: Int, key: KeyID) {
    longPressTimers.removeValue(forKey: touch)?.invalidate()
    if calloutTouch == touch {
      inputCallout.hide()
      calloutTouch = nil
    }
    if let button = highlightedButtons.removeValue(forKey: touch) { button.isHighlighted = false }
    guard let button = button(for: key) else { return }
    activate(button.key.action)
  }

  private func released(touch: Int, key: KeyID) {
    longPressTimers.removeValue(forKey: touch)?.invalidate()
    if calloutTouch == touch {
      inputCallout.hide()
      calloutTouch = nil
    }
    if let button = highlightedButtons.removeValue(forKey: touch) { button.isHighlighted = false }
  }

  private func highlight(_ button: KeyboardKeyButton, touch: Int) {
    button.isHighlighted = true
    highlightedButtons[touch] = button
  }

  private func scheduleLongPress(
    touch: Int, delay: TimeInterval, action: @escaping () -> Void
  ) {
    longPressTimers[touch]?.invalidate()
    let timer = Timer(timeInterval: delay, repeats: false) { _ in action() }
    longPressTimers[touch] = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  // MARK: Accent panel

  private func beginAlternates(touch: Int, key: KeyID) {
    guard let button = button(for: key), case .text(let text) = button.key.action else { return }
    let options = interactionState.alternateCharacters(for: text)
    guard options.count > 1 else { return }
    inputCallout.hide()
    calloutTouch = nil
    let buttonFrame = button.convert(button.bounds, to: self)
    let anchorsToTrailingEdge = buttonFrame.midX > bounds.midX
    activeAlternateOptions = anchorsToTrailingEdge ? Array(options.reversed()) : options
    alternateCallout.show(
      options: activeAlternateOptions,
      above: button,
      in: self,
      anchoredToTrailingEdge: anchorsToTrailingEdge
    )
    feedback.selectionChanged()
  }

  private var lastAlternateSelection: String?

  private func feedbackIfSelectionChanged() {
    if alternateCallout.selectedText != lastAlternateSelection {
      lastAlternateSelection = alternateCallout.selectedText
      feedback.selectionChanged()
    }
  }

  private func endAlternates(commit: Bool) {
    if commit, let selected = alternateCallout.selectedText {
      insertText(selected)
    }
    alternateCallout.hide()
    activeAlternateOptions = []
    lastAlternateSelection = nil
  }

  // MARK: Space-bar trackpad

  private func beginTrackpad(touch: Int) {
    isTrackpadActive = true
    trackpad = TrackpadCursor(anchor: lastTouchPoints[touch] ?? .zero)
    longPressTimers.removeValue(forKey: touch)?.invalidate()
    rowButtons.flatMap { $0 }.forEach { $0.setLabelsHidden(true) }
    feedback.selectionChanged()
  }

  private func moveTrackpad(to point: CGPoint) {
    guard var cursor = trackpad else { return }
    let steps = cursor.steps(to: point)
    trackpad = cursor
    if steps.characters != 0 {
      delegate?.keyboardSurface(self, adjustTextPositionBy: steps.characters)
      feedback.selectionChanged()
    }
    if steps.lines != 0 {
      delegate?.keyboardSurface(self, moveCursorVerticallyBy: steps.lines)
      feedback.selectionChanged()
    }
  }

  private func endTrackpad() {
    guard isTrackpadActive || trackpad != nil else { return }
    isTrackpadActive = false
    trackpad = nil
    rowButtons.flatMap { $0 }.forEach { $0.setLabelsHidden(false) }
  }

  // MARK: Delete

  private func beginDeleteRepeat() {
    deleteOnce()
    stopDeleteRepeat()
    let delay = deleteRepeat.begin(at: ProcessInfo.processInfo.systemUptime)
    scheduleDeleteTick(after: delay)
  }

  private func scheduleDeleteTick(after interval: TimeInterval) {
    deleteTimer?.invalidate()
    let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
      self?.deleteTick(at: ProcessInfo.processInfo.systemUptime)
    }
    deleteTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  /// One repeat of a held ⌫ (a character, later a word); also driven by tests.
  func deleteTick(at time: TimeInterval) {
    guard let (step, next) = deleteRepeat.tick(at: time) else { return }
    keyDownFeedback()
    switch step {
    case .character: deleteOnce()
    case .word: delegate?.keyboardSurfaceDeleteWordBackward(self)
    }
    scheduleDeleteTick(after: next)
  }

  private func deleteOnce() {
    delegate?.keyboardSurfaceDeleteBackward(self)
  }

  private func stopDeleteRepeat() {
    deleteRepeat.end()
    deleteTimer?.invalidate()
    deleteTimer = nil
  }

  // MARK: Globe and VoiceOver

  @objc private func nextKeyboardTouchDown() {
    keyDownFeedback()
  }

  @objc private func nextKeyboardEvent(_ sender: UIButton, event: UIEvent) {
    delegate?.keyboardSurface(self, showInputModeListFrom: sender, event: event)
  }

  @objc private func accessibilityActivated(_ sender: KeyboardKeyButton) {
    keyDownFeedback()
    activate(sender.key.action)
  }

  private func insertText(_ text: String, consumesShift: Bool = true) {
    delegate?.keyboardSurface(self, insertText: text)
    guard consumesShift else { return }
    let previous = interactionState.capitalization
    interactionState.consumeText()
    if previous != interactionState.capitalization {
      relabel()
    }
  }

  private func presentation(
    for action: KeyboardKeyAction
  ) -> (title: String?, systemImage: String?, accessibilityLabel: String, accessibilityIdentifier: String) {
    let strings = accessibilityStrings
    switch action {
    case .text(let text):
      return (text, nil, text, "keyboard-key-\(text)")
    case .shift:
      let image = interactionState.isCapsLocked
        ? "capslock.fill"
        : (interactionState.usesUppercaseLetters ? "shift.fill" : "shift")
      let value: String
      switch interactionState.page {
      case .letters: value = interactionState.isCapsLocked ? strings.capsLock : strings.shift
      case .numbers: value = strings.symbols
      case .symbols: value = strings.numbers
      }
      return (
        interactionState.page == .letters ? nil : shiftPageTitle,
        interactionState.page == .letters ? image : nil,
        value,
        "keyboard-shift-key"
      )
    case .backspace:
      return (nil, "delete.left", strings.delete, "keyboard-delete-key")
    case .page:
      return (
        interactionState.page == .letters ? "123" : interactionState.language.pageToggleTitle,
        nil,
        interactionState.page == .letters ? strings.numbers : strings.letters,
        "keyboard-page-key")
    case .nextKeyboard:
      return (nil, "globe", strings.nextKeyboard, "keyboard-next-keyboard-key")
    case .microphone:
      return (nil, microphone.systemImage, microphone.accessibilityLabel, "keyboard-microphone-key")
    case .space:
      return (nil, nil, interactionState.language.spaceTitle, "keyboard-space-key")
    case .returnKey:
      return (nil, returnKeySymbol, returnKeyTitle ?? strings.return, "keyboard-return-key")
    case .blank:
      return (nil, nil, "", "keyboard-blank-key")
    }
  }

  private var shiftPageTitle: String {
    interactionState.page == .numbers ? "#+=" : "123"
  }

  /// iOS 26 draws a glyph on the return key, the same in every language
  /// (measured on the simulator for each `UIReturnKeyType`).
  private var returnKeySymbol: String {
    switch returnKeyType {
    case .go, .join, .route: return "arrow.right"
    case .search, .google, .yahoo: return "magnifyingglass"
    case .send: return "arrow.up"
    case .done: return "checkmark"
    case .next, .continue: return "chevron.right"
    case .emergencyCall: return "phone.fill"
    default: return "return"
    }
  }

  /// Spoken name of the return key.
  private var returnKeyTitle: String? {
    if interactionState.language == .russian {
      switch returnKeyType {
      case .go: return "перейти"
      case .google, .yahoo, .search: return "Найти"
      case .join: return "Войти"
      case .next: return "Далее"
      case .route: return "Маршрут"
      case .send: return "Отправить"
      case .done: return "Готово"
      case .continue: return "Продолжить"
      case .emergencyCall: return "Вызов"
      default: return nil
      }
    }
    switch returnKeyType {
    case .go: return "go"
    case .google: return "Google"
    case .join: return "join"
    case .next: return "next"
    case .route: return "route"
    case .search: return "search"
    case .send: return "send"
    case .yahoo: return "Yahoo"
    case .done: return "done"
    case .continue: return "continue"
    case .emergencyCall: return "Emergency"
    default: return nil
    }
  }

  // MARK: Test support

  /// Frame of the key with this accessibility identifier, in surface coordinates.
  func keyFrame(identifier: String) -> CGRect? {
    rowButtons.flatMap { $0 }.first { $0.accessibilityIdentifier == identifier }?.frame
  }
}

extension CGRect {
  /// Snaps the frame to whole device pixels so key edges stay crisp.
  func integralPixel(scale: CGFloat) -> CGRect {
    let s = max(scale, 1)
    let minX = (origin.x * s).rounded() / s
    let minY = (origin.y * s).rounded() / s
    let maxX = ((origin.x + size.width) * s).rounded() / s
    let maxY = ((origin.y + size.height) * s).rounded() / s
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
  }
}
