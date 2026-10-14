import SwiftUI

/// What the keyboards measured on this iPhone: the last 200 presses of each.
struct TypingStatsScreen: View {
  let store: SharedRelayStore
  @State private var rows: [(title: String, summary: TypingStats.Summary)] = []

  private static let keyboards = [
    ("Великий & Могучий RU", "ru"), ("Великий & Могучий EN", "en"), ("Великий & Могучий KK RU", "kk-ru"), ("Великий & Могучий KK EN", "kk-en"),
  ]

  var body: some View {
    Form { Group {
      ForEach(rows, id: \.title) { row in
        Section(row.title) {
          if row.summary.presses == 0 {
            Text("Нажатий пока нет").foregroundStyle(.secondary)
          } else {
            LabeledContent("Нажатий", value: "\(row.summary.presses)")
            LabeledContent("Без результата", value: "\(row.summary.withoutOutput)")
            LabeledContent("Внахлёст", value: "\(row.summary.overlapped)")
            spread("Касание дошло до клавиатуры", row.summary.delivery)
            spread("От отпускания до буквы", row.summary.releaseToOutput)
            spread("От касания до буквы", row.summary.pressToOutput)
          }
        }
      }
      Section {
        Button("Обновить", action: reload)
        Button("Начать замер заново", role: .destructive) {
          store.typingStatsResetAt = Date().timeIntervalSince1970
          reload()
        }
      } footer: {
        Text(
          "Каждая клавиатура запоминает последние 200 нажатий и сохраняет их, когда вы перестаёте печатать на 1,5 с или убираете клавиатуру. Время в миллисекундах: медиана (обычное нажатие) и p95 (5 % самых медленных). «Касание дошло» — сколько iOS везла касание до клавиатуры. «От отпускания до буквы» — сколько клавиатура думала после того, как палец поднялся. «От касания до буквы» включает и время, пока палец лежал на клавише. «Без результата» — нажатия, после которых ничего не произошло (потерянные). «Внахлёст» — нажатия, начатые, пока предыдущий палец ещё не поднялся."
        )
      }
    }.listRowBackground(OldRus.vellum) }
    .oldRusPage()
    .navigationTitle("Скорость набора")
    .onAppear(perform: reload)
  }

  private func spread(_ title: String, _ value: TypingStats.Spread?) -> some View {
    LabeledContent(
      title,
      value: value.map { "\(Self.ms($0.median)) / \(Self.ms($0.p95)) мс" } ?? "—")
  }

  private static func ms(_ value: Double) -> String {
    value < 10 ? String(format: "%.1f", value) : String(format: "%.0f", value)
  }

  private func reload() {
    let resetAt = store.typingStatsResetAt
    rows = Self.keyboards.map { title, id in
      (title, store.typingStats(keyboard: id).since(resetAt).summary)
    }
  }
}
