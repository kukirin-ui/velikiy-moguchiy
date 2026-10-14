import UIKit

// Adapted for this project from KeyboardKit 9.9.1 interaction and styling
// concepts. Copyright (c) 2016-2025 Daniel Saidi. MIT license; see
// THIRD_PARTY_NOTICES.md. Colors, metrics and glyph sizes were re-measured on
// the iOS 26.3 system keyboard.

final class KeyboardKeyButton: UIButton {
  private(set) var key: KeyboardLayoutKey
  private let titleView = UILabel()
  private let glyphView = UIImageView()
  private let cornerLabel = UILabel()
  private let lettersLabel = UILabel()
  /// Overrides the default function-key tint (the microphone uses it).
  var tintOverride: UIColor? {
    didSet { updateAppearance(animated: false) }
  }
  var glyphColorOverride: UIColor? {
    didSet { updateAppearance(animated: false) }
  }

  init(key: KeyboardLayoutKey) {
    self.key = key
    super.init(frame: .zero)
    // Not exclusive: the surface tracks all fingers itself, and an exclusive
    // key would starve a second thumb while the first one is still down.
    accessibilityTraits.insert(.keyboardKey)
    layer.cornerCurve = .continuous
    layer.cornerRadius = CGFloat(KeyboardMetrics.keyCornerRadius)

    titleView.textAlignment = .center
    titleView.isUserInteractionEnabled = false
    titleView.adjustsFontSizeToFitWidth = true
    titleView.minimumScaleFactor = 0.6
    addSubview(titleView)

    glyphView.contentMode = .center
    glyphView.isUserInteractionEnabled = false
    addSubview(glyphView)

    cornerLabel.font = .systemFont(ofSize: 16, weight: .regular, width: .condensed)
    cornerLabel.textAlignment = .right
    cornerLabel.isUserInteractionEnabled = false
    cornerLabel.isHidden = true
    addSubview(cornerLabel)

    lettersLabel.textAlignment = .center
    lettersLabel.isUserInteractionEnabled = false
    addSubview(lettersLabel)
    updateAppearance(animated: false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    nil
  }

  override var isHighlighted: Bool {
    didSet { updateAppearance(animated: true) }
  }

  override var isEnabled: Bool {
    didSet { updateAppearance(animated: false) }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    if key.emphasized {
      // Digit pad: the digit hangs from the top and the letters sit under it,
      // whether or not a key has letters (measured: digit top 11.4 pt, letters'
      // baseline 41.7 pt below the top of a 48 pt key).
      let font = titleView.font ?? Self.digitFont
      titleView.frame = CGRect(
        x: 2, y: Self.digitTop - (font.ascender - font.capHeight), width: bounds.width - 4,
        height: font.lineHeight)
      let small = Self.digitLettersFont
      lettersLabel.frame = CGRect(
        x: 2, y: Self.digitLettersBaseline - small.ascender, width: bounds.width - 4,
        height: small.lineHeight)
    } else {
      titleView.frame = bounds.insetBy(dx: 2, dy: 0).offsetBy(dx: 0, dy: titleOffsetY)
    }
    glyphView.frame = bounds.offsetBy(dx: 0, dy: key.action == .returnKey ? -0.6 : 0)
    cornerLabel.frame = CGRect(x: bounds.width - 45, y: bounds.height - 29, width: 40, height: 21)
  }

  /// Same button, new title or case (Shift changed): no view is recreated.
  func update(key newKey: KeyboardLayoutKey) {
    key = newKey
    applySubtitle()
    setNeedsLayout()
    updateAppearance(animated: false)
  }

  /// Space-bar trackpad: the letters fade out like on Apple's keyboard.
  func setLabelsHidden(_ hidden: Bool) {
    let alpha: CGFloat = hidden ? 0 : 1
    guard titleView.alpha != alpha else { return }
    UIView.animate(withDuration: 0.12) {
      self.titleView.alpha = alpha
      self.glyphView.alpha = alpha
      self.cornerLabel.alpha = alpha
    }
  }

  /// Small secondary label in the lower-right corner (Apple shows the
  /// language code there on the space bar of non-English keyboards).
  func setCornerText(_ text: String?) {
    cornerLabel.text = text
    cornerLabel.isHidden = text == nil
  }

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    // Only the globe receives real touches; give it the same extended hit area
    // Apple gives every key.
    bounds.insetBy(dx: -3, dy: -6).contains(point)
  }

  private func applySubtitle() {
    guard let subtitle = key.subtitle else {
      lettersLabel.attributedText = nil
      lettersLabel.isHidden = true
      return
    }
    lettersLabel.isHidden = false
    // Spacing goes between the letters only, so the group stays centred.
    let text = NSMutableAttributedString(
      string: subtitle,
      attributes: [.font: Self.digitLettersFont, .kern: 1.5, .foregroundColor: Self.foregroundColor])
    text.addAttribute(.kern, value: 0, range: NSRange(location: (subtitle as NSString).length - 1, length: 1))
    lettersLabel.attributedText = text
  }

  static let digitFont = UIFont.systemFont(ofSize: 22, weight: .regular)
  static let digitLettersFont = UIFont.systemFont(ofSize: 10, weight: .semibold)
  static let digitTop: CGFloat = 11.4
  static let digitLettersBaseline: CGFloat = 41.7

