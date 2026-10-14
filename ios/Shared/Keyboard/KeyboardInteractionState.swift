import Foundation

// This project-local layout/state engine adapts concepts from KeyboardKit
// 9.9.1. That release is MIT licensed; see THIRD_PARTY_NOTICES.md. The sample
// does not link or download KeyboardKit.

/// Letter layout of a keyboard. The Russian and English keyboards are two
/// separate extensions (each with its own `PrimaryLanguage`), so the system
/// globe key switches between them the way it does between Apple's keyboards.
enum KeyboardLayoutLanguage: String, Equatable {
  case english
  case russian

  /// Letter rows as Apple ships them on iPhone: QWERTY / ЙЦУКЕН.
  var letterRowStrings: [String] {
    switch self {
    case .english: return ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
    case .russian: return ["йцукенгшщзх", "фывапролджэ", "ячсмитьбю"]
    }
  }

  var pageToggleTitle: String { self == .russian ? "АБВ" : "ABC" }
  /// Accessibility name of the space bar. Apple's space bar carries no visible
  /// title on iOS 26; the Russian one shows a small "ру" in its corner.
  var spaceTitle: String { self == .russian ? "пробел" : "space" }
  var spaceCornerLabel: String { self == .russian ? "ру" : "A" }
  var defaultReturnTitle: String { self == .russian ? "ввод" : "return" }
  /// Currency key on the numbers page (Apple uses the ruble on the Russian keyboard).
  var numbersCurrencyKey: String { self == .russian ? "₽" : "$" }
  /// Domain key on URL keyboards: Apple shows ".com" on the Russian keyboard too.
  var primaryDomainKey: String { ".com" }
}

enum KeyboardPage: Equatable {
  case letters
  case numbers
  case symbols
}

enum KeyboardCapitalization: Equatable {
  case lowercase
  case shifted
  case capsLock
}

/// What the text field wants, reduced to the layouts this keyboard has.
enum KeyboardInputKind: Equatable {
  case standard
  case email
  case url
  /// Safari's address bar and search fields: URL keys plus a space bar.
  case webSearch
  /// Twitter-style fields: `@` and `#` next to the space bar.
  case twitter
  /// Digits only (codes, SMS codes, PINs).
  case numberPad
  /// Digits and a decimal separator (amounts).
  case decimalPad

  var isDigitPad: Bool { self == .numberPad || self == .decimalPad }
  /// Fields where typographic replacements and corrections must stay off.
  var isTechnical: Bool {
    switch self {
    case .email, .url, .webSearch, .numberPad, .decimalPad: return true
    case .standard, .twitter: return false
    }
  }
}

enum KeyboardKeyStyle: Equatable {
  /// Letters, digits and punctuation: show the press popup.
  case input
  /// Function keys (shift, delete, 123, globe, mic, space, return).
  case system
  /// The blue return key (go / search / send / done ...).
  case accent
  /// No key cap, only the glyph: ⌫ and the decimal separator on the digit pad.
  case plain
}

enum KeyboardKeyAction: Equatable {
  case text(String)
  case shift
  case backspace
  case page
  case nextKeyboard
  case microphone
  case space
  case returnKey
  /// An empty cell that is neither drawn nor hit (the digit pad's corner).
  case blank
}

struct KeyboardLayoutKey: Equatable {
  let action: KeyboardKeyAction
  /// Relative weight, used by `.fill` rows to share leftover width.
  let width: Double
  let style: KeyboardKeyStyle
  /// Absolute width in points on a 402-point-wide (iPhone 17 Pro) keyboard.
  /// It is scaled with the keyboard width. `nil` means "letter width" in a
  /// `.centered` row and "flexible by `width`" in a `.fill` row.
  let fixedPoints: Double?
  /// Large title (digit pad keys).
  let emphasized: Bool
  /// Small letters under a digit pad digit ("ABC").
  let subtitle: String?

  init(
    _ action: KeyboardKeyAction,
    width: Double = 1,
    style: KeyboardKeyStyle = .input,
    fixedPoints: Double? = nil,
    emphasized: Bool = false,
    subtitle: String? = nil
  ) {
    self.action = action
    self.width = width
    self.style = style
    self.fixedPoints = fixedPoints
    self.emphasized = emphasized
    self.subtitle = subtitle
  }
}

enum KeyboardRowArrangement: Equatable {
  /// Apple's letter rows: every letter key has the same width, the group is
  /// centered, and fixed-width side keys (shift, delete) sit at the edges.
  case centered
  /// Keys span the whole row; keys without `fixedPoints` share what is left.
  case fill
}

