import SwiftUI
import UIKit

extension ContentView {
  var setupScreen: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 28) {
        VStack(alignment: .leading, spacing: 14) {
          Image(systemName: "keyboard")
            .font(.system(size: 42, weight: .light))
            .foregroundStyle(OldRus.cinnabar)
          Text("Ваш голос.\nВ любом поле ввода.")
            .font(.largeTitle.weight(.bold))
          Text("Добавьте две клавиатуры «Великий & Могучий» один раз, и они всегда под рукой: глобус переключает язык, как у системной клавиатуры.")
            .foregroundStyle(.secondary)
        }
        VStack(spacing: 24) {
          instruction(1, "Добавьте клавиатуры", "Настройки → Основные → Клавиатура → Клавиатуры → Новые клавиатуры. Выберите «Великий & Могучий RU» и «Великий & Могучий EN».")
          instruction(2, "Разрешите полный доступ", "Откройте каждую из двух клавиатур в списке и включите «Разрешить полный доступ»: так клавиатура связывается с приложением, которое записывает голос.")
          instruction(3, "Включите приём", "Откройте «Великий & Могучий» и включите приём. В любом поле ввода нажмите на глобус, чтобы переключить RU и EN, а затем на микрофон, чтобы диктовать.")
        }
        .padding(22)
        .background(OldRus.vellum, in: .rect(cornerRadius: 26))
        Button(action: openSystemSettings) {
          Text("Открыть настройки").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 9)
        }
        .buttonStyle(.glassProminent)
        NavigationLink("Попробовать клавиатуру") { KeyboardTryoutView() }
          .frame(maxWidth: .infinity)
        Text("Полный доступ нужен, чтобы клавиатура обменивалась текстом и командами с приложением. Ключ API остаётся в приложении.")
          .font(.footnote).foregroundStyle(.secondary)
      }
      .frame(maxWidth: 580)
      .padding(24)
      .frame(maxWidth: .infinity)
    }
    .background(OldRus.page.ignoresSafeArea())
    .navigationTitle("Настройка клавиатур")
    .navigationBarTitleDisplayMode(.inline)
  }

  func instruction(_ number: Int, _ title: String, _ detail: String) -> some View {
    HStack(alignment: .top, spacing: 14) {
      Text("\(number)")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(OldRus.cinnabar)
        .frame(width: 30, height: 30)
        .background(OldRus.cinnabar.opacity(0.08), in: .circle)
      VStack(alignment: .leading, spacing: 6) {
        Text(title).font(.headline)
        Text(detail).font(.subheadline).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
  }
}

struct KeyboardTryoutView: View {
  @State private var text = ""
  @FocusState private var isFocused: Bool
  @FocusState private var isFieldFocused: Bool
  /// Debug aid: `VELIKIY_MOGUCHIY_TRYOUT=1` focuses the field on launch so keyboards can
  /// be inspected without navigating.
  private var focusesOnAppear: Bool {
    #if DEBUG
      ProcessInfo.processInfo.environment["VELIKIY_MOGUCHIY_TRYOUT"] == "1"
    #else
      false
    #endif
  }

  #if DEBUG
    /// Debug aid: `VELIKIY_MOGUCHIY_TRYOUT_KIND=number|decimal|web|url|email|twitter|numpunct|text` swaps the
    /// editor for a single-line field with that keyboard type, so every layout can be captured.
    private var tryoutKind: String? { ProcessInfo.processInfo.environment["VELIKIY_MOGUCHIY_TRYOUT_KIND"] }
    private var tryoutKeyboardType: UIKeyboardType {
      switch tryoutKind {
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
    /// `VELIKIY_MOGUCHIY_TRYOUT_RETURN=go|search|send|done|next|join|route|continue` sets the return key.
    private var tryoutSubmitLabel: SubmitLabel {
      switch ProcessInfo.processInfo.environment["VELIKIY_MOGUCHIY_TRYOUT_RETURN"] {
      case "go": return .go
      case "search": return .search
      case "send": return .send
      case "done": return .done
      case "next": return .next
      case "join": return .join
      case "route": return .route
      case "continue": return .continue
      default: return .return
      }
    }
    /// `VELIKIY_MOGUCHIY_TRYOUT_AUTOCORRECT=0` turns autocorrection off, as Safari's address bar does.
    private var tryoutAutocorrectionDisabled: Bool {
      ProcessInfo.processInfo.environment["VELIKIY_MOGUCHIY_TRYOUT_AUTOCORRECT"] == "0"
    }
    private func rotateIfRequested() {
      // "1" rotates to landscape, "0" back to portrait (the simulator keeps its orientation).
      guard let value = ProcessInfo.processInfo.environment["VELIKIY_MOGUCHIY_TRYOUT_LANDSCAPE"],
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
      else { return }
      scene.requestGeometryUpdate(
        .iOS(interfaceOrientations: value == "1" ? .landscapeRight : .portrait))
    }
  #endif

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text("Нажмите на глобус, чтобы выбрать Великий & Могучий RU или Великий & Могучий EN, и попробуйте микрофон.")
        .font(.subheadline).foregroundStyle(.secondary)
      #if DEBUG
        if tryoutKind != nil {
          TextField("Поле", text: $text)
            .keyboardType(tryoutKeyboardType)
            .submitLabel(tryoutSubmitLabel)
            .autocorrectionDisabled(tryoutAutocorrectionDisabled)
            .focused($isFieldFocused)
            .padding(12)
            .background(OldRus.vellum, in: .rect(cornerRadius: 12))
            .accessibilityIdentifier("keyboard-practice-field")
        }
      #endif
      TextEditor(text: $text)
        .focused($isFocused)
        .padding(12)
        .scrollContentBackground(.hidden)
        .background(OldRus.vellum, in: .rect(cornerRadius: 22))
        .overlay(alignment: .topLeading) {
          if text.isEmpty {
            Text("Нажмите здесь, чтобы попробовать клавиатуру")
              .foregroundStyle(.tertiary)
              .padding(.horizontal, 17).padding(.vertical, 20)
              .allowsHitTesting(false)
          }
        }
        .accessibilityLabel("Поле для проверки клавиатуры")
        .accessibilityIdentifier("keyboard-practice-text")
    }
    .padding(20)
    .background(OldRus.page.ignoresSafeArea())
    .onAppear {
      #if DEBUG
        rotateIfRequested()
        if focusesOnAppear, tryoutKind != nil {
          isFieldFocused = true
          return
        }
      #endif
      if focusesOnAppear { isFocused = true }
    }
    .navigationTitle("Проверка клавиатуры")
    .navigationBarTitleDisplayMode(.inline)
  }
}
