import SwiftUI
import UIKit

/// The container app's look: a page of an old Russian illuminated book, in
/// parchment by day and black Palekh lacquer with gold in the dark appearance,
/// with vyaz titles (Oglavie) and book-hand headers (Monomakh). The keyboards
/// stay system-styled.
enum OldRus {
  static let cinnabar = Color(light: 0x9B3A2C, dark: 0xC0503A)
  static let heading = Color(light: 0x9B3A2C, dark: 0xD9B865)
  static let gold = Color(light: 0xB8902F, dark: 0xD9B865)
  static let ochre = Color(light: 0x9A7A3C, dark: 0xC9A24A)
  static let olive = Color(light: 0x6B6433, dark: 0xA9A15E)
  static let umber = Color(light: 0x32261E, dark: 0xE8DCC8)
  static let page = Color(light: 0xE8DCC8, dark: 0x0E0A08)
  static let vellum = Color(light: 0xF4ECDD, dark: 0x1C1512)

  static func vyaz(_ size: CGFloat) -> Font { .custom("OglavieUnicode", size: size) }
  static func bookHand(_ size: CGFloat) -> Font { .custom("MonomakhUnicode", size: size) }
  static func oldStyle(_ size: CGFloat, bold: Bool = false) -> Font {
    .custom(bold ? "OldStandardTT-Bold" : "OldStandardTT-Regular", size: size)
  }

  /// Navigation titles in vyaz and old-style serif, cinnabar on parchment.
  static func applyAppearance() {
    let heading = UIColor(OldRus.heading)
    let bar = UINavigationBarAppearance()
    bar.configureWithTransparentBackground()
    if let large = UIFont(name: "OglavieUnicode", size: 38) {
      bar.largeTitleTextAttributes = [.font: large, .foregroundColor: heading, .kern: 0.8]
    }
    if let inline = UIFont(name: "MonomakhUnicode", size: 19) {
      bar.titleTextAttributes = [.font: inline, .foregroundColor: heading]
    }
    UINavigationBar.appearance().standardAppearance = bar
    UINavigationBar.appearance().scrollEdgeAppearance = bar
    UINavigationBar.appearance().compactAppearance = bar
  }
}

extension Color {
  init(light: UInt32, dark: UInt32) {
    self.init(uiColor: UIColor { traits in
      let hex = traits.userInterfaceStyle == .dark ? dark : light
      return UIColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1)
    })
  }
}

/// A section header in the book hand after a small gilded lily.
struct OldRusHeader: View {
  let title: String
  init(_ title: String) { self.title = title }
  var body: some View {
    HStack(spacing: 6) {
      Image("Krin").resizable().frame(width: 16, height: 16).accessibilityHidden(true)
      Text(title).font(OldRus.bookHand(17)).foregroundStyle(OldRus.heading)
    }
    .textCase(nil)
  }
}

/// A thin ochre double rule with a rosette in the middle.
struct OldRusDivider: View {
  var body: some View {
    HStack(spacing: 8) {
      rule
      Image("Krin").resizable().frame(width: 18, height: 18)
      rule
    }
    .accessibilityHidden(true)
  }

  private var rule: some View {
    VStack(spacing: 2) {
      Rectangle().fill(OldRus.ochre.opacity(0.75)).frame(height: 1)
      Rectangle().fill(OldRus.ochre.opacity(0.35)).frame(height: 0.5)
    }
  }
}

extension View {
  /// Parchment behind a Form or List, vellum rows edged in ochre.
  func oldRusPage() -> some View {
    scrollContentBackground(.hidden)
      .background(OldRus.page.ignoresSafeArea())
  }

  func oldRusRow() -> some View {
    listRowBackground(OldRus.vellum)
  }
}
