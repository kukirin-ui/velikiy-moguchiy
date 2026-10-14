import SwiftUI
import UIKit

extension ContentView {
  var historyScreen: some View {
    List { Group {
      if let error = relay.historyError {
        Label(error, systemImage: "exclamationmark.circle")
          .foregroundStyle(OldRus.ochre)
      }
      if !relay.recoverableRecordings.isEmpty {
        Section {
          ForEach(relay.recoverableRecordings) { recording in
            recordingRow(recording)
          }
        } header: {
          OldRusHeader("Сохранённые записи")
        } footer: {
          Text("Эти записи остались на iPhone. Повторите распознавание или удалите их.")
        }
      }
      if !relay.history.isEmpty {
        Section {
          ForEach(relay.history) { item in
            NavigationLink {
              transcriptScreen(item)
            } label: {
              VStack(alignment: .leading, spacing: 8) {
                Text(item.text).font(.body).lineLimit(3)
                Text(item.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                  .font(.caption).foregroundStyle(.secondary)
              }
              .padding(.vertical, 8)
            }
            .contextMenu {
              Button("Скопировать", systemImage: "doc.on.doc") { copyTranscript(item) }
              ShareLink(item: item.text)
            }
            .swipeActions {
              Button("Удалить", role: .destructive) { relay.deleteHistoryItem(item) }
            }
          }
        } header: {
          OldRusHeader("Сохранённый текст")
        } footer: {
          Text("Хранится \(configuration.historyRetentionDays) дн. Срок меняется в настройках.")
        }
      }
    }.listRowBackground(OldRus.vellum) }
    .oldRusPage()
    .overlay {
      if relay.history.isEmpty && relay.recoverableRecordings.isEmpty {
        ContentUnavailableView {
          Label("Здесь будут ваши тексты", systemImage: "text.quote")
        } description: {
          Text("Запишите заметку, потом скопируйте или отправьте её. Сюда же попадают диктовки с клавиатуры.")
        } actions: {
          Button("Записать заметку", systemImage: "mic.badge.plus") {
            Task { await relay.startNoteCapture() }
          }
          .buttonStyle(.glassProminent)
          .disabled(!relay.canStartNoteCapture)
        }
      }
    }
    .navigationTitle("История")
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button("Записать заметку", systemImage: "mic.badge.plus") {
          Task { await relay.startNoteCapture() }
        }
        .disabled(!relay.canStartNoteCapture)
        .accessibilityIdentifier("history-record-note-button")
      }
      if !relay.history.isEmpty {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Очистить историю", systemImage: "trash") { isClearHistoryPresented = true }
        }
      }
    }
  }

  func transcriptScreen(_ item: TranscriptHistoryItem) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        Text(item.createdAt, format: .dateTime.month(.wide).day().hour().minute())
          .font(.subheadline).foregroundStyle(.secondary)
        Text(item.text)
          .font(.body).lineSpacing(6).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxWidth: 640)
      .padding(24)
      .frame(maxWidth: .infinity)
    }
    .background(OldRus.page.ignoresSafeArea())
    .navigationTitle("Сохранённый текст")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItemGroup(placement: .topBarTrailing) {
        Button(copiedItemID == item.id ? "Скопировано" : "Скопировать", systemImage: copiedItemID == item.id ? "checkmark" : "doc.on.doc") {
          copyTranscript(item)
        }
        .accessibilityIdentifier("copy-transcript-button")
        ShareLink(item: item.text)
      }
    }
    .sensoryFeedback(.success, trigger: copiedItemID)
    .task(id: copiedItemID) {
      guard copiedItemID != nil else { return }
      do { try await Task.sleep(for: .seconds(2)) } catch { return }
      copiedItemID = nil
    }
  }

  func copyTranscript(_ item: TranscriptHistoryItem) {
    UIPasteboard.general.string = item.text
    copiedItemID = item.id
  }

  func recordingRow(_ recording: RecoverableRecording) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label(recording.actionTitle, systemImage: "waveform")
          .font(.headline)
        Spacer()
        Text(recording.createdAt, style: .relative).font(.caption).foregroundStyle(.secondary)
      }
      Text(recording.lastError).font(.subheadline).foregroundStyle(.secondary)
      HStack {
        Button {
          relay.retryRecording(recording)
        } label: {
          HStack(spacing: 6) {
            if relay.retryingRecordingID == recording.id { ProgressView().controlSize(.small) }
            Label(recording.transcriptSaved == true ? "Текст сохранён" : "Повторить", systemImage: "arrow.clockwise")
          }
        }
        .buttonStyle(.bordered)
        .disabled(recording.transcriptSaved == true || relay.retryingRecordingID != nil || relay.status.isBusy || !configuration.hasUsableAPIKey)
        Spacer()
        Button("Удалить запись", systemImage: "trash", role: .destructive) {
          recordingPendingDeletion = recording
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .frame(minWidth: 44, minHeight: 44)
        .disabled(relay.retryingRecordingID == recording.id)
      }
    }
    .padding(.vertical, 8)
  }
}
