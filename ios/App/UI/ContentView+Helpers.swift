import SwiftUI
import UIKit

extension ContentView {
  var languagePicker: some View {
    Picker("Язык заметок", selection: $configuration.noteLanguageCode) {
      ForEach(DictationLanguage.allCases, id: \.rawValue) { language in
        Text(language.displayName).tag(language.code)
      }
    }
    .pickerStyle(.menu)
    .accessibilityIdentifier("note-language-picker")
  }

  func openSystemSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url)
  }

  var statusTitle: String {
    if !configuration.hasUsableAPIKey { return "Нужна настройка" }
    if relay.isRelayStarting { return "Подключение" }
    switch relay.status {
    case .offline: return "Приём на паузе"
    case .idle: return relay.isRelayRunning ? "Приём включён" : "Приём на паузе"
    case .recording: return "Слушаю"
    case .transcribing: return "Заканчиваю"
    case .error: return "Нужно внимание"
    }
  }

  var statusSymbol: String {
    if !configuration.hasUsableAPIKey { return "key" }
    if relay.isRelayStarting { return "circle.dotted" }
    switch relay.status {
    case .idle where relay.isRelayRunning: return "checkmark.circle.fill"
    case .recording: return "mic.fill"
    case .transcribing: return "ellipsis.circle"
    case .error: return "exclamationmark.circle"
    default: return "pause.circle"
    }
  }

  var statusColor: Color {
    if !configuration.hasUsableAPIKey { return .secondary }
    switch relay.status {
    case .idle where relay.isRelayRunning: return OldRus.cinnabar
    case .recording, .transcribing: return OldRus.cinnabar
    case .error: return .orange
    default: return .secondary
    }
  }
}
