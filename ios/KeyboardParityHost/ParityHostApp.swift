import UIKit

/// A bare UIKit text field for the keyboard parity gate: Apple's keyboard and
/// ours are photographed over the same field. The field is configured from the
/// launch environment (PARITY_KIND, PARITY_RETURN, PARITY_AUTOCORRECT).
@main
final class ParityHostAppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    let window = UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = ParityFieldViewController()
    window.makeKeyAndVisible()
    self.window = window
    return true
  }
}

final class ParityFieldViewController: UIViewController {
  private let field = UITextField()

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemGroupedBackground
    let env = ProcessInfo.processInfo.environment
    field.keyboardType = Self.keyboardType(env["PARITY_KIND"])
    field.returnKeyType = Self.returnKeyType(env["PARITY_RETURN"])
    field.autocorrectionType = env["PARITY_AUTOCORRECT"] == "0" ? .no : .default
    field.placeholder = "Поле"
    field.borderStyle = .roundedRect
    field.accessibilityIdentifier = "parity-field"
    field.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(field)
    NSLayoutConstraint.activate([
      field.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
      field.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
      field.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 40),
    ])
  }

  private var keyboardObserver: NSObjectProtocol?
  private var changeObserver: NSObjectProtocol?

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    keyboardObserver = NotificationCenter.default.addObserver(
      forName: UIResponder.keyboardDidShowNotification, object: nil, queue: .main
    ) { note in
      let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
      NSLog("PARITYHOST keyboard frame y=%.2f h=%.2f", frame.minY, frame.height)
    }
    changeObserver = NotificationCenter.default.addObserver(
      forName: UIResponder.keyboardDidChangeFrameNotification, object: nil, queue: .main
    ) { note in
      let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
      NSLog("PARITYHOST keyboard change y=%.2f h=%.2f", frame.minY, frame.height)
    }
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    field.becomeFirstResponder()
  }

  private static func keyboardType(_ kind: String?) -> UIKeyboardType {
    switch kind {
    case "number": return .numberPad
    case "decimal": return .decimalPad
    case "web": return .webSearch
    case "url": return .URL
    case "email": return .emailAddress
    case "twitter": return .twitter
    case "numpunct": return .numbersAndPunctuation
    default: return .default
    }
  }

  private static func returnKeyType(_ name: String?) -> UIReturnKeyType {
    switch name {
    case "go": return .go
    case "search": return .search
    case "send": return .send
    case "done": return .done
    case "next": return .next
    default: return .default
    }
  }
}