  func configure(title: String?, systemImage: String?, accessibilityLabel: String) {
    applySubtitle()
    if let title {
      titleView.isHidden = false
      titleView.text = title
      titleView.font = font(forTitle: title)
    } else {
      titleView.isHidden = true
      titleView.text = nil
    }
    if let systemImage {
      glyphView.isHidden = false
      let configuration = UIImage.SymbolConfiguration(pointSize: glyphPointSize, weight: .regular)
      glyphView.image = UIImage(systemName: systemImage, withConfiguration: configuration)
    } else {
      glyphView.isHidden = true
      glyphView.image = nil
    }
    self.accessibilityLabel = accessibilityLabel
    updateAppearance(animated: false)
  }

  /// Glyph sizes measured against the system keyboard (iOS 26.3).
  /// Capitals sit slightly above the key's center in Apple's keyboard.
  private var titleOffsetY: CGFloat {
    switch key.action {
    case .text(let text):
      if key.emphasized { return 0 }
      if key.isURLRowKey {
        switch text {
        case ".": return 1.4
        case "/": return -2.0
        default: return -2.8
        }
      }
      // The "." beside the space bar on e-mail and web search keyboards.
      if text == ".", key.fixedPoints == KeyboardMetrics.bottomKeyPoints
        || key.fixedPoints == KeyboardMetrics.webSearchPeriodPoints
      {
        return -3.0
      }
      if text != text.uppercased() { return -2.3 }
      return -1.3
    case .page:
      return -0.7
    default:
      return 0
    }
  }

  private var glyphPointSize: CGFloat {
    switch key.action {
    // Russian side keys are as narrow as letters and get a smaller glyph.
    case .backspace where key.style == .plain: return 20
    case .shift, .backspace: return key.fixedPoints == nil ? 14.5 : 19
    case .returnKey: return 19
    case .nextKeyboard: return 20
    case .microphone: return 19
    default: return 19
    }
  }

  private func font(forTitle title: String) -> UIFont {
    switch key.action {
    case .text:
      if key.emphasized { return Self.digitFont }
      // "/" and the domain on the URL keyboard are set smaller.
      if key.isURLRowKey, title != "." { return .systemFont(ofSize: 19, weight: .regular) }
      // Apple draws capitals smaller than lowercase letters.
      // Digits and punctuation use the capital size.
      let isLowercaseLetter = title != title.uppercased()
      return .systemFont(ofSize: isLowercaseLetter ? 25 : 22, weight: .regular)
    case .page:
      return .systemFont(ofSize: 18, weight: .regular)
    case .space:
      return .systemFont(ofSize: 16, weight: .regular)
    case .shift:
      // "#+=" / "123" on the symbol pages.
      return .systemFont(ofSize: 15, weight: .regular)
    default:
      return .systemFont(ofSize: 16, weight: .regular)
    }
  }

  private func updateAppearance(animated: Bool) {
    let changes = {
      self.backgroundColor = self.currentBackground
      let foreground = self.glyphColorOverride ?? self.currentForeground
      self.titleView.textColor = foreground
      self.cornerLabel.textColor = UIColor.tertiaryLabel
      self.glyphView.tintColor = foreground
      self.alpha = self.isEnabled ? 1 : 0.4
    }
    if animated {
      UIView.animate(
        withDuration: isHighlighted ? 0.0 : 0.1,
        delay: 0,
        options: [.allowUserInteraction, .beginFromCurrentState],
        animations: changes
      )
    } else {
      changes()
    }
  }

  private var currentForeground: UIColor {
    key.style == .accent ? .white : Self.foregroundColor
  }

  private var currentBackground: UIColor {
    if let tintOverride { return tintOverride }
    switch key.style {
    case .accent:
      return isHighlighted ? Self.pressedAccent : .systemBlue
    case .input:
      // Letters show a popup instead of changing color; space and return
      // behave like function keys.
      return key.action == .space && isHighlighted ? Self.pressedFunction : Self.keyColor
    case .system:
      return isHighlighted ? Self.pressedFunction : Self.keyColor
    case .plain:
      return isHighlighted ? Self.pressedFunction : .clear
    }
  }

  static let foregroundColor = UIColor { traits in
    traits.userInterfaceStyle == .dark ? .white : .black
  }

  /// iOS 26: every key is the same color (white, or 61/255 gray in dark mode).
  static let keyColor = UIColor { traits in
    traits.userInterfaceStyle == .dark
      ? UIColor(white: 61.0 / 255.0, alpha: 1)
      : .white
  }

  static let pressedFunction = UIColor { traits in
    traits.userInterfaceStyle == .dark
      ? UIColor(white: 92.0 / 255.0, alpha: 1)
      : UIColor(red: 172 / 255.0, green: 177 / 255.0, blue: 186 / 255.0, alpha: 1)
  }

  private static let pressedAccent = UIColor.systemBlue.withAlphaComponent(0.8)
}

private extension KeyboardLayoutKey {
  /// The three equal keys of the URL keyboard's bottom row.
  var isURLRowKey: Bool {
    guard style == .system, fixedPoints == nil, case .text(let text) = action else { return false }
    return text == "." || text == "/" || text.hasPrefix(".") && text.count > 1
  }
}
