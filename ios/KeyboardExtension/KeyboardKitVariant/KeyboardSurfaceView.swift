import KeyboardKit
import SwiftUI
import UIKit

// The "Великий & Могучий KK" keyboards: the same controller, dictation, status strip and
// measurements as Великий & Могучий RU/EN, but the keys, touch handling, callouts and
// per-field layouts come from KeyboardKit 9.9.1 (MIT). This file replaces the
// hand-made key grid of KeyboardKitPort/KeyboardSurfaceView.swift with the
// same API, so the typing feel of the two can be compared on a phone.

protocol KeyboardSurfaceViewDelegate: AnyObject {
  func keyboardSurface(_ surface: KeyboardSurfaceView, insertText text: String)
  func keyboardSurfaceDeleteBackward(_ surface: KeyboardSurfaceView)
  func keyboardSurfaceDeleteWordBackward(_ surface: KeyboardSurfaceView)
  func keyboardSurface(_ surface: KeyboardSurfaceView, adjustTextPositionBy offset: Int)
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

final class KeyboardSurfaceView: UIView {
  struct MicrophonePresentation: Equatable {
    var systemImage = "mic.fill"
    var isActive = false
    var isEnabled = true
    var accessibilityLabel = "Диктовка"
  }

  /// What the SwiftUI keys read; changes re-render them.
  final class Model: ObservableObject {
    @Published var microphone = MicrophonePresentation()
    @Published var typingEnabled = true
  }

  weak var delegate: KeyboardSurfaceViewDelegate?
  var onKeyOutput: (() -> Void)?
  /// Only the strip and padding heights are taken from here; KeyboardKit
  /// sizes its own rows (see `gridHeight`).
  var geometry = KeyboardGeometry.portrait
  var feedbackPolicy = KeyFeedbackPolicy.initial {
    didSet { applyFeedbackPolicy() }
  }
  let feedback = KeyFeedbackEngine()

  private let language: KeyboardLayoutLanguage
  private let model = Model()
  private weak var controller: KeyboardInputViewController?
  private var host: UIHostingController<AnyView>?

  init(language: KeyboardLayoutLanguage = .english, frame: CGRect = .zero) {
    self.language = language
    super.init(frame: frame)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    nil
  }

  /// Height of KeyboardKit's key rows for the current field.
  var gridHeight: CGFloat {
    guard let controller else { return CGFloat(geometry.gridHeight) }
    return CGFloat(
      controller.services.layoutService.keyboardLayout(for: controller.state.keyboardContext)
        .totalHeight)
  }

  var bottomPadding: CGFloat { CGFloat(geometry.bottomPadding) }
  var topAdjustment: CGFloat { 0 }

