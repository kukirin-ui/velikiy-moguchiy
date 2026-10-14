import Darwin
import Foundation
import UIKit

// MARK: - App Group identifier

/// The App Group shared by the app and both keyboards. It is read at runtime
/// from ONE place so a re-signing tool can change it consistently:
///
/// 1. the `application-groups` entitlement of the installed build (read from
///    the embedded provisioning profile, which a re-signer rewrites together
///    with the entitlements), then
/// 2. the `AppGroupID` Info.plist key (set from `VELIKIY_MOGUCHIY_APP_GROUP_IDENTIFIER`
///    in the xcconfig, the same variable the .entitlements files use),
/// 3. a built-in default.
enum VoiceAppGroup {
  static let defaultIdentifier = "group.com.example.velikiy-moguchiy"

  static let identifier: String = resolveIdentifier(
    infoValue: Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String,
    entitledGroups: embeddedProfileApplicationGroups()
  )

  static func resolveIdentifier(infoValue: String?, entitledGroups: [String]) -> String {
    let configured = infoValue?.trimmingCharacters(in: .whitespacesAndNewlines)
      .nonEmptyValue
    if let configured, entitledGroups.isEmpty || entitledGroups.contains(configured) {
      return configured
    }
    // A re-signer rewrote the group: trust what the build is actually entitled to.
    if let first = entitledGroups.first { return first }
    return configured ?? defaultIdentifier
  }

  /// `application-groups` of the embedded provisioning profile, if the build
  /// has one (device builds do; the simulator does not).
  static func embeddedProfileApplicationGroups(bundle: Bundle = .main) -> [String] {
    guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
      let data = try? Data(contentsOf: url)
    else { return [] }
    // The profile is a CMS blob around an XML plist: cut the plist out.
    guard let start = data.range(of: Data("<?xml".utf8)),
      let end = data.range(of: Data("</plist>".utf8))
    else { return [] }
    let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
    guard
      let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil)
        as? [String: Any],
      let entitlements = plist["Entitlements"] as? [String: Any],
      let groups = entitlements["com.apple.security.application-groups"] as? [String]
    else { return [] }
    return groups
  }

  static var containerURL: URL? {
    FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: identifier
    )
  }

  /// Directory for data only the containing app uses (recordings, history).
  /// The App Group container when there is one, otherwise the app's own
  /// Application Support folder, so the app also works without an App Group.
  static var appDataDirectory: URL? {
    if let containerURL { return containerURL }
    guard
      let support = try? FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask,
        appropriateFor: nil, create: true)
    else { return nil }
    return resolveAppDataDirectory(in: support)
  }

  /// `VelikiyMoguchiy` inside `support`, or the folder of builds from before
  /// the rename while only that one exists, so their recordings and history stay.
  static func resolveAppDataDirectory(in support: URL, fileManager: FileManager = .default) -> URL {
    let current = support.appendingPathComponent("VelikiyMoguchiy", isDirectory: true)
    let legacy = support.appendingPathComponent(legacyAppDataFolderName, isDirectory: true)
    var legacyIsDirectory: ObjCBool = false
    if !fileManager.fileExists(atPath: current.path),
      fileManager.fileExists(atPath: legacy.path, isDirectory: &legacyIsDirectory),
      legacyIsDirectory.boolValue
    {
      return legacy
    }
    return current
  }

  /// Application Support folder name used before the rename.
  static let legacyAppDataFolderName = "Govorun"
}

extension String {
  fileprivate var nonEmptyValue: String? {
    isEmpty ? nil : self
  }
}

// MARK: - Storage abstraction

/// The slice of `UserDefaults` the relay protocol uses. `UserDefaults` backed
/// by an App Group is the primary implementation; a pair of named pasteboards
/// is the fallback for builds without a usable App Group.
protocol RelayKeyValueStorage: AnyObject {
  func integer(forKey key: String) -> Int
  func double(forKey key: String) -> Double
  func string(forKey key: String) -> String?
  func bool(forKey key: String) -> Bool
  func object(forKey key: String) -> Any?
  func set(_ value: Any?, forKey key: String)
  func removeObject(forKey key: String)
  @discardableResult func synchronize() -> Bool
  /// `false` when this process may not write `key` (single-writer transport).
  func ownsKey(_ key: String) -> Bool
  /// Single-writer transports cannot clear the other side's keys; the store
  /// uses acknowledgement markers instead.
  var isSingleWriterPartitioned: Bool { get }
}

extension UserDefaults: RelayKeyValueStorage {
  func ownsKey(_ key: String) -> Bool { true }
  var isSingleWriterPartitioned: Bool { false }
}

// MARK: - Transport selection

enum RelayTransportKind: String, Equatable, Sendable {
  case appGroup
  case pasteboard

