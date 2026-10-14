import Foundation

/// VoiceOver names of the function keys. They follow the system language, as on
/// Apple's keyboard, so a Russian iPhone hears "удалить" on both Великий & Могучий RU and
/// Великий & Могучий EN.
struct KeyboardAccessibilityStrings: Equatable {
  var delete: String
  var shift: String
  var capsLock: String
  var moreSymbols: String
  var numbers: String
  var letters: String
  var symbols: String
  var nextKeyboard: String
  var space: String
  var spaceRussianKeyboard: String
  var `return`: String

  static let russian = KeyboardAccessibilityStrings(
    delete: "удалить", shift: "Shift", capsLock: "Caps Lock", moreSymbols: "ещё",
    numbers: "цифры", letters: "буквы", symbols: "символы",
    nextKeyboard: "следующая клавиатура", space: "пробел", spaceRussianKeyboard: "пробел",
    return: "ввод")

  static let english = KeyboardAccessibilityStrings(
    delete: "delete", shift: "shift", capsLock: "caps lock", moreSymbols: "more",
    numbers: "numbers", letters: "letters", symbols: "symbols",
    nextKeyboard: "next keyboard", space: "space", spaceRussianKeyboard: "space",
    return: "return")

  /// Russian when the first preferred language is Russian, English otherwise.
  static func forPreferredLanguages(_ languages: [String]) -> KeyboardAccessibilityStrings {
    languages.first?.lowercased().hasPrefix("ru") == true ? .russian : .english
  }

  static var current: KeyboardAccessibilityStrings {
    forPreferredLanguages(Locale.preferredLanguages)
  }
}
