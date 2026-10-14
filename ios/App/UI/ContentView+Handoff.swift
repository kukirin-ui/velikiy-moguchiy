import SwiftUI
import UIKit

extension ContentView {
  var keyboardHandoffOverlay: some View {
    ZStack {
      Color(uiColor: .systemGroupedBackground).ignoresSafeArea()

      VStack(spacing: 28) {
        Spacer()

        Image(systemName: "waveform")
          .font(.system(size: 42, weight: .medium))
          .foregroundStyle(OldRus.cinnabar)
          .frame(width: 92, height: 92)
          .glassEffect(.regular, in: .circle)

        if relay.status == .recording { handoffWaveform }

        VStack(spacing: 10) {
          Text(handoffTitle)
            .font(.largeTitle.weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
          Text(handoffMessage)
            .font(.body)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 26)
        }

        if relay.status == .idle && !relay.requiresManualKeyboardReturn {
          Text("Запись начнётся, только когда клавиатура подключится к вашему полю ввода.")
            .font(.caption)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 32)
        }

        Button {
          relay.cancelKeyboardHandoff()
        } label: {
          Label(
            relay.status == .recording ? "Отменить запись" : "Отменить переход",
            systemImage: "xmark"
          )
          .fontWeight(.semibold)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 15)
          .background(OldRus.vellum)
          .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 28)

        Spacer()
      }
    }
    .transition(.opacity)
    .accessibilityIdentifier("keyboard-handoff-overlay")
  }

  var handoffTitle: String {
    switch relay.status {
    case .idle:
      #if VELIKIY_MOGUCHIY_PERSONAL_DEVICE
        return relay.requiresManualKeyboardReturn
          ? "Не удалось вернуться автоматически"
          : "Возвращаюсь к клавиатуре"
      #else
        return "Готов к записи"
      #endif
    case .recording:
      return "Слушаю"
    case .transcribing:
      return "Заканчиваю"
    case .error:
      return "Нужно внимание"
    case .offline:
      return "Готовлю микрофон…"
    }
  }

  var handoffMessage: String {
    switch relay.status {
    case .idle:
      #if VELIKIY_MOGUCHIY_PERSONAL_DEVICE
        if relay.requiresManualKeyboardReturn {
          return "Смахните назад в приложение, где вы печатали. Запись ещё не началась."
        }
        return
          "«Великий & Могучий» готов. Запись начнётся, как только поле ввода и клавиатура снова станут активны."
      #else
        return
          "«Великий & Могучий» готов. Вернитесь в исходное поле ввода: запись начнётся, когда появится клавиатура."
      #endif
    case .recording:
      return "«Великий & Могучий» продолжит слушать, пока вы пользуетесь клавиатурой."
    case .transcribing, .error, .offline:
      return relay.statusMessage
    }
  }

  var handoffWaveform: some View {
    HStack(alignment: .center, spacing: 7) {
      ForEach(0..<9, id: \.self) { index in
        let shape = [0.42, 0.68, 0.9, 0.62, 1.0, 0.72, 0.86, 0.58, 0.38][index]
        Capsule()
          .fill(relay.status == .recording ? OldRus.cinnabar : Color.secondary.opacity(0.35))
          .frame(
            width: 7,
            height: 14 + (58 * max(0.08, relay.audioLevel) * shape)
          )
      }
    }
    .frame(height: 78)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: relay.audioLevel)
  }
}
