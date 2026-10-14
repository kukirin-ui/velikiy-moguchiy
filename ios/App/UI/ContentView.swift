import SwiftUI
import UIKit

struct ContentView: View {
  enum Screen: Hashable { case relay, history, settings }

  @ObservedObject var configuration: AppConfiguration
  @ObservedObject var relay: RelayController
  @Environment(\.accessibilityReduceMotion) var reduceMotion
  @Environment(\.dynamicTypeSize) var dynamicTypeSize

  @State var selectedScreen: Screen = .relay
  @State var recordingPendingDeletion: RecoverableRecording?
  @State var isClearHistoryPresented = false
  @State var copiedItemID: UUID?

  var body: some View {
    TabView(selection: $selectedScreen) {
      Tab("Диктовка", systemImage: "waveform", value: Screen.relay) {
        NavigationStack { relayScreen }
      }
      Tab("История", systemImage: "clock", value: Screen.history) {
        NavigationStack { historyScreen }
      }
      .badge(relay.recoverableRecordings.count)
      Tab("Настройки", systemImage: "gearshape", value: Screen.settings) {
        NavigationStack { settingsScreen }
      }
    }
    .tint(OldRus.cinnabar)
    .onChange(of: configuration.apiKeyOverride) { _, _ in
      relay.credentialAvailabilityDidChange()
    }
    .onChange(of: configuration.historyRetentionDays) { _, _ in
      relay.applyHistoryRetention()
    }
    .accessibilityHidden(relay.isKeyboardHandoffActive)
    .overlay {
      if relay.isKeyboardHandoffActive {
        keyboardHandoffOverlay
      }
    }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: relay.isKeyboardHandoffActive)
    .onOpenURL(perform: relay.handleDeepLink)
    #if DEBUG && targetEnvironment(simulator)
      .onAppear {
        switch ProcessInfo.processInfo.environment["VELIKIY_MOGUCHIY_VISUAL_TEST_TAB"] {
        case "history": selectedScreen = .history
        case "settings": selectedScreen = .settings
        default: break
        }
      }
    #endif
    .sheet(isPresented: $relay.isNoteCapturePresented) {
      NoteCaptureSheet(relay: relay, retentionDays: configuration.historyRetentionDays) {
        selectedScreen = .history
        relay.dismissNoteCapture()
      }
    }
    .confirmationDialog(
      "Удалить сохранённую запись?",
      isPresented: Binding(
        get: { recordingPendingDeletion != nil },
        set: { presented in
          if !presented { recordingPendingDeletion = nil }
        }
      ),
      titleVisibility: .visible
    ) {
      Button("Удалить запись", role: .destructive) {
        if let recordingPendingDeletion {
          relay.deleteRecording(recordingPendingDeletion)
        }
        recordingPendingDeletion = nil
      }
      Button("Оставить", role: .cancel) {
        recordingPendingDeletion = nil
      }
    } message: {
      Text("Аудиозапись будет удалена с iPhone безвозвратно.")
    }
    .confirmationDialog("Очистить историю?", isPresented: $isClearHistoryPresented, titleVisibility: .visible) {
      Button("Очистить историю", role: .destructive) { relay.clearHistory() }
    } message: {
      Text("Готовый текст будет удалён с iPhone. Сохранённые аудиозаписи останутся.")
    }
  }
}

#Preview {
  let configuration = AppConfiguration()
  ContentView(
    configuration: configuration,
    relay: RelayController(configuration: configuration)
  )
}
