import ActivityKit
import Foundation
import UIKit

/// Starts, updates and ends the Live Activity of an armed microphone. Every call
/// degrades to a no-op: with Live Activities switched off, without the widget
/// extension (a signing tool may drop it), or when iOS refuses the request, the
/// relay works exactly as before.
@MainActor
final class RelayLiveActivityController {
  private var activity: Activity<VelikiyMoguchiyRelayAttributes>?
  private var lastState: VelikiyMoguchiyRelayAttributes.ContentState?
  private var requestFailed = false

  var isAvailable: Bool {
    !requestFailed && ActivityAuthorizationInfo().areActivitiesEnabled
  }

  /// Requests the activity (foreground only: iOS refuses it from the
  /// background) or adopts one that survived a failed audio recovery.
  func begin(state: VelikiyMoguchiyRelayAttributes.ContentState) {
    if activity == nil, let existing = Activity<VelikiyMoguchiyRelayAttributes>.activities.first {
      activity = existing
    }
    if activity != nil {
      update(state: state, force: true)
      return
    }
    guard isAvailable, UIApplication.shared.applicationState == .active else { return }
    do {
      activity = try Activity.request(
        attributes: VelikiyMoguchiyRelayAttributes(),
        content: ActivityContent(state: state, staleDate: state.shutdownDate),
        pushType: nil
      )
      lastState = state
    } catch {
      // Typical causes: Live Activities off, no widget extension in this build.
      requestFailed = true
      NSLog("LIVE_ACTIVITY_REQUEST_FAILED error=%@", error.localizedDescription)
    }
  }

  func update(state: VelikiyMoguchiyRelayAttributes.ContentState, force: Bool = false) {
    guard let activity, force || state != lastState else { return }
    lastState = state
    let content = ActivityContent(state: state, staleDate: state.shutdownDate)
    Task { await activity.update(content) }
  }

  func end(finalMessage: String? = nil) {
    let activities = Activity<VelikiyMoguchiyRelayAttributes>.activities
    activity = nil
    lastState = nil
    guard !activities.isEmpty else { return }
    Task {
      for activity in activities {
        await activity.end(nil, dismissalPolicy: .immediate)
      }
    }
  }
}
