import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// Lock Screen and Dynamic Island presentation of the armed microphone.
struct VelikiyMoguchiyRelayLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: VelikiyMoguchiyRelayAttributes.self) { context in
      RelayLockScreenView(state: context.state)
        .padding(16)
        .activityBackgroundTint(nil)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Image(systemName: context.state.symbolName)
            .font(.title2)
            .foregroundStyle(RelayTint.color(for: context.state.phase))
        }
        DynamicIslandExpandedRegion(.center) {
          Text(context.state.title).font(.headline)
        }
        DynamicIslandExpandedRegion(.trailing) {
          RelayCountdownText(shutdownDate: context.state.shutdownDate)
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        DynamicIslandExpandedRegion(.bottom) {
          RelayButtons(state: context.state)
        }
      } compactLeading: {
        Image(systemName: context.state.symbolName)
          .foregroundStyle(RelayTint.color(for: context.state.phase))
      } compactTrailing: {
        if context.state.shutdownDate != nil {
          RelayCountdownText(shutdownDate: context.state.shutdownDate)
            .font(.caption.monospacedDigit())
            .frame(maxWidth: 44)
        } else {
          EmptyView()
        }
      } minimal: {
        Image(systemName: context.state.symbolName)
          .foregroundStyle(RelayTint.color(for: context.state.phase))
      }
    }
  }
}

enum RelayTint {
  static func color(for phase: VelikiyMoguchiyRelayAttributes.ContentState.Phase) -> Color {
    switch phase {
    case .ready: return .blue
    case .listening: return .red
    case .transcribing: return .blue
    case .paused: return .orange
    case .needsApp: return .orange
    }
  }
}

/// "14:32" counting down to the automatic shutdown; ticks without updates.
struct RelayCountdownText: View {
  let shutdownDate: Date?

  var body: some View {
    if let shutdownDate {
      // A range needs lower <= upper, so an overdue date shows 0:00.
      Text(timerInterval: Date.now...max(shutdownDate, Date.now), countsDown: true)
        .multilineTextAlignment(.trailing)
    }
  }
}

struct RelayLockScreenView: View {
  let state: VelikiyMoguchiyRelayAttributes.ContentState

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        Image(systemName: state.symbolName)
          .font(.title2)
          .foregroundStyle(RelayTint.color(for: state.phase))
          .frame(width: 32)
        VStack(alignment: .leading, spacing: 2) {
          Text(state.title).font(.headline)
          subtitle
        }
        Spacer(minLength: 0)
      }
      RelayButtons(state: state)
    }
  }

  @ViewBuilder
  private var subtitle: some View {
    if state.shutdownDate != nil {
      HStack(spacing: 4) {
        Text("Выключится через")
        RelayCountdownText(shutdownDate: state.shutdownDate)
          .monospacedDigit()
      }
      .font(.subheadline)
      .foregroundStyle(.secondary)
    } else if state.phase == .ready {
      Text("Пока вы не выключите")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    } else if state.phase == .needsApp {
      Text("Нажмите микрофон на клавиатуре, чтобы включить снова")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
  }
}

struct RelayButtons: View {
  let state: VelikiyMoguchiyRelayAttributes.ContentState

  var body: some View {
    HStack(spacing: 10) {
      Button(intent: StopRelayIntent()) {
        Text("Стоп").frame(maxWidth: .infinity)
      }
      .tint(.red)
      if state.canExtend {
        Button(intent: ExtendRelayIntent()) {
          Text("Продлить").frame(maxWidth: .infinity)
        }
        .tint(.blue)
      }
    }
    .buttonStyle(.borderedProminent)
    .controlSize(.small)
  }
}
