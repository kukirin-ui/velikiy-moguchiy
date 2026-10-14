import UIKit

/// Maps a text field's `UIKeyboardType` to what this keyboard can show.
///
/// Apple substitutes its own pad for `phonePad` and `namePhonePad` before a
/// custom keyboard is ever asked, so those two only exist here as a safe
/// fallback (the digit pad) should a host ever pass them through.
struct KeyboardInputProfile: Equatable {
  var kind: KeyboardInputKind
  /// `numbersAndPunctuation` fields open on the "123" page.
  var startsOnNumbers: Bool
  /// Apple drops the suggestion strip (and the keyboard gets shorter) on digit
  /// pads and in technical fields with autocorrection off, e.g. Safari's
  /// address bar. Plain text and Twitter fields keep it even then.
  var showsSuggestionStrip = true

  static func resolve(
    keyboardType: UIKeyboardType?,
    returnKeyType: UIReturnKeyType? = nil,
    autocorrectionType: UITextAutocorrectionType? = nil
  ) -> KeyboardInputProfile {
    var profile = layout(keyboardType: keyboardType, returnKeyType: returnKeyType)
    switch keyboardType ?? .default {
    case .URL, .webSearch, .emailAddress, .numbersAndPunctuation:
      profile.showsSuggestionStrip = autocorrectionType != .no
    default:
      profile.showsSuggestionStrip = !profile.kind.isDigitPad
    }
    return profile
  }

  private static func layout(
    keyboardType: UIKeyboardType?, returnKeyType: UIReturnKeyType?
  ) -> KeyboardInputProfile {
    switch keyboardType ?? .default {
    case .URL where returnKeyType == .go:
      // An address bar with a Go key also takes search queries, so it needs a
      // space bar. Safari reports `.webSearch` on the simulator, but a `.URL`
      // address bar on a phone lost the space bar.
      return KeyboardInputProfile(kind: .webSearch, startsOnNumbers: false)
    case .emailAddress:
      return KeyboardInputProfile(kind: .email, startsOnNumbers: false)
    case .URL:
      return KeyboardInputProfile(kind: .url, startsOnNumbers: false)
    case .webSearch:
      return KeyboardInputProfile(kind: .webSearch, startsOnNumbers: false)
    case .twitter:
      return KeyboardInputProfile(kind: .twitter, startsOnNumbers: false)
    case .numberPad, .asciiCapableNumberPad, .phonePad, .namePhonePad:
      return KeyboardInputProfile(kind: .numberPad, startsOnNumbers: false)
    case .decimalPad:
      return KeyboardInputProfile(kind: .decimalPad, startsOnNumbers: false)
    case .numbersAndPunctuation:
      return KeyboardInputProfile(kind: .standard, startsOnNumbers: true)
    default:
      return KeyboardInputProfile(kind: .standard, startsOnNumbers: false)
    }
  }
}
