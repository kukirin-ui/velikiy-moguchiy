import Foundation
import UIKit

/// Reads the battery and Low Power Mode state and reports changes. Cheap: it
/// only listens to system notifications, it never polls.
@MainActor
final class RelayPowerMonitor {
  var onChange: (() -> Void)?
  private var observers: [NSObjectProtocol] = []

  init() {
    UIDevice.current.isBatteryMonitoringEnabled = true
    let center = NotificationCenter.default
    let names: [Notification.Name] = [
      UIDevice.batteryLevelDidChangeNotification,
      UIDevice.batteryStateDidChangeNotification,
      .NSProcessInfoPowerStateDidChange,
    ]
    observers = names.map { name in
      center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.onChange?() }
      }
    }
  }

  deinit {
    observers.forEach(NotificationCenter.default.removeObserver)
  }

  var state: RelayPowerState {
    let device = UIDevice.current
    return RelayPowerState(
      batteryLevel: device.batteryLevel,
      isCharging: device.batteryState == .charging || device.batteryState == .full,
      isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled
    )
  }
}