  /// The shared container must exist and be writable; otherwise the relay
  /// switches to the named-pasteboard fallback.
  static func select(containerIsUsable: Bool) -> RelayTransportKind {
    containerIsUsable ? .appGroup : .pasteboard
  }

  var title: String {
    switch self {
    case .appGroup: return "App Group"
    case .pasteboard: return "резервный канал"
    }
  }
}

enum RelayProcessRole: Equatable {
  case app
  case keyboard

  static var current: RelayProcessRole {
    Bundle.main.bundlePath.hasSuffix(".appex") ? .keyboard : .app
  }
}

/// The relay channel of this process, chosen once at first use.
final class RelayTransport: @unchecked Sendable {
  static let shared = RelayTransport(role: .current)

  let kind: RelayTransportKind
  let role: RelayProcessRole
  let storage: any RelayKeyValueStorage

  init(role: RelayProcessRole, containerIsUsable: Bool? = nil) {
    self.role = role
    let usable = containerIsUsable ?? Self.probeContainer()
    kind = RelayTransportKind.select(containerIsUsable: usable)
    NSLog("RELAY_TRANSPORT role=%@ kind=%@", role == .app ? "app" : "keyboard", kind.rawValue)
    switch kind {
    case .appGroup:
      storage = UserDefaults(suiteName: VoiceAppGroup.identifier) ?? .standard
    case .pasteboard:
      storage = PasteboardKeyValueStorage(
        role: role,
        appToKeyboard: SystemRelayPasteboard(name: "\(VoiceAppGroup.identifier).relay.app"),
        keyboardToApp: SystemRelayPasteboard(name: "\(VoiceAppGroup.identifier).relay.keyboard"),
        signals: DarwinRelaySignals(prefix: VoiceAppGroup.identifier)
      )
    }
  }

  /// A usable container is one the process can actually write to.
  private static func probeContainer() -> Bool {
    guard let url = VoiceAppGroup.containerURL else { return false }
    let probe = url.appendingPathComponent(".relay-probe-\(getpid())")
    do {
      try Data([1]).write(to: probe)
      try? FileManager.default.removeItem(at: probe)
      return true
    } catch {
      return false
    }
  }
}

// MARK: - Pasteboard backend

protocol RelayPasteboardBackend: AnyObject {
  var changeCount: Int { get }
  func read() -> Data?
  func write(_ data: Data)
}

/// A team-scoped named pasteboard. Named pasteboards are visible to the other
/// processes signed by the same team, which is exactly app + keyboards.
final class SystemRelayPasteboard: RelayPasteboardBackend {
  static let dataType = "velikiy-moguchiy.relay-state"
  private let name: String
  private var pasteboard: UIPasteboard? {
    UIPasteboard(name: UIPasteboard.Name(rawValue: name), create: true)
  }

  init(name: String) {
    self.name = name
  }

  var changeCount: Int { pasteboard?.changeCount ?? 0 }

  func read() -> Data? {
    pasteboard?.data(forPasteboardType: Self.dataType)
  }

  func write(_ data: Data) {
    guard let pasteboard else { return }
    pasteboard.setItems(
      [[Self.dataType: data]],
      options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(15 * 60)]
    )
  }
}

// MARK: - Darwin notifications

protocol RelaySignalling: AnyObject {
  func post(_ event: RelaySignalEvent)
  func observe(_ event: RelaySignalEvent, handler: @escaping () -> Void)
}

enum RelaySignalEvent: String {
  /// The keyboard wrote a command or a launch request.
  case keyboardChanged = "keyboard-changed"
  /// The app wrote status, a live preview or a result.
  case appChanged = "app-changed"
}

/// Wake-up signals between processes. They carry no payload; the data lives in
/// the pasteboards. Observers must tolerate spurious and coalesced signals.
final class DarwinRelaySignals: RelaySignalling {
  private let prefix: String
  private final class Box {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
  }
  private var boxes: [Box] = []

  init(prefix: String) {
    self.prefix = prefix
  }

  deinit {
    // The registered observer pointers are the boxes; drop them so a late
    // notification can never reach a freed handler.
    for box in boxes {
      CFNotificationCenterRemoveEveryObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        Unmanaged.passUnretained(box).toOpaque()
      )
    }
  }

  func post(_ event: RelaySignalEvent) {
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      CFNotificationName("\(prefix).relay.\(event.rawValue)" as CFString),
      nil, nil, true
    )
  }

  func observe(_ event: RelaySignalEvent, handler: @escaping () -> Void) {
    let box = Box(handler)
    boxes.append(box)
    CFNotificationCenterAddObserver(
      CFNotificationCenterGetDarwinNotifyCenter(),
      Unmanaged.passUnretained(box).toOpaque(),
      { _, observer, _, _, _ in
        guard let observer else { return }
        Unmanaged<Box>.fromOpaque(observer).takeUnretainedValue().handler()
      },
      "\(prefix).relay.\(event.rawValue)" as CFString,
      nil,
      .deliverImmediately
    )
  }
}