struct KeyboardLayoutRow: Equatable {
  let keys: [KeyboardLayoutKey]
  let arrangement: KeyboardRowArrangement

  init(_ keys: [KeyboardLayoutKey], arrangement: KeyboardRowArrangement = .centered) {
    self.keys = keys
    self.arrangement = arrangement
  }
}

/// Measured on the iOS 26.3 system keyboard (iPhone 17 Pro, 402 pt wide, and
/// iPhone 16, 393 pt). The side margin and the gap between keys stay the same
/// on every phone width; fixed-width keys scale with the width and letters
/// take the rest.
enum KeyboardMetrics {
  static let referenceWidth: Double = 402
  static let sideMargin: Double = 6.5
  static let keyGap: Double = 6
  static let keyHeight: Double = 43
  static let rowGap: Double = 11
  static let keyCornerRadius: Double = 8
  /// Shift / delete on the English letter page and "#+=" on the symbol pages.
  static let sideKeyPoints: Double = 136.0 / 3.0
  static let bottomKeyPoints: Double = 130.0 / 3.0
  static let returnKeyPoints: Double = 93
  /// The five punctuation keys on the number and symbol pages.
  static let punctuationKeyPoints: Double = 50
  /// Web search bottom row: the "." key and the narrower Go key.
  static let webSearchPeriodPoints: Double = 100.0 / 3.0
  static let webSearchReturnPoints: Double = 63

  /// Digit pad (iPhone 16, 393 pt, against Apple's in the parity gate): 48 pt
  /// keys, 8 pt apart side by side and 6 pt between rows; the grid sits
  /// 2.67 pt from the left edge and 8.33 pt from the right one.
  enum DigitPad {
    static let keyHeight: Double = 48
    static let columnGap: Double = 8
    static let rowGap: Double = 6
    static let leftMargin: Double = 8.0 / 3.0
    static let rightMargin: Double = 25.0 / 3.0
    static var gridHeight: Double { keyHeight * 4 + rowGap * 3 }
    /// Its rows start 1 pt higher than a letter keyboard without a strip and
    /// reach the bottom edge. Apple's last row ends 1 pt lower still, which a
    /// keyboard extension cannot draw.
    static let topAdjustment: Double = -1
    static let bottomPadding: Double = 0
  }
  static var gridHeight: Double { keyHeight * 4 + rowGap * 3 }
}

/// Metrics of the key grid. Portrait values scale with the width (measured on a
/// 402 pt iPhone 17 Pro); landscape values are absolute points measured on the
/// iOS 26.3 system keyboard rotated on the same phone (874 x 402 pt).
struct KeyboardGeometry: Equatable {
  var keyHeight: Double
  var rowGap: Double
  /// Height of the suggestion strip above the keys.
  var toolbarHeight: Double
  /// Space under the last row.
  var bottomPadding: Double
  var isLandscape = false
  /// Landscape only: distance of the key grid from the screen edge.
  var gridInset: Double = 0
  var keyGap: Double = KeyboardMetrics.keyGap
  var sideKeyPoints: Double = KeyboardMetrics.sideKeyPoints
  var bottomKeyPoints: Double = KeyboardMetrics.bottomKeyPoints
  var returnKeyPoints: Double = KeyboardMetrics.returnKeyPoints
  var punctuationKeyPoints: Double = KeyboardMetrics.punctuationKeyPoints

  var gridHeight: Double { keyHeight * 4 + rowGap * 3 }

  /// Space above the keys. Without the suggestion strip Apple's keyboard is
  /// 27 pt shorter and the keys stay where they were (iOS 26.2, Safari's
  /// address bar against a plain text field).
  func topHeight(showsStrip: Bool) -> Double {
    showsStrip ? toolbarHeight : toolbarHeight - 27
  }

  func totalHeight(showsStrip: Bool) -> Double {
    topHeight(showsStrip: showsStrip) + gridHeight + bottomPadding
  }

  static let portrait = KeyboardGeometry(
    keyHeight: KeyboardMetrics.keyHeight, rowGap: KeyboardMetrics.rowGap,
    toolbarHeight: 52, bottomPadding: 3)

