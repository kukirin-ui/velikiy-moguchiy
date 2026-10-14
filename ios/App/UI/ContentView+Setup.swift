import SwiftUI
import UIKit

extension ContentView {
  var setupScreen: some View {
    KeyboardSetupScreen(checklist: checklist, store: relay.store)
  }
}

/// Adding the keyboards and Full Access, with each step ticked off live.
struct KeyboardSetupScreen: View {
  @ObservedObject var checklist: SetupChecklist
  let store: SharedRelayStore

  var body: some View {
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
        Button(action: openAppSettings) {
          Label("Открыть настройки iOS", systemImage: "gear")
            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 9)
        }
        .buttonStyle(.glassProminent)
        .accessibilityIdentifier("open-keyboard-settings-button")
        VStack(spacing: 24) {
          SetupStepRow(
            number: 1,
            title: "Добавьте клавиатуры",
            detail: keyboardsDetail,
            isDone: progress.keyboardAdded
          )
          SetupStepRow(
            number: 2,
            title: "Разрешите полный доступ",
            detail: fullAccessDetail,
            isDone: progress.fullAccess
          )
          SetupStepRow(
            number: 3,
            title: "Попробуйте",
            detail: "Откройте поле ниже, нажмите на глобус и выберите «Великий & Могучий RU». Галочки выше отметятся сами, как только клавиатура появится.",
            isDone: false
          )
        }
        .padding(22)
        .background(OldRus.vellum, in: .rect(cornerRadius: 26))
        NavigationLink {
          KeyboardTryoutView()
        } label: {
          Label("Попробовать клавиатуру", systemImage: "text.cursor")
            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 9)
        }
        .buttonStyle(.glass)
        .accessibilityIdentifier("keyboard-tryout-link")
        Text("Зачем полный доступ: через него клавиатура передаёт приложению команды «начать» и «остановить» и получает готовый текст. Голос записывает и отправляет в DashScope только приложение; в коде клавиатуры нет сетевых запросов, набранный текст никуда не уходит.")
          .font(.footnote).foregroundStyle(.secondary)
      }
      .frame(maxWidth: 580)
      .padding(24)
      .frame(maxWidth: .infinity)
    }
    .background(OldRus.page.ignoresSafeArea())
    .navigationTitle("Настройка клавиатур")
    .navigationBarTitleDisplayMode(.inline)
    .task { await refreshWhileVisible() }
  }

  private var progress: SetupProgress {
    SetupProgress(
      hasKey: true, keyVerified: true, microphone: .granted,
      addedKeyboards: checklist.addedKeyboards, totalKeyboards: checklist.totalKeyboards,
      keyboardReported: checklist.keyboardReported)
  }

  private var keyboardsDetail: String {
    let path = "Нажмите «Открыть настройки iOS» → «Клавиатуры» и включите «Великий & Могучий RU» и «Великий & Могучий EN». Или: Основные → Клавиатура → Клавиатуры → Новые клавиатуры."
    guard let added = checklist.addedKeyboards, added > 0 else { return path }
    if added >= checklist.totalKeyboards { return "Обе клавиатуры добавлены." }
    return "Добавлена \(added) из \(checklist.totalKeyboards). \(path)"
  }

  private var fullAccessDetail: String {
    progress.fullAccess
      ? "Клавиатура вышла на связь с приложением: полный доступ включён."
      : "Там же, в «Клавиатурах», включите «Полный доступ». Отметка появится, когда клавиатура впервые откроется с доступом."
  }

  private func openAppSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url)
  }

  private func refreshWhileVisible() async {
    while !Task.isCancelled {
      checklist.refresh(store: store)
      try? await Task.sleep(for: .seconds(1))
    }
  }
}

struct SetupStepRow: View {
  let number: Int
  let title: String
  let detail: String
  let isDone: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      ZStack {
        if isDone {
          Image(systemName: "checkmark")
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(OldRus.cinnabar, in: .circle)
        } else {
          Text("\(number)")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(OldRus.cinnabar)
            .frame(width: 30, height: 30)
            .background(OldRus.cinnabar.opacity(0.08), in: .circle)
        }
      }
      .contentTransition(.symbolEffect(.replace))
      VStack(alignment: .leading, spacing: 6) {
        Text(title).font(.headline)
        Text(detail).font(.subheadline).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
    .accessibilityValue(isDone ? "Готово" : "Не сделано")
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
