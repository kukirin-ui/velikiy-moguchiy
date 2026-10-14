import UIKit

// Adapted for this project from KeyboardKit 9.9.1 callout concepts.
// Copyright (c) 2016-2025 Daniel Saidi. MIT license; see THIRD_PARTY_NOTICES.md.
// Shapes and metrics were re-measured on the iOS 26.3 system keyboard.

private enum CalloutColors {
  static let fill = UIColor { traits in
    traits.userInterfaceStyle == .dark
      ? UIColor(white: 92.0 / 255.0, alpha: 1)
      : .white
  }
  static let text = UIColor { traits in
    traits.userInterfaceStyle == .dark ? .white : .black
  }
  static let selection = UIColor(red: 0, green: 136.0 / 255.0, blue: 1, alpha: 1)
}

/// The balloon that grows out of a pressed key (Apple's key popup).
final class KeyboardInputCalloutView: UIView {
  private let shape = CAShapeLayer()
  private let label = UILabel()
  private var cachedKeyFrame: CGRect = .zero

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    backgroundColor = .clear
    layer.addSublayer(shape)
    shape.shadowColor = UIColor.black.cgColor
    shape.shadowOpacity = 0.18
    shape.shadowRadius = 2
    shape.shadowOffset = CGSize(width: 0, height: 1)

    label.font = .systemFont(ofSize: 36, weight: .regular)
    label.textAlignment = .center
    label.adjustsFontSizeToFitWidth = true
    label.minimumScaleFactor = 0.5
    addSubview(label)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    nil
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    shape.fillColor = CalloutColors.fill.resolvedColor(with: traitCollection).cgColor
  }

  /// `availableHeight` is the space above the key inside the keyboard view;
  /// the balloon shrinks on the top row because an extension cannot draw
  /// outside its own view the way the system keyboard does.
  func show(text: String, above key: UIView, in container: UIView) {
    let keyFrame = key.convert(key.bounds, to: container)
    let widen: CGFloat = 10.5
    let desiredRise: CGFloat = 66
    let rise = min(desiredRise, max(34, keyFrame.minY + 48))
    let neckHeight: CGFloat = 16

    var left = keyFrame.minX - widen
    var right = keyFrame.maxX + widen
    // Keep the balloon on screen, sliding sideways like Apple's does.
    if left < 2 { right += 2 - left; left = 2 }
    if right > container.bounds.width - 2 {
      left -= right - (container.bounds.width - 2)
      right = container.bounds.width - 2
    }
    let top = keyFrame.minY - rise
    let frame = CGRect(
      x: min(left, keyFrame.minX),
      y: top,
      width: max(right, keyFrame.maxX) - min(left, keyFrame.minX),
      height: keyFrame.maxY - top
    )
    self.frame = frame

    let local = keyFrame.offsetBy(dx: -frame.minX, dy: -frame.minY)
    let wideLeft = left - frame.minX
    let wideRight = right - frame.minX
    let wideBottom = local.minY - neckHeight + 0
    shape.frame = bounds
    shape.path = Self.balloonPath(
      wideLeft: wideLeft, wideRight: wideRight, top: 0, wideBottom: max(wideBottom, 24),
      key: local, cornerRadius: CGFloat(KeyboardMetrics.keyCornerRadius)
    ).cgPath
    shape.shadowPath = shape.path
    shape.fillColor = CalloutColors.fill.resolvedColor(with: traitCollection).cgColor

    label.text = text
    label.textColor = CalloutColors.text
    label.frame = CGRect(
      x: wideLeft, y: 0, width: wideRight - wideLeft, height: max(wideBottom, 24) + 18)
    label.frame.origin.y = (rise - 48) / 2 + 2

    if superview !== container {
      removeFromSuperview()
      container.addSubview(self)
    }
    container.bringSubviewToFront(self)
    alpha = 1
  }

  func hide() {
    removeFromSuperview()
  }

  private static func balloonPath(
    wideLeft: CGFloat, wideRight: CGFloat, top: CGFloat, wideBottom: CGFloat,
    key: CGRect, cornerRadius: CGFloat
  ) -> UIBezierPath {
    let r: CGFloat = 10  // balloon corner radius
    let neck: CGFloat = 8  // concave radius where the balloon meets the key
    let path = UIBezierPath()
    path.move(to: CGPoint(x: wideLeft + r, y: top))
    path.addLine(to: CGPoint(x: wideRight - r, y: top))
    path.addArc(
      withCenter: CGPoint(x: wideRight - r, y: top + r), radius: r,
      startAngle: -.pi / 2, endAngle: 0, clockwise: true)
    path.addLine(to: CGPoint(x: wideRight, y: wideBottom - r))
    path.addArc(
      withCenter: CGPoint(x: wideRight - r, y: wideBottom - r), radius: r,
      startAngle: 0, endAngle: .pi / 2, clockwise: true)
    // Back in to the key's right edge, with a concave neck.
    if wideRight > key.maxX + neck {
      path.addLine(to: CGPoint(x: key.maxX + neck, y: wideBottom))
      path.addQuadCurve(
        to: CGPoint(x: key.maxX, y: wideBottom + neck),
        controlPoint: CGPoint(x: key.maxX, y: wideBottom))
    } else {
      path.addLine(to: CGPoint(x: key.maxX, y: wideBottom))
    }
    path.addLine(to: CGPoint(x: key.maxX, y: key.maxY - cornerRadius))
    path.addArc(
      withCenter: CGPoint(x: key.maxX - cornerRadius, y: key.maxY - cornerRadius),
      radius: cornerRadius, startAngle: 0, endAngle: .pi / 2, clockwise: true)
    path.addLine(to: CGPoint(x: key.minX + cornerRadius, y: key.maxY))
    path.addArc(
      withCenter: CGPoint(x: key.minX + cornerRadius, y: key.maxY - cornerRadius),
      radius: cornerRadius, startAngle: .pi / 2, endAngle: .pi, clockwise: true)
    path.addLine(to: CGPoint(x: key.minX, y: wideBottom + neck))
    if wideLeft < key.minX - neck {
      path.addQuadCurve(
        to: CGPoint(x: key.minX - neck, y: wideBottom),
        controlPoint: CGPoint(x: key.minX, y: wideBottom))
      path.addLine(to: CGPoint(x: wideLeft + r, y: wideBottom))
      path.addArc(
        withCenter: CGPoint(x: wideLeft + r, y: wideBottom - r), radius: r,
        startAngle: .pi / 2, endAngle: .pi, clockwise: true)
    } else {
      path.addLine(to: CGPoint(x: key.minX, y: wideBottom - r))
      path.addArc(
        withCenter: CGPoint(x: wideLeft + r, y: wideBottom - r), radius: r,
        startAngle: .pi / 2, endAngle: .pi, clockwise: true)
    }
    path.addLine(to: CGPoint(x: wideLeft, y: top + r))
    path.addArc(
      withCenter: CGPoint(x: wideLeft + r, y: top + r), radius: r,
      startAngle: .pi, endAngle: -.pi / 2, clockwise: true)
    path.close()
    return path
  }
}

