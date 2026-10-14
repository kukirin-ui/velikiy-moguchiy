import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Haptic feedback for key presses, like Apple's "Keyboard Feedback → Haptic".
///
/// One light impact generator and one selection generator are created once and
/// reused for every key, so a keystroke allocates nothing. `prepare()` keeps
/// the Taptic Engine warm; it is called on touch-down of the keyboard and again
/// after each tick. Feedback is skipped silently when `policy.shouldVibrate`
/// is false (no Full Access, or the user turned it off).
@MainActor
final class KeyFeedbackEngine {
  var policy = KeyFeedbackPolicy.initial

  private let impact = UIImpactFeedbackGenerator(style: .light)
  private let selection = UISelectionFeedbackGenerator()

  /// Wakes the Taptic Engine so the next tick has no latency.
  func prepare() {
    guard policy.shouldVibrate else { return }
    impact.prepare()
  }

  /// Light tap for a key-down (letters, space, delete and its repeats, ...).
  func keyDown() {
    guard policy.shouldVibrate else { return }
    impact.impactOccurred()
    impact.prepare()
  }

  /// Tick when the selection moves (accent panel, space-bar cursor drag).
  func selectionChanged() {
    guard policy.shouldVibrate else { return }
    selection.selectionChanged()
    selection.prepare()
  }
}

/// Never claims a touch; it only warms the haptic engine at the moment a
/// finger lands anywhere on the keyboard, before any key handles the touch.
final class KeyboardTouchDownPreparer: UIGestureRecognizer {
  var onTouchDown: (() -> Void)?

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    onTouchDown?()
    state = .failed
  }
}

/// The keyboard's input view. Input clicks (`UIDevice.playInputClick`) only
/// sound when the visible input view adopts `UIInputViewAudioFeedback`.
final class KeyboardInputView: UIInputView, UIInputViewAudioFeedback {
  /// Mirrors the "click sound" setting; read by the system on every click.
  var clicksEnabled = true
  var enableInputClicksWhenVisible: Bool { clicksEnabled }
}
