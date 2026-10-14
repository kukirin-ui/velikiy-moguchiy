import SwiftUI

extension ContentView {
  var relayScreen: some View {
    ScrollView {
      VStack(spacing: 24) {
        relayHero
        if !setupProgress.isComplete {
          gettingStartedCard
        }
        if configuration.hasUsableAPIKey, relay.status == .error {
          Label(relay.statusMessage, systemImage: "exclamationmark.circle")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(OldRus.vellum, in: .rect(cornerRadius: 22))
            .accessibilityIdentifier("relay-error-message")
        }
        VStack(spacing: 12) {
          recordNoteCard
        }
        if !relay.recoverableRecordings.isEmpty {
          Button { selectedScreen = .history } label: {
            HStack(spacing: 12) {
              Image(systemName: "waveform.badge.exclamationmark")
              Text("Сохранённых записей для повтора: \(relay.recoverableRecordings.count)")
              Spacer()
              Image(systemName: "chevron.right").font(.caption.weight(.semibold))
            }
            .font(.subheadline)
            .padding(18)
          }
          .buttonStyle(.plain)
          .background(OldRus.vellum, in: .rect(cornerRadius: 22))
        }
      }
      .frame(maxWidth: 580)
      .padding(.horizontal, 20)
      .padding(.bottom, 28)
      .frame(maxWidth: .infinity)
    }
    .background(OldRus.page.ignoresSafeArea())
    .navigationTitle("Великий & Могучий")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        NavigationLink { setupScreen } label: { Image(systemName: "keyboard") }
          .accessibilityLabel("Настройка клавиатур")
      }
    }
  }

  var recordNoteCard: some View {
    Button {
      Task { await relay.startNoteCapture() }
    } label: {
      HStack(spacing: 14) {
        Image(systemName: "mic.badge.plus")
          .font(.title2)
          .frame(width: 48, height: 48)
          .glassEffect(.regular.tint(OldRus.cinnabar.opacity(0.1)), in: .circle)
        VStack(alignment: .leading, spacing: 4) {
          Text("Записать заметку").font(.headline)
          Text("Скажите. Сохраните. Скопируйте.")
            .font(.subheadline).foregroundStyle(Color.secondary)
        }
        Spacer(minLength: 4)
        Image(systemName: "arrow.up.right").font(.subheadline.weight(.semibold))
      }
      .padding(18)
      .background(OldRus.cinnabar.opacity(0.06), in: .rect(cornerRadius: 22))
      .contentShape(.rect(cornerRadius: 22))
    }
    .buttonStyle(.plain)
    .foregroundStyle(OldRus.cinnabar)
    .disabled(!relay.canStartNoteCapture)
    .accessibilityIdentifier("record-note-button")
    .accessibilityHint("Запускает запись голосовой заметки в приложении.")
  }

  var relayHero: some View {
    VStack(spacing: 16) {
      statusPill.padding(.top, 8)
      RelayPowerControl(
        isRunning: relay.isRelayRunning,
        isStarting: relay.isRelayStarting,
        isRecording: relay.status == .recording,
        isTranscribing: relay.status == .transcribing,
        isEnabled: configuration.hasUsableAPIKey,
        audioLevel: relay.audioLevel,
        title: relayActionTitle,
        action: toggleRelay
      )
      VStack(spacing: 8) {
        Text(relayHeadline)
          .font(.title2.weight(.semibold))
          .contentTransition(.opacity)
        Text(relayExplanation)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .frame(maxWidth: 320)
          .fixedSize(horizontal: false, vertical: true)
      }
      .multilineTextAlignment(.center)
      if relay.status == .recording {
        HStack(spacing: 16) {
          Button("Отмена", role: .cancel) { relay.cancelDictation() }
            .buttonStyle(.glass)
          Button("Готово", systemImage: "checkmark") {
            if let requestID = relay.activeRequestID {
              relay.finishDictationAndTranscribe(requestID: requestID)
            }
          }
          .buttonStyle(.glassProminent)
        }
        .controlSize(.large)
      }
      Group {
        if let deadline = relay.idleShutdownDeadline, deadline > Date() {
          HStack(spacing: 4) {
            Image(systemName: "timer")
            Text("Выключится через")
            Text(timerInterval: Date()...deadline, countsDown: true)
              .monospacedDigit().fixedSize()
            Button("Продлить") { relay.extendSession() }
              .buttonStyle(.borderless)
              .accessibilityIdentifier("extend-session-button")
          }
        } else {
          Label(
            relay.isRelayRunning ? "Микрофон готов для клавиатуры" : "Включится при открытии приложения",
            systemImage: relay.isRelayRunning ? "mic" : "arrow.up.forward.app"
          )
        }
      }
      .font(.caption).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.bottom, 4)
    .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: relay.status)
  }

  var gettingStartedCard: some View {
    let progress = setupProgress
    return Button { isGettingStartedPresented = true } label: {
      HStack(spacing: 14) {
        Image(systemName: progress.hasKey ? "checklist" : "key.fill")
          .font(.title3)
          .foregroundStyle(OldRus.cinnabar)
          .frame(width: 30)
        VStack(alignment: .leading, spacing: 4) {
          Text("Начало работы").font(.headline)
          Text("Готово \(progress.completedSteps) из \(SetupProgress.stepCount): \(nextStepHint(progress))")
            .font(.subheadline).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 4)
        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
      }
      .padding(18)
      .background(OldRus.vellum, in: .rect(cornerRadius: 22))
      .contentShape(.rect(cornerRadius: 22))
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("getting-started-card")
  }

  func nextStepHint(_ progress: SetupProgress) -> String {
    if !progress.hasKey { return "добавьте ключ DashScope." }
    if !progress.microphoneGranted { return "разрешите микрофон." }
    if !progress.keyboardAdded { return "добавьте клавиатуру в настройках iOS." }
    return "включите клавиатуре полный доступ."
  }

  var statusPill: some View {
    Label(statusTitle, systemImage: statusSymbol)
      .font(.subheadline.weight(.medium))
      .foregroundStyle(statusColor)
      .contentTransition(.symbolEffect(.replace))
  }

  var relayHeadline: String {
    if !configuration.hasUsableAPIKey { return "Подключите DashScope" }
    if relay.isRelayStarting { return "Готовлюсь…" }
    switch relay.status {
    case .recording: return "Слушаю"
    case .transcribing: return "Превращаю речь в текст"
    case .error: return "Нужно внимание"
    case .idle where relay.isRelayRunning: return "Клавиатура готова"
    default: return "Готов к работе"
    }
  }

  var relayExplanation: String {
    if !configuration.hasUsableAPIKey { return "Подключите DashScope, и диктуйте голосом в любом поле ввода." }
    if relay.isRelayStarting { return "Готовлю микрофон для клавиатуры." }
    switch relay.status {
    case .recording: return "Нажмите «Готово», когда закончите. Текст появится в поле ввода."
    case .transcribing: return "Готовый текст появится в поле ввода и в истории."
    case .idle where relay.isRelayRunning: return "Переключитесь на клавиатуру «Великий & Могучий» и нажмите микрофон."
    default: return "Включите приём, чтобы диктовать везде, где печатаете."
    }
  }

  var relayActionTitle: String {
    if relay.isRelayStarting { return "Запуск…" }
    if relay.status == .recording { return "Слушаю" }
    if relay.status == .transcribing { return "Заканчиваю…" }
    return relay.isRelayRunning ? "Выключить" : "Включить"
  }

  func toggleRelay() {
    if relay.isRelayRunning {
      relay.stopRelay()
    } else {
      Task { await relay.startRelay() }
    }
  }
}