  /// Measured with `Scripts/capture_one.sh ... landscape`: keys 27.33 pt high on a
  /// 35.33 pt pitch, letters 65.1 pt wide with 7.3 pt gaps, shift/delete 88 pt,
  /// return 138 pt, the key grid starts 78.7 pt from each edge of the screen, the
  /// suggestion strip is 49 pt, 5 pt under the last row.
  static let landscape = KeyboardGeometry(
    keyHeight: 27.33, rowGap: 8, toolbarHeight: 49, bottomPadding: 5,
    isLandscape: true, gridInset: 78.7, keyGap: 7.3, sideKeyPoints: 88,
    bottomKeyPoints: 65.1, returnKeyPoints: 138, punctuationKeyPoints: 74)
}

struct KeyboardInteractionState: Equatable {
  private static let doubleTapInterval: TimeInterval = 0.32

  let language: KeyboardLayoutLanguage
  /// Separator on the decimal pad: the user's region decides, like Apple's.
  var decimalSeparator: String
  private(set) var page: KeyboardPage = .letters
  private(set) var capitalization: KeyboardCapitalization = .lowercase
  private var lastShiftTapTimestamp: TimeInterval?

  init(
    language: KeyboardLayoutLanguage = .english,
    decimalSeparator: String = Locale.current.decimalSeparator ?? "."
  ) {
    self.language = language
    self.decimalSeparator = decimalSeparator
  }

  var usesUppercaseLetters: Bool {
    capitalization != .lowercase
  }

  var isCapsLocked: Bool {
    capitalization == .capsLock
  }

  mutating func tapShift(at timestamp: TimeInterval) {
    switch page {
    case .letters:
      if capitalization == .capsLock {
        capitalization = .lowercase
        lastShiftTapTimestamp = nil
        return
      }

      // Two taps within the interval always mean Caps Lock, also when the first
      // tap cancelled an automatic capital at the start of a sentence.
      let isDoubleTap =
        lastShiftTapTimestamp.map {
          timestamp >= $0 && timestamp - $0 < Self.doubleTapInterval
        } ?? false

      if isDoubleTap {
        capitalization = .capsLock
        lastShiftTapTimestamp = nil
      } else {
        capitalization = capitalization == .lowercase ? .shifted : .lowercase
        lastShiftTapTimestamp = timestamp
      }
    case .numbers:
      page = .symbols
    case .symbols:
      page = .numbers
    }
  }

  /// Number and punctuation fields open on the "123" page.
  mutating func showNumbers() {
    page = .numbers
    capitalization = .lowercase
    lastShiftTapTimestamp = nil
  }

  mutating func tapPage() {
    page = page == .letters ? .numbers : .letters
    capitalization = .lowercase
    lastShiftTapTimestamp = nil
  }

  mutating func consumeText() {
    guard page == .letters, capitalization == .shifted else { return }
    capitalization = .lowercase
    lastShiftTapTimestamp = nil
  }

  mutating func applyAutomaticCapitalization(_ requested: KeyboardCapitalization) {
    guard page == .letters, capitalization != .capsLock else { return }
    capitalization = requested
    if requested != .shifted {
      lastShiftTapTimestamp = nil
    }
  }

  func layout(inputKind: KeyboardInputKind, needsInputModeSwitchKey: Bool) -> [KeyboardLayoutRow] {
    if inputKind.isDigitPad {
      return digitPadRows(inputKind: inputKind, needsInputModeSwitchKey: needsInputModeSwitchKey)
    }
    switch page {
    case .letters:
      return letterRows(inputKind: inputKind, needsInputModeSwitchKey: needsInputModeSwitchKey)
    case .numbers:
      return numberRows(inputKind: inputKind, needsInputModeSwitchKey: needsInputModeSwitchKey)
    case .symbols:
      return symbolRows(inputKind: inputKind, needsInputModeSwitchKey: needsInputModeSwitchKey)
    }
  }

