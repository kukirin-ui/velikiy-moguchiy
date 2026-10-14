import AVFoundation
import Combine
import Foundation
import UIKit

extension RelayController {
  func handleDeepLink(_ url: URL) {
    if url.scheme?.lowercased() == "velikiy-moguchiy", url.host?.lowercased() == "open" {
      // The keyboard's brand mark just brings the app forward. There is no
      // request to claim, and the scene-phase handler starts the relay.
      return
    }
    if let request = RelayLaunchRequest.parse(url) {
      guard store.pendingLaunchRequest() == request else {
        if !isRelayRunning {
          setLocalStatus(
            .error,
            message: "Переход с клавиатуры не авторизован. Повторите с клавиатуры.")
        }
        return
      }
      pendingLaunchRequest = request
      isKeyboardHandoffActive = true
      requiresManualKeyboardReturn = manualReturnRequired(for: request)
      let applicationState = UIApplication.shared.applicationState
      #if VELIKIY_MOGUCHIY_PERSONAL_DEVICE
        if applicationState == .active {
          Task { await applicationDidBecomeActive() }
        } else if applicationState == .inactive,
          AVAudioApplication.shared.recordPermission == .granted
        {
          // A keyboard URL arrives while the scene's opening animation is
          // foreground-inactive. Starting here lets capture and the return
          // request finish before the app needs to draw its regular UI.
          Task { await startRelay() }
        }
      #else
        if applicationState == .active {
          Task { await applicationDidBecomeActive() }
        }
      #endif
      return
    }

    guard url.scheme?.lowercased() == "velikiy-moguchiy" else { return }
    if !isRelayRunning {
      setLocalStatus(.error, message: "Запрос с клавиатуры устарел. Повторите попытку.")
    }
  }

  func requestMicrophonePermission() async -> Bool {
    await withCheckedContinuation { continuation in
      AVAudioApplication.requestRecordPermission { granted in
        continuation.resume(returning: granted)
      }
    }
  }
}
