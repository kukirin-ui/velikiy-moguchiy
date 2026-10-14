import XCTest

/// Captures whatever keyboard is active (Apple's or ours) over the parity host's
/// text field, once per field type, for `Scripts/parity/parity.sh`. Driven by the
/// environment (set by the script through `TEST_RUNNER_` variables):
///   PARITY_OUT      directory for `<PARITY_PREFIX>-<kind>.png` and `.ax.tsv`
///   PARITY_PREFIX   e.g. `apple-ru-dark`
///   PARITY_KINDS    comma-separated `kind:return:autocorrect` cases
/// The appearance is set from outside (`simctl ui appearance`).
final class KeyboardParityCaptureTests: XCTestCase {
  func testCaptureKeyboards() throws {
    let env = ProcessInfo.processInfo.environment
    guard let out = env["PARITY_OUT"], let prefix = env["PARITY_PREFIX"],
      let kinds = env["PARITY_KINDS"]
    else {
      throw XCTSkip("run through Scripts/parity/parity.sh")
    }
    for spec in kinds.split(separator: ",").map(String.init) {
      let parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
      guard parts.count == 3 else { continue }
      let app = XCUIApplication()
      app.launchEnvironment = [
        "PARITY_KIND": parts[0], "PARITY_RETURN": parts[1], "PARITY_AUTOCORRECT": parts[2],
      ]
      app.launch()
      // The keyboard slides in and the extension settles its first layout.
      sleep(5)
      let name = "\(prefix)-\(parts[0])-\(parts[1])-ac\(parts[2])"
      let png = XCUIScreen.main.screenshot().pngRepresentation
      try png.write(to: URL(fileURLWithPath: out).appendingPathComponent("\(name).png"))
      try keyZones(in: app).write(
        toFile: (out as NSString).appendingPathComponent("\(name).ax.tsv"), atomically: true,
        encoding: .utf8)
      app.terminate()
    }
  }

  /// Touch zones of the keys that Accessibility exposes. Apple's keyboard lists
  /// every key; a third-party keyboard runs in its own process and lists none.
  private func keyZones(in app: XCUIApplication) -> String {
    guard let root = try? app.snapshot() else { return "" }
    let keyboardTop = root.frame.height * 0.5
    var lines = ["#screen\t\(root.frame.height)"]
    func walk(_ node: XCUIElementSnapshot) {
      let f = node.frame
      if node.elementType == .key || node.elementType == .button, f.minY > keyboardTop,
        f.width > 10, f.width < 300, f.height > 20, f.height < 80
      {
        lines.append("\(node.label)\t\(f.minX)\t\(f.minY)\t\(f.width)\t\(f.height)")
      }
      node.children.forEach(walk)
    }
    walk(root)
    return lines.joined(separator: "\n")
  }
}