  func alternateCharacters(for text: String) -> [String] {
    let values: [String]
    switch text.lowercased() {
    case "е" where language == .russian: values = ["е", "ё"]
    case "ь" where language == .russian: values = ["ь", "ъ"]
    case "a" where language == .english: values = ["a", "à", "á", "â", "ä", "æ", "ã", "å", "ā"]
    case "c" where language == .english: values = ["c", "ç", "ć", "č"]
    case "e" where language == .english: values = ["e", "è", "é", "ê", "ë", "ē", "ė", "ę"]
    case "i" where language == .english: values = ["i", "ì", "í", "î", "ï", "ī", "į"]
    case "l" where language == .english: values = ["l", "ł"]
    case "n" where language == .english: values = ["n", "ñ", "ń"]
    case "o" where language == .english: values = ["o", "ò", "ó", "ô", "ö", "œ", "ø", "õ", "ō"]
    case "s" where language == .english: values = ["s", "ß", "ś", "š"]
    case "u" where language == .english: values = ["u", "ù", "ú", "û", "ü", "ū"]
    case "y" where language == .english: values = ["y", "ý", "ÿ"]
    case "z" where language == .english: values = ["z", "ž", "ź", "ż"]
    case "$", "₽": values = ["$", "€", "£", "¥", "₽", "¢"]
    case "0": values = ["0", "°"]
    case "?": values = ["?", "¿"]
    case "!": values = ["!", "¡"]
    case "&": values = ["&", "§"]
    case "%": values = ["%", "‰"]
    case ".": values = [".", "…"]
    case "-": values = ["-", "–", "—", "•"]
    case "'": values = ["'", "’", "‘", "`"]
    case "\"" where language == .russian: values = ["\"", "«", "»", "„", "“", "”"]
    case "\"": values = ["\"", "”", "“", "„"]
    case ".com", ".ru": values = language == .russian
      ? [".ru", ".com", ".org", ".net", ".edu"] : [".com", ".ru", ".org", ".net", ".edu"]
    default: return []
    }
    // Only letter popups follow Shift; punctuation and ".com" variants do not.
    guard usesUppercaseLetters, text == text.uppercased(), text.first?.isLetter == true else {
      return values
    }
    return values.map { $0.uppercased() }
  }
}

private extension KeyboardInteractionState {
  func textKeys(_ text: String) -> [KeyboardLayoutKey] {
    text.map {
      let value = usesUppercaseLetters ? String($0).uppercased() : String($0)
      return KeyboardLayoutKey(.text(value))
    }
  }

  func literalKeys(_ values: [String]) -> [KeyboardLayoutKey] {
    values.map { KeyboardLayoutKey(.text($0)) }
  }

  var sideKey: KeyboardLayoutKey {
    // Apple's Russian layout has 11 keys per row, so shift/delete are as wide
    // as a letter; the English layout gives them 44.67 pt.
    KeyboardLayoutKey(
      .shift, style: .system,
      fixedPoints: language == .english ? KeyboardMetrics.sideKeyPoints : nil)
  }

  var deleteKey: KeyboardLayoutKey {
    KeyboardLayoutKey(
      .backspace, style: .system,
      fixedPoints: language == .english ? KeyboardMetrics.sideKeyPoints : nil)
  }

  func letterRows(
    inputKind: KeyboardInputKind,
    needsInputModeSwitchKey: Bool
  ) -> [KeyboardLayoutRow] {
    let rows = language.letterRowStrings
    return [
      KeyboardLayoutRow(textKeys(rows[0])),
      KeyboardLayoutRow(textKeys(rows[1])),
      KeyboardLayoutRow([sideKey] + textKeys(rows[2]) + [deleteKey]),
      bottomRow(inputKind: inputKind, needsInputModeSwitchKey: needsInputModeSwitchKey),
    ]
  }

  /// "#+=" / "123" and delete flank five punctuation keys that stretch.
  func symbolThirdRow(_ punctuation: [String]) -> KeyboardLayoutRow {
    let side = KeyboardMetrics.sideKeyPoints
    return KeyboardLayoutRow(
      [KeyboardLayoutKey(.shift, style: .system, fixedPoints: side)]
        + punctuation.map {
          KeyboardLayoutKey(.text($0), fixedPoints: KeyboardMetrics.punctuationKeyPoints)
        }
        + [KeyboardLayoutKey(.backspace, style: .system, fixedPoints: side)]
    )
  }

  func numberRows(
    inputKind: KeyboardInputKind,
    needsInputModeSwitchKey: Bool
  ) -> [KeyboardLayoutRow] {
    [
      KeyboardLayoutRow(literalKeys(Array("1234567890").map(String.init))),
      KeyboardLayoutRow(
        literalKeys(["-", "/", ":", ";", "(", ")", language.numbersCurrencyKey, "&", "@", "\""])),
      symbolThirdRow([".", ",", "?", "!", "'"]),
      bottomRow(inputKind: inputKind, needsInputModeSwitchKey: needsInputModeSwitchKey),
    ]
  }

