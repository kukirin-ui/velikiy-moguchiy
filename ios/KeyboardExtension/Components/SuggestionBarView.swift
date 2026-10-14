import UIKit

/// Apple's predictive strip: three equal cells with thin dividers. The middle
/// cell is the primary candidate (the one an automatic correction would use).
final class SuggestionBarView: UIView {
  var onSelect: ((Suggestion) -> Void)?

  private let buttons = (0..<3).map { _ in UIButton(type: .custom) }
  private let dividers = (0..<2).map { _ in UIView() }
  private var suggestions: [Suggestion?] = [nil, nil, nil]

  override init(frame: CGRect) {
    super.init(frame: frame)
    for (index, button) in buttons.enumerated() {
      button.titleLabel?.font = .systemFont(ofSize: 17, weight: .regular)
      button.titleLabel?.lineBreakMode = .byTruncatingTail
      button.setTitleColor(Self.textColor, for: .normal)
      button.setTitleColor(.secondaryLabel, for: .highlighted)
      button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
      button.tag = index
      button.accessibilityIdentifier = "keyboard-suggestion-\(index)"
      button.addTarget(self, action: #selector(tapped(_:)), for: .touchUpInside)
      button.isHidden = true
      addSubview(button)
    }
    for divider in dividers {
      divider.backgroundColor = Self.dividerColor
      divider.isUserInteractionEnabled = false
      addSubview(divider)
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    nil
  }

  static let textColor = UIColor { traits in
    traits.userInterfaceStyle == .dark ? .white : .black
  }

  static let dividerColor = UIColor { traits in
    traits.userInterfaceStyle == .dark
      ? UIColor(white: 1, alpha: 0.18) : UIColor(white: 0, alpha: 0.14)
  }

  /// Shows up to three candidates: three fill the cells, two take the left and
  /// middle, one sits in the middle.
  func show(_ items: [Suggestion]) {
    var cells: [Suggestion?] = [nil, nil, nil]
    switch items.count {
    case 0: break
    case 1: cells[1] = items[0]
    case 2:
      cells[0] = items[0]
      cells[1] = items[1]
    default:
      cells = [items[0], items[1], items[2]]
    }
    guard cells != suggestions else { return }
    suggestions = cells
    for (index, button) in buttons.enumerated() {
      if let suggestion = cells[index] {
        button.setTitle(suggestion.display, for: .normal)
        button.accessibilityLabel = "Подсказка: \(suggestion.text)"
        button.isHidden = false
      } else {
        button.setTitle(nil, for: .normal)
        button.isHidden = true
      }
    }
    setNeedsLayout()
  }

  var hasContent: Bool { suggestions.contains { $0 != nil } }

  func clear() {
    show([])
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let width = bounds.width / 3
    for (index, button) in buttons.enumerated() {
      button.frame = CGRect(x: CGFloat(index) * width, y: 0, width: width, height: bounds.height)
    }
    let dividerHeight: CGFloat = 24
    for (index, divider) in dividers.enumerated() {
      divider.frame = CGRect(
        x: width * CGFloat(index + 1) - 0.25, y: (bounds.height - dividerHeight) / 2,
        width: 0.5, height: dividerHeight)
    }
  }

  @objc private func tapped(_ sender: UIButton) {
    guard suggestions.indices.contains(sender.tag), let suggestion = suggestions[sender.tag]
    else { return }
    onSelect?(suggestion)
  }
}