/// Arming the keyboard is distinct from recording; only recording shows a waveform.
struct RelayPowerControl: View {
  let isRunning: Bool
  let isStarting: Bool
  let isRecording: Bool
  let isTranscribing: Bool
  let isEnabled: Bool
  let audioLevel: Double
  let title: String
  let action: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @ScaledMetric(relativeTo: .headline) private var controlDiameter = 172.0

  var body: some View {
    let diameter = min(controlDiameter, 270)
    ZStack {
      Circle()
        .stroke(OldRus.cinnabar.opacity(isRunning ? 0.12 : 0.06), lineWidth: 1)
        .frame(width: diameter + 48, height: diameter + 48)
      Circle()
        .fill(OldRus.cinnabar.opacity(isRunning ? 0.07 : 0.035))
        .frame(width: diameter + 24, height: diameter + 24)
        .scaleEffect(isRecording && !reduceMotion ? 1 + min(max(audioLevel, 0), 1) * 0.08 : 1)
      Button(action: action) {
        VStack(spacing: 14) {
          if isStarting || isTranscribing {
            ProgressView().controlSize(.large).tint(OldRus.cinnabar).frame(height: 46)
          } else {
            Image(systemName: isRecording ? "waveform" : "power")
              .font(.system(size: 44, weight: .medium))
              .symbolEffect(.variableColor.iterative, options: .repeating, isActive: isRecording && !reduceMotion)
              .contentTransition(.symbolEffect(.replace))
              .frame(height: 46)
          }
          Text(title).font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(isEnabled ? OldRus.cinnabar : Color.secondary)
        .frame(width: diameter, height: diameter)
        .background {
          if reduceTransparency {
            Circle().fill(OldRus.vellum)
          }
        }
        .glassEffect(.regular.tint(OldRus.cinnabar.opacity(isRunning ? 0.14 : 0.025)).interactive(), in: .circle)
        .overlay {
          // a gilded ring with a cinnabar hairline, like a book clasp
          Circle().strokeBorder(OldRus.gold, lineWidth: 2.5)
          Circle().strokeBorder(OldRus.cinnabar.opacity(0.7), lineWidth: 0.8).padding(5)
        }
        .contentShape(Circle())
      }
      .buttonStyle(RelayPressStyle())
      .disabled(!isEnabled || isStarting || isRecording || isTranscribing)
      .accessibilityIdentifier("relay-control-button")
      .accessibilityLabel(title)
      .accessibilityValue(isRunning ? "Приём включён" : "Приём выключен")
      .accessibilityHint(isRecording ? "Идёт диктовка. Используйте «Готово» или «Отмена» ниже." : isRunning ? "Выключает приём. Включить снова можно микрофоном на клавиатуре." : "Готовит микрофон. Диктовку запускайте с клавиатуры.")
    }
    .frame(height: diameter + 52)
    .sensoryFeedback(.impact(weight: .light), trigger: isRunning)
    .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8), value: isRunning)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: audioLevel)
  }
}

private struct RelayPressStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
      .opacity(configuration.isPressed ? 0.85 : 1)
      .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.7), value: configuration.isPressed)
  }
}