  func symbolRows(
    inputKind: KeyboardInputKind,
    needsInputModeSwitchKey: Bool
  ) -> [KeyboardLayoutRow] {
    let currencies =
      language == .russian
      ? ["_", "\\", "|", "~", "<", ">", "$", "€", "£", "•"]
      : ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"]
    return [
      KeyboardLayoutRow(literalKeys(["[", "]", "{", "}", "#", "%", "^", "*", "+", "="])),
      KeyboardLayoutRow(literalKeys(currencies)),
      symbolThirdRow([".", ",", "?", "!", "'"]),
      bottomRow(inputKind: inputKind, needsInputModeSwitchKey: needsInputModeSwitchKey),
    ]
  }

  /// Apple's bottom row is [123] [emoji slot] [space] [return]. A third-party
  /// keyboard cannot open the emoji keyboard, so the dictation microphone
  /// takes that slot. The globe appears only when iOS asks for it.
  func bottomRow(
    inputKind: KeyboardInputKind,
    needsInputModeSwitchKey: Bool
  ) -> KeyboardLayoutRow {
    let small = KeyboardMetrics.bottomKeyPoints
    var keys = [KeyboardLayoutKey(.page, style: .system, fixedPoints: small)]
    if needsInputModeSwitchKey {
      keys.append(KeyboardLayoutKey(.nextKeyboard, style: .system, fixedPoints: small))
    }
    keys.append(KeyboardLayoutKey(.microphone, style: .system, fixedPoints: small))

    switch inputKind {
    case .standard:
      keys.append(KeyboardLayoutKey(.space, style: .input))
    case .email:
      keys += [
        KeyboardLayoutKey(.space, style: .input),
        KeyboardLayoutKey(.text("@"), style: .system, fixedPoints: small),
        KeyboardLayoutKey(.text("."), style: .system, fixedPoints: small),
      ]
    case .twitter:
      keys += [
        KeyboardLayoutKey(.space, style: .input),
        KeyboardLayoutKey(.text("@"), style: .system, fixedPoints: small),
        KeyboardLayoutKey(.text("#"), style: .system, fixedPoints: small),
      ]
    case .webSearch:
      // Apple: [123] [emoji] [space] [.] [go]. Without the space bar a
      // multi-word query cannot be typed.
      keys += [
        KeyboardLayoutKey(.space, style: .input),
        KeyboardLayoutKey(.text("."), style: .system, fixedPoints: KeyboardMetrics.webSearchPeriodPoints),
      ]
    case .url:
      // ".", "/" and the domain share the row equally.
      keys += [
        KeyboardLayoutKey(.text("."), style: .system),
        KeyboardLayoutKey(.text("/"), style: .system),
        KeyboardLayoutKey(.text(language.primaryDomainKey), style: .system),
      ]
    case .numberPad, .decimalPad:
      break  // digit pads have their own layout
    }
    keys.append(
      KeyboardLayoutKey(
        .returnKey, style: .system,
        fixedPoints: inputKind == .webSearch
          ? KeyboardMetrics.webSearchReturnPoints : KeyboardMetrics.returnKeyPoints))
    return KeyboardLayoutRow(keys, arrangement: .fill)
  }

  /// Apple's digit pad: 1-9, then [separator or globe] 0 delete. No letters, no
  /// microphone, no return key (a number field has none either).
  func digitPadRows(
    inputKind: KeyboardInputKind,
    needsInputModeSwitchKey: Bool
  ) -> [KeyboardLayoutRow] {
    // Apple prints the phone letters under the digits on every digit pad.
    let letters = ["2": "ABC", "3": "DEF", "4": "GHI", "5": "JKL", "6": "MNO", "7": "PQRS", "8": "TUV", "9": "WXYZ"]
    func digitRow(_ digits: String) -> KeyboardLayoutRow {
      KeyboardLayoutRow(
        digits.map {
          KeyboardLayoutKey(
            .text(String($0)), style: .system, emphasized: true, subtitle: letters[String($0)])
        },
        arrangement: .fill
      )
    }
    let corner: KeyboardLayoutKey
    if inputKind == .decimalPad {
      corner = KeyboardLayoutKey(.text(decimalSeparator), style: .plain, emphasized: true)
    } else if needsInputModeSwitchKey {
      corner = KeyboardLayoutKey(.nextKeyboard, style: .plain)
    } else {
      corner = KeyboardLayoutKey(.blank, style: .system)
    }
    return [
      digitRow("123"),
      digitRow("456"),
      digitRow("789"),
      KeyboardLayoutRow(
        [
          corner,
          KeyboardLayoutKey(.text("0"), style: .system, emphasized: true),
          KeyboardLayoutKey(.backspace, style: .plain),
        ],
        arrangement: .fill
      ),
    ]
  }
}