  func attach(to controller: KeyboardInputViewController) {
    self.controller = controller
    let state = controller.state
    let services = controller.services
    if language == .russian {
      state.keyboardContext.locale = Locale(identifier: "ru")
    }
    services.layoutService = VelikiyMoguchiyLayoutService(language: language)
    let handler = VelikiyMoguchiyActionHandler(
      controller: controller,
      keyboardContext: state.keyboardContext,
      keyboardBehavior: services.keyboardBehavior,
      autocompleteContext: state.autocompleteContext,
      autocompleteService: services.autocompleteService,
      emojiContext: state.emojiContext,
      feedbackContext: state.feedbackContext,
      feedbackService: services.feedbackService,
      spaceDragGestureHandler: services.spaceDragGestureHandler
    )
    handler.surface = self
    services.actionHandler = handler
    applyFeedbackPolicy()

    let root = Root(context: state.keyboardContext, model: model, state: state, services: services)
      .keyboardState(state)
    let host = UIHostingController(rootView: AnyView(root))
    host.view.backgroundColor = .clear
    host.safeAreaRegions = []
    host.view.translatesAutoresizingMaskIntoConstraints = false
    controller.addChild(host)
    addSubview(host.view)
    NSLayoutConstraint.activate([
      host.view.leadingAnchor.constraint(equalTo: leadingAnchor),
      host.view.trailingAnchor.constraint(equalTo: trailingAnchor),
      host.view.topAnchor.constraint(equalTo: topAnchor),
      host.view.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    host.didMove(toParent: controller)
    self.host = host
  }

  func setMicrophone(_ presentation: MicrophonePresentation) {
    model.microphone = presentation
  }

  /// While a dictation runs only the microphone reacts, as on Великий & Могучий RU/EN.
  func setTypingEnabled(_ enabled: Bool) {
    model.typingEnabled = enabled
  }

  var typingEnabled: Bool { model.typingEnabled }
  var microphoneIsEnabled: Bool { model.microphone.isEnabled }

  // KeyboardKit follows the text field itself (layout per keyboard type,
  // return key, auto-capitalization), so these are left to it.
  func updateInputContext(
    kind: KeyboardInputKind,
    returnKeyType: UIReturnKeyType,
    needsInputModeSwitchKey: Bool,
    startsOnNumbers: Bool = false
  ) {}
  func setReturnKeyEnabled(_ enabled: Bool) {}
  func applyAutomaticCapitalization(_ capitalization: KeyboardCapitalization) {}
  func resetTransientState() {}

  private func applyFeedbackPolicy() {
    guard let settings = controller?.state.feedbackContext.settings else { return }
    settings.isHapticFeedbackEnabled = feedbackPolicy.shouldVibrate
    settings.isAudioFeedbackEnabled = feedbackPolicy.shouldPlayClick
  }

  /// Rebuilt whenever the field context changes, so the layout follows it.
  private struct Root: View {
    @ObservedObject var context: KeyboardContext
    @ObservedObject var model: Model
    let state: Keyboard.State
    let services: Keyboard.Services

    var body: some View {
      KeyboardView(
        state: state,
        services: services,
        renderBackground: false,
        buttonContent: { params in
          if params.item.action == .dictation {
            Image(systemName: model.microphone.systemImage)
              .font(.system(size: 18))
              .accessibilityLabel(model.microphone.accessibilityLabel)
          } else {
            params.view
          }
        },
        buttonView: { $0.view },
        collapsedView: { $0.view },
        emojiKeyboard: { $0.view },
        toolbar: { _ in EmptyView() }
      )
    }
  }
}

/// KeyboardKit's iPhone layouts, with ЙЦУКЕН for the Russian keyboard and the
/// dictation key in the emoji slot (an extension cannot open Apple's emoji keyboard).
private final class VelikiyMoguchiyLayoutService: KeyboardLayout.StandardLayoutService {
  init(language: KeyboardLayoutLanguage) {
    let base: KeyboardLayout.DeviceBasedLayoutService
    switch language {
    case .russian:
      base = KeyboardLayout.DeviceBasedLayoutService(
        alphabeticInputSet: .init(rows: [
          .init(chars: "йцукенгшщзх"),
          .init(chars: "фывапролджэ"),
          .init(chars: "ячсмитьбю"),
        ]),
        numericInputSet: .numeric(currency: "₽"),
        symbolicInputSet: .symbolic
      )
    case .english:
      base = KeyboardLayout.DeviceBasedLayoutService()
    }
    super.init(baseService: base)
  }

  override func keyboardLayout(for context: KeyboardContext) -> KeyboardLayout {
    var layout = super.keyboardLayout(for: context)
    for row in layout.itemRows.indices {
      for index in layout.itemRows[row].indices
      where layout.itemRows[row][index].action == .keyboardType(.emojis) {
        layout.itemRows[row][index].action = .dictation
      }
    }
    return layout
  }
}

/// KeyboardKit's standard handling, plus our dictation key, the typing lock
/// during a dictation, and the per-press measurement.
private final class VelikiyMoguchiyActionHandler: KeyboardAction.StandardActionHandler {
  weak var surface: KeyboardSurfaceView?

  override func handle(_ gesture: Keyboard.Gesture, on action: KeyboardAction, replaced: Bool) {
    guard let surface else { return super.handle(gesture, on: action, replaced: replaced) }
    if action == .dictation {
      guard gesture == .release, surface.microphoneIsEnabled else { return }
      surface.delegate?.keyboardSurfaceMicrophoneTapped(surface)
      surface.onKeyOutput?()
      return
    }
    guard surface.typingEnabled else { return }
    // A replacement action re-enters with `replaced: true`; count the press once.
    let producesOutput = !replaced && (gesture == .press || gesture == .release)
      && canHandle(gesture, on: action)
    super.handle(gesture, on: action, replaced: replaced)
    if producesOutput { surface.onKeyOutput?() }
  }
}