// MARK: - Pasteboard key-value storage

/// A `UserDefaults`-like store split between two named pasteboards, each with
/// exactly one writer, so two processes never overwrite each other:
///
/// - the keyboard writes commands and launch requests (`keyboardToApp`),
/// - the app writes status, previews, results and everything else (`appToKeyboard`).
///
/// Reads merge both sides. A `set` on a key the process does not own is
/// refused; `SharedRelayStore` uses acknowledgement keys for those cases.
final class PasteboardKeyValueStorage: RelayKeyValueStorage {
  private let role: RelayProcessRole
  private let appToKeyboard: RelayPasteboardBackend
  private let keyboardToApp: RelayPasteboardBackend
  private let signals: RelaySignalling?
  private let lock = NSLock()

  private var ownValues: [String: Any] = [:]
  private var remoteValues: [String: Any] = [:]
  private var remoteChangeCount = -1
  private var isDirty = false

  /// Called (on an arbitrary thread) when the other process signalled a change.
  var onRemoteChange: (() -> Void)? {
    didSet { observeIfNeeded() }
  }
  private var isObserving = false

  var isSingleWriterPartitioned: Bool { true }

  init(
    role: RelayProcessRole,
    appToKeyboard: RelayPasteboardBackend,
    keyboardToApp: RelayPasteboardBackend,
    signals: RelaySignalling? = nil
  ) {
    self.role = role
    self.appToKeyboard = appToKeyboard
    self.keyboardToApp = keyboardToApp
    self.signals = signals
    ownValues = Self.decode(ownBackend.read())
  }

  private var ownBackend: RelayPasteboardBackend {
    role == .app ? appToKeyboard : keyboardToApp
  }
  private var remoteBackend: RelayPasteboardBackend {
    role == .app ? keyboardToApp : appToKeyboard
  }

  /// Keys the keyboard writes; everything else belongs to the app.
  static func isKeyboardKey(_ key: String) -> Bool {
    if key == "relay.command.handled-sequence" { return false }
    return key.hasPrefix("relay.command.")
      || key.hasPrefix("relay.launch.pending")
      || key.hasPrefix("relay.legacy-launch.")
      || key == "relay.result.acked"
      || key.hasPrefix("relay.keyboard.")
  }

  func ownsKey(_ key: String) -> Bool {
    Self.isKeyboardKey(key) == (role == .keyboard)
  }

  // MARK: reads

  func object(forKey key: String) -> Any? {
    lock.lock()
    defer { lock.unlock() }
    if ownsKey(key) { return ownValues[key] }
    refreshRemoteLocked()
    return remoteValues[key]
  }

  func integer(forKey key: String) -> Int {
    (object(forKey: key) as? NSNumber)?.intValue ?? 0
  }

  func double(forKey key: String) -> Double {
    (object(forKey: key) as? NSNumber)?.doubleValue ?? 0
  }

  func bool(forKey key: String) -> Bool {
    (object(forKey: key) as? NSNumber)?.boolValue ?? false
  }

  func string(forKey key: String) -> String? {
    object(forKey: key) as? String
  }

  // MARK: writes

  func set(_ value: Any?, forKey key: String) {
    guard let value else {
      removeObject(forKey: key)
      return
    }
    lock.lock()
    defer { lock.unlock() }
    guard ownsKey(key) else {
      assertionFailure("relay key \(key) is written by the other process")
      return
    }
    ownValues[key] = value
    isDirty = true
  }

  func removeObject(forKey key: String) {
    lock.lock()
    defer { lock.unlock() }
    guard ownsKey(key) else { return }
    if ownValues.removeValue(forKey: key) != nil { isDirty = true }
  }

  @discardableResult
  func synchronize() -> Bool {
    lock.lock()
    let dirty = isDirty
    let snapshot = ownValues
    isDirty = false
    lock.unlock()
    guard dirty else { return true }
    if let data = try? PropertyListSerialization.data(
      fromPropertyList: snapshot, format: .binary, options: 0)
    {
      ownBackend.write(data)
      signals?.post(role == .app ? .appChanged : .keyboardChanged)
    }
    return true
  }

  // MARK: remote

  private func refreshRemoteLocked() {
    let count = remoteBackend.changeCount
    guard count != remoteChangeCount else { return }
    remoteChangeCount = count
    remoteValues = Self.decode(remoteBackend.read())
  }

  private static func decode(_ data: Data?) -> [String: Any] {
    guard let data,
      let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
      let dictionary = object as? [String: Any]
    else { return [:] }
    return dictionary
  }

  private func observeIfNeeded() {
    guard !isObserving, onRemoteChange != nil, let signals else { return }
    isObserving = true
    let event: RelaySignalEvent = role == .app ? .keyboardChanged : .appChanged
    signals.observe(event) { [weak self] in
      self?.onRemoteChange?()
    }
  }
}
