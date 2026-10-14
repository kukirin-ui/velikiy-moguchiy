import AppIntents

struct OpenVelikiyMoguchiyIntent: AppIntent {
  static let title: LocalizedStringResource = "Запустить «Великий & Могучий»"
  static let description = IntentDescription(
    "Открывает «Великий & Могучий» и включает приём голоса для клавиатуры."
  )
  static let openAppWhenRun = true

  @MainActor
  func perform() async throws -> some IntentResult {
    .result()
  }
}

struct VelikiyMoguchiyShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: OpenVelikiyMoguchiyIntent(),
      phrases: [
        "Start \(.applicationName)",
        "Open \(.applicationName)",
        "Show \(.applicationName)",
      ],
      shortTitle: "Запустить «Великий & Могучий»",
      systemImageName: "waveform.badge.mic"
    )
  }
}
