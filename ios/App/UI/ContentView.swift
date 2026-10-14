import SwiftUI
import UIKit

struct ContentView: View {
  enum Screen: Hashable { case relay, history, settings }

  @ObservedObject var configuration: AppConfiguration
  @ObservedObject var relay: RelayController
  @Environment(\.accessibilityReduceMotion) var reduceMotion
  @Environment(\.dynamicTypeSize) var dynamicTypeSize
  @Environment(\.scenePhase) var scenePhase

  @State var selectedScreen: Screen = .relay
  @State var recordingPendingDeletion: RecoverableRecording?
  @State var isClearHistoryPresented = false
  @State var copiedItemID: UUID?
  @StateObject var checklist = SetupChecklist()
  @State var isGettingStartedPresented = false
  /// Set once the user has closed «Начало работы» or finished it; after that
  /// it no longer opens by itself, and the Dictation tab shows a card instead.
  @AppStorage("onboarding.finished") var onboardingFinished = false

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
    .task { presentGettingStartedIfNeeded() }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { checklist.refresh(store: relay.store) }
    }
    .sheet(isPresented: $isGettingStartedPresented) {
      NavigationStack {
        GettingStartedScreen(
          configuration: configuration, checklist: checklist, store: relay.store
        ) {
          onboardingFinished = true
          isGettingStartedPresented = false
        }
      }
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

extension ContentView {
  var setupProgress: SetupProgress { checklist.progress(configuration) }

  func presentGettingStartedIfNeeded() {
    checklist.refresh(store: relay.store)
    if setupProgress.isComplete {
      onboardingFinished = true
      return
    }
    let environment = ProcessInfo.processInfo.environment
    let isAutomatedRun =
      environment["XCTestConfigurationFilePath"] != nil
      || environment["VELIKIY_MOGUCHIY_VISUAL_TEST_SCENARIO"] != nil
      || environment["VELIKIY_MOGUCHIY_VISUAL_TEST_TAB"] != nil
    guard !onboardingFinished, !relay.isKeyboardHandoffActive, !isAutomatedRun else { return }
    isGettingStartedPresented = true
  }
}

#Preview {
  let configuration = AppConfiguration()
  ContentView(
    configuration: configuration,
    relay: RelayController(configuration: configuration)
  )
}
