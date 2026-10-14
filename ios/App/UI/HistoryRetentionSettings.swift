import SwiftUI

struct HistoryRetentionSettings: View {
  @ObservedObject var configuration: AppConfiguration
  @Environment(\.dismiss) private var dismiss
  @State private var days = ""

  private var validDays: Int? {
    guard let value = Int(days), (1...36_500).contains(value) else { return nil }
    return value
  }

  var body: some View {
    Form { Group {
      Section {
        HStack {
          Text("Хранить")
          Spacer()
          TextField("30", text: $days)
            .keyboardType(.numberPad)
            .multilineTextAlignment(.trailing)
            .frame(minWidth: 60, maxWidth: 100)
            .accessibilityLabel("Дней хранения истории")
            .accessibilityIdentifier("history-retention-days")
          Text("дн.").foregroundStyle(.secondary)
        }
      } footer: {
        Text("Заметки и диктовки старше этого срока удаляются автоматически. При сокращении срока старый текст удалится при следующем сохранении. Записи, ожидающие повтора, хранятся отдельно.")
      }
      if !days.isEmpty, validDays == nil {
        Text("Введите целое число от 1 до 36 500.")
          .foregroundStyle(.secondary)
      }
    }.listRowBackground(OldRus.vellum) }
    .oldRusPage()
    .navigationTitle("Хранение истории")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Сохранить") {
          guard let value = validDays else { return }
          configuration.historyRetentionDays = value
          dismiss()
        }
        .disabled(validDays == nil)
        .accessibilityIdentifier("save-history-retention-button")
      }
    }
    .onAppear { days = String(configuration.historyRetentionDays) }
  }
}
