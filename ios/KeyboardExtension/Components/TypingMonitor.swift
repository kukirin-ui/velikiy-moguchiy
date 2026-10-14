import UIKit

/// Measures every key press on the device: how late iOS hands the touch to the
/// keyboard, how long until the text reaches the field, and presses that
/// produce nothing. Saves the last presses while the user is not typing, so
/// the measurement never competes with a keystroke.
final class TypingMonitor {
  /// Watches the key area without taking part: it never recognizes, delays or
  /// cancels anything, it only sees each touch before the keys do.
  private final class Recognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    weak var monitor: TypingMonitor?

    init(monitor: TypingMonitor) {
      self.monitor = monitor
      super.init(target: nil, action: nil)
      cancelsTouchesInView = false
      delaysTouchesBegan = false
      delaysTouchesEnded = false
      delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
      let now = ProcessInfo.processInfo.systemUptime
      for touch in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
        monitor?.probe.touchBegan(id(touch), at: touch.timestamp, receivedAt: now)
      }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
      for touch in touches { monitor?.probe.touchEnded(id(touch), at: touch.timestamp) }
      finishIfIdle(event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
      for touch in touches { monitor?.probe.touchCancelled(id(touch)) }
      finishIfIdle(event)
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }

    /// Staying `.possible` keeps the recognizer receiving new fingers; once
    /// every finger is up it fails so UIKit resets it for the next sequence.
    private func finishIfIdle(_ event: UIEvent) {
      let active = event.allTouches?.filter { $0.phase != .ended && $0.phase != .cancelled } ?? []
      if active.isEmpty { state = .failed }
    }

    private func id(_ touch: UITouch) -> Int { ObjectIdentifier(touch).hashValue }
  }

  private(set) var probe = TypingProbe()
  private var stats: TypingStats
  private var unsaved = false
  private var saveWorkItem: DispatchWorkItem?
  private let save: (TypingStats) -> Void

  /// - Parameters:
  ///   - stored: the presses saved earlier, so the window keeps growing to 200.
  ///   - save: called on the main thread during typing pauses.
  init(stored: TypingStats, save: @escaping (TypingStats) -> Void) {
    stats = stored
    self.save = save
  }

  func attach(to view: UIView) {
    view.addGestureRecognizer(Recognizer(monitor: self))
  }

  /// A key did its job (text inserted, deleted, shift toggled ...). Call after
  /// the text has been handed to the field.
  func noteOutput() {
    probe.noteOutput(at: ProcessInfo.processInfo.systemUptime)
    scheduleSave()
  }

  func flush() {
    collect(now: ProcessInfo.processInfo.systemUptime + TypingProbe.quietAfterRelease)
    saveWorkItem?.cancel()
    saveWorkItem = nil
    guard unsaved else { return }
    unsaved = false
    save(stats)
  }

  private func collect(now: TimeInterval) {
    let settled = probe.takeSettled(now: now, wallClock: Date().timeIntervalSince1970)
    guard !settled.isEmpty else { return }
    settled.forEach { stats.append($0) }
    unsaved = true
  }

  private func scheduleSave() {
    saveWorkItem?.cancel()
    let item = DispatchWorkItem { [weak self] in self?.flush() }
    saveWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
  }
}
