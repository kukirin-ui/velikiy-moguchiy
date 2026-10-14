import SwiftUI

@main
struct VelikiyMoguchiyApp: App {
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var configuration: AppConfiguration
  @StateObject private var relay: RelayController

  init() {
    #if DEBUG
      if ProcessInfo.processInfo.environment["VELIKIY_MOGUCHIY_NONFATAL_DIAGNOSTIC"] == "1" {
        NSLog("IOS_VALIDATION_FAILURE deliberate nonfatal launch diagnostic")
      }
    #endif
    OldRus.applyAppearance()
    let configuration = AppConfiguration()
    let relay = RelayController(configuration: configuration)
    #if DEBUG && targetEnvironment(simulator)
      relay.applyVisualTestScenario()
    #endif
    _configuration = StateObject(wrappedValue: configuration)
    _relay = StateObject(wrappedValue: relay)
  }

  var body: some Scene {
    WindowGroup {
      #if DEBUG
        if ProcessInfo.processInfo.environment["VELIKIY_MOGUCHIY_TRYOUT"] == "1" {
          NavigationStack { KeyboardTryoutView() }
        } else {
          mainContent
        }
      #else
        mainContent
      #endif
    }
  }

  @ViewBuilder
  private var mainContent: some View {
      ContentView(configuration: configuration, relay: relay)
        .task {
          guard scenePhase == .active else { return }
          await handleActiveSceneIfEnabled()
        }
        .onChange(of: scenePhase) { _, newPhase in
          switch newPhase {
          case .active:
            Task { await handleActiveSceneIfEnabled() }
          case .background:
            relay.applicationDidEnterBackground()
          case .inactive:
            break
          @unknown default:
            break
          }
        }
  }

  @MainActor
  private func handleActiveSceneIfEnabled() async {
    let environment = ProcessInfo.processInfo.environment
    guard environment["VELIKIY_MOGUCHIY_DISABLE_RELAY_AUTOSTART"] != "1" else { return }
    #if DEBUG
      guard environment["XCTestConfigurationFilePath"] == nil else { return }
      guard environment["VELIKIY_MOGUCHIY_VISUAL_TEST_SCENARIO"] == nil else { return }
    #endif
    await relay.applicationDidBecomeActive()
  }
}
