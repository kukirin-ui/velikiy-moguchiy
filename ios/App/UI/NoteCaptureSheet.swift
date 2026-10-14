import SwiftUI
import UIKit

struct NoteCaptureSheet: View {
  @ObservedObject var relay: RelayController
  let retentionDays: Int
  let showHistory: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var confirmDiscard = false
  @State private var copied = false

  private var isRecording: Bool { relay.noteCapturePhase == .recording }
  private var canDiscard: Bool { isRecording || relay.noteCapturePhase == .preparing }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 28) {
          switch relay.noteCapturePhase {
          case .saved(let item):
            Label("Сохранено в истории", systemImage: "checkmark.circle.fill")
              .font(.subheadline.weight(.medium)).foregroundStyle(OldRus.cinnabar)
            Text(item.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
              .font(.caption).foregroundStyle(.secondary)
            Text(item.text)
              .font(.title3).lineSpacing(7).textSelection(.enabled)
              .accessibilityIdentifier("saved-note-text")
          case .failed(let message):
            Image(systemName: "waveform.badge.exclamationmark")
              .font(.largeTitle).foregroundStyle(OldRus.ochre)
            Text("С заметкой что-то пошло не так").font(.title2.weight(.semibold))
            Text(message).foregroundStyle(.secondary)
          case .preparing, .recording, .processing:
            recordingHeader
            Text(relay.notePreviewText.isEmpty ? "Мысль, план, то, что нужно запомнить…" : relay.notePreviewText)
              .font(.title3).lineSpacing(7)
              .foregroundStyle(relay.notePreviewText.isEmpty ? .secondary : .primary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .contentTransition(.opacity)
              .accessibilityIdentifier("note-live-preview")
          }
        }
        .frame(maxWidth: 620, alignment: .leading)
        .padding(28)
        .frame(maxWidth: .infinity)
      }
      .background(OldRus.page.ignoresSafeArea())
      .safeAreaInset(edge: .bottom) { bottomControls }
      .navigationTitle(relay.noteCapturePhase.isBusy ? "Новая заметка" : "Голосовая заметка")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          if canDiscard {
            Button("Отмена", systemImage: "xmark") { confirmDiscard = true }
              .accessibilityIdentifier("cancel-note-button")
          } else {
            Button("Готово", systemImage: "checkmark") { relay.dismissNoteCapture() }
              .accessibilityIdentifier("done-note-button")
          }
        }
      }
      .confirmationDialog("Отбросить эту запись?", isPresented: $confirmDiscard, titleVisibility: .visible) {
        Button("Отбросить", role: .destructive) { relay.discardNoteCapture() }
        Button("Продолжить запись", role: .cancel) {}
      }
    }
    .presentationDetents([.large])
    .presentationDragIndicator(.visible)
    .presentationCornerRadius(32)
    .interactiveDismissDisabled(canDiscard)
    .sensoryFeedback(.success, trigger: copied)
    .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: relay.noteCapturePhase)
    .task(id: copied) {
      guard copied else { return }
      do { try await Task.sleep(for: .seconds(2)) } catch { return }
      copied = false
    }
  }

  private var recordingHeader: some View {
    VStack(spacing: 18) {
      HStack(alignment: .center, spacing: 6) {
        ForEach(0..<15, id: \.self) { index in
          let shape = 0.3 + abs(sin(Double(index) * 1.7)) * 0.7
          Capsule()
            .fill(OldRus.cinnabar.opacity(isRecording ? 1 : 0.3))
            .frame(width: 5, height: 10 + (isRecording ? 72 * max(0.04, relay.audioLevel) * shape : 0))
        }
      }
      .frame(height: 96)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: relay.audioLevel)
      .accessibilityHidden(true)
      Text(isRecording ? "Говорите, я слушаю." : relay.noteCapturePhase == .preparing ? "Готовлюсь…" : "Сохраняю ваши слова…")
        .font(.title2.weight(.semibold))
        .multilineTextAlignment(.center)
      if isRecording, let started = relay.activeStartedAt {
        Text(timerInterval: started...max(started, started.addingTimeInterval(RelayController.maximumDictationDuration)), countsDown: false)
          .font(.body.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
          .accessibilityLabel("Длительность записи")
      } else {
        ProgressView().controlSize(.small)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 12)
  }

  private var bottomControls: some View {
    VStack(spacing: 14) {
      switch relay.noteCapturePhase {
      case .recording:
        Button("Закончить и сохранить", systemImage: "stop.fill") { relay.finishNoteCapture() }
          .buttonStyle(.glassProminent)
          .accessibilityIdentifier("finish-note-button")
        Text("До 5 минут · хранится \(retentionDays) дн.")
          .font(.caption).foregroundStyle(.secondary)
      case .saved(let item):
        Button(copied ? "Скопировано" : "Скопировать заметку", systemImage: copied ? "checkmark" : "doc.on.doc") {
          UIPasteboard.general.string = item.text
          copied = true
        }
        .buttonStyle(.glassProminent)
        .accessibilityIdentifier("copy-note-button")
        HStack(spacing: 28) {
          Button("Открыть в истории", action: showHistory)
          ShareLink(item: item.text) { Label("Поделиться", systemImage: "square.and.arrow.up") }
        }
        .font(.subheadline)
      case .failed:
        Button("Открыть историю", systemImage: "clock", action: showHistory)
          .buttonStyle(.glassProminent)
      case .processing:
        Text("Окно можно закрыть. Заметка появится в истории.")
          .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
      case .preparing:
        Text("Готовлю микрофон")
          .font(.subheadline).foregroundStyle(.secondary)
      }
    }
    .controlSize(.large)
    .buttonSizing(.flexible)
    .frame(maxWidth: 540)
    .padding(.horizontal, 28)
    .padding(.vertical, 20)
    .frame(maxWidth: .infinity)
    .background(.bar)
  }
}
