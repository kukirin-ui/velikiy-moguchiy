import UIKit

/// Holds the dictation status row. In a field with a suggestion strip it sits on
/// the strip; in a field without one (Safari's address bar) it covers the top
/// key row behind a backdrop while a dictation runs, since typing is locked then.
final class StatusOverlayView: UIView {
  let backdrop = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))

  override init(frame: CGRect) {
    super.init(frame: frame)
    backdrop.translatesAutoresizingMaskIntoConstraints = false
    backdrop.layer.cornerRadius = 12
    backdrop.layer.cornerCurve = .continuous
    backdrop.clipsToBounds = true
    backdrop.isHidden = true
    addSubview(backdrop)
    NSLayoutConstraint.activate([
      backdrop.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
      backdrop.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
      backdrop.topAnchor.constraint(equalTo: topAnchor, constant: 4),
      backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    nil
  }

  /// Buttons always get their touches. Over the strip everything else passes
  /// through to the suggestions; over the keys the backdrop swallows the rest.
  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    guard let hit = super.hitTest(point, with: event) else { return nil }
    if hit is UIControl { return hit }
    return backdrop.isHidden ? nil : self
  }
}