/// The accent panel shown on long press: white panel, blue selected cell.
final class KeyboardAlternateCalloutView: UIView {
  private static let cellWidth: CGFloat = 37
  private static let sidePadding: CGFloat = 10.3
  private static let panelRadius: CGFloat = 12

  private let selectionView = UIView()
  private var labels: [UILabel] = []
  private var cellHeight: CGFloat = 47.5
  private var verticalPadding: CGFloat = 9.5
  private(set) var selectedText: String?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = CalloutColors.fill
    layer.cornerRadius = Self.panelRadius
    layer.cornerCurve = .continuous
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOpacity = 0.18
    layer.shadowRadius = 3
    layer.shadowOffset = CGSize(width: 0, height: 1)

    selectionView.backgroundColor = CalloutColors.selection
    selectionView.layer.cornerRadius = 9
    selectionView.layer.cornerCurve = .continuous
    addSubview(selectionView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    nil
  }

  func show(
    options: [String],
    above key: UIView,
    in container: UIView,
    anchoredToTrailingEdge: Bool
  ) {
    labels.forEach { $0.removeFromSuperview() }
    labels = options.map { option in
      let label = UILabel()
      label.text = option
      label.textAlignment = .center
      label.font = .systemFont(ofSize: 25, weight: .regular)
      addSubview(label)
      return label
    }
    let keyFrame = key.convert(key.bounds, to: container)
    // The system panel floats above the keyboard; ours has to fit inside the
    // keyboard view, so it shrinks on the top row.
    let gapAboveKey: CGFloat = 6
    let fullHeight: CGFloat = 67
    let available = keyFrame.minY - gapAboveKey - 2 + 50
    let height = min(fullHeight, max(46, available))
    verticalPadding = (height - (fullHeight - 2 * 9.5)) / 2 > 0 ? 9.5 : 4
    cellHeight = height - 2 * (height < fullHeight ? 4 : 9.5)
    verticalPadding = height < fullHeight ? 4 : 9.5

    let width = Self.sidePadding * 2 + CGFloat(options.count) * Self.cellWidth
    let baseIndex = anchoredToTrailingEdge ? options.count - 1 : 0
    let baseCenterOffset =
      Self.sidePadding + (CGFloat(baseIndex) + 0.5) * Self.cellWidth
    var x = keyFrame.midX - baseCenterOffset
    x = min(max(x, 4), container.bounds.width - width - 4)
    frame = CGRect(
      x: x, y: keyFrame.minY - gapAboveKey - height, width: width, height: height)
    backgroundColor = CalloutColors.fill
    for (index, label) in labels.enumerated() {
      label.frame = CGRect(
        x: Self.sidePadding + CGFloat(index) * Self.cellWidth, y: verticalPadding,
        width: Self.cellWidth, height: cellHeight)
    }
    if superview !== container {
      removeFromSuperview()
      container.addSubview(self)
    }
    container.bringSubviewToFront(self)
    select(index: baseIndex, options: options)
  }

  func updateSelection(at point: CGPoint, options: [String]) {
    guard !options.isEmpty, bounds.width > 0 else { return }
    let localPoint = convert(point, from: superview)
    let raw = Int(((localPoint.x - Self.sidePadding) / Self.cellWidth).rounded(.down))
    select(index: min(options.count - 1, max(0, raw)), options: options)
  }

  func hide() {
    selectedText = nil
    removeFromSuperview()
  }

  private func select(index: Int, options: [String]) {
    guard options.indices.contains(index) else { return }
    selectedText = options[index]
    selectionView.frame = CGRect(
      x: Self.sidePadding + CGFloat(index) * Self.cellWidth, y: verticalPadding,
      width: Self.cellWidth, height: cellHeight)
    for (labelIndex, label) in labels.enumerated() {
      label.textColor = labelIndex == index ? .white : CalloutColors.text
    }
    sendSubviewToBack(selectionView)
  }
}
