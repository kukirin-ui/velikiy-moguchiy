import SwiftUI
import UIKit

/// «Начало работы»: everything the first dictation needs, checked live.
struct GettingStartedScreen: View {
  @ObservedObject var configuration: AppConfiguration
  @ObservedObject var checklist: SetupChecklist
  let store: SharedRelayStore
  let onClose: () -> Void

  private var progress: SetupProgress { checklist.progress(configuration) }

  var body: some View {
    List { Group {
      Section {
        VStack(alignment: .leading, spacing: 10) {
          Text(progress.isComplete ? "Всё готово" : "Четыре шага до первой диктовки")
            .font(.title2.weight(.semibold))
          ProgressView(
            value: Double(progress.completedSteps), total: Double(SetupProgress.stepCount)
          )
          .tint(OldRus.cinnabar)
          Text(
            progress.isComplete
              ? "Откройте любое приложение, глобусом выберите «Великий & Могучий» и нажмите микрофон."
              : "Готово \(progress.completedSteps) из \(SetupProgress.stepCount). Отметки ставятся сами, как только шаг сделан."
          )
          .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("getting-started-summary")
      }

      Section {
        NavigationLink {
          DashScopeConnectionScreen(configuration: configuration)
        } label: {
          checkRow("Ключ DashScope", detail: keyDetail, isDone: progress.hasKey, symbol: "key")
        }
        .accessibilityIdentifier("getting-started-key")

        Button {
          switch progress.microphone {
          case .undetermined: Task { await checklist.requestMicrophone(store: store) }
          case .denied: openAppSettings()
          case .granted: break
          }
        } label: {
          checkRow(
            "Микрофон", detail: microphoneDetail, isDone: progress.microphoneGranted, symbol: "mic")
        }
        .foregroundStyle(.primary)
        .disabled(progress.microphoneGranted)
        .accessibilityIdentifier("getting-started-microphone")

        NavigationLink {
          KeyboardSetupScreen(checklist: checklist, store: store)
        } label: {
          checkRow(
            "Клавиатура добавлена", detail: keyboardDetail, isDone: progress.keyboardAdded,
            symbol: "keyboard")
        }
        .accessibilityIdentifier("getting-started-keyboard")

        NavigationLink {
          KeyboardSetupScreen(checklist: checklist, store: store)
        } label: {
          checkRow(
            "Полный доступ", detail: fullAccessDetail, isDone: progress.fullAccess,
            symbol: "lock.open")
        }
        .accessibilityIdentifier("getting-started-full-access")
      } header: {
        OldRusHeader("Что нужно")
      }

      Section {
        NavigationLink {
          KeyboardTryoutView()
        } label: {
          Label("Попробовать диктовку", systemImage: "text.cursor")
        }
        .accessibilityIdentifier("getting-started-tryout")
      } footer: {
        Text("В поле для проверки нажмите на глобус, выберите «Великий & Могучий RU» и нажмите микрофон. Звук записывает приложение, клавиатура только передаёт команды и вставляет текст.")
      }
    }.listRowBackground(OldRus.vellum) }
    .oldRusPage()
    .navigationTitle("Начало работы")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button(progress.isComplete ? "Готово" : "Позже", action: onClose)
          .accessibilityIdentifier("getting-started-close")
      }
    }
    .task {
      while !Task.isCancelled {
        checklist.refresh(store: store)
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  private var keyDetail: String {
    if !progress.hasKey { return "Нужен ключ Alibaba Cloud: там же инструкция, где его взять." }
    return progress.keyVerified ? "Работает." : "Сохранён, но не проверен: откройте и нажмите «Проверить ключ»."
  }

  private var microphoneDetail: String {
    switch progress.microphone {
    case .granted: return "Разрешён."
    case .undetermined: return "Нажмите, чтобы разрешить: голос записывает приложение."
    case .denied: return "Запрещён. Нажмите и включите «Микрофон» в настройках iOS."
    }
  }

  private var keyboardDetail: String {
    if progress.keyboardAdded { return "«Великий & Могучий» есть в списке клавиатур." }
    return "Добавьте в настройках iOS: Клавиатуры → «Великий & Могучий RU» и «EN»."
  }

  private var fullAccessDetail: String {
    if progress.fullAccess { return "Клавиатура связалась с приложением." }
    return "Включите «Полный доступ» и один раз откройте клавиатуру в любом поле."
  }

  private func checkRow(_ title: String, detail: String, isDone: Bool, symbol: String) -> some View {
    HStack(spacing: 14) {
      Image(systemName: isDone ? "checkmark.circle.fill" : symbol)
        .font(.title3)
        .foregroundStyle(isDone ? OldRus.cinnabar : Color.secondary)
        .frame(width: 30)
        .contentTransition(.symbolEffect(.replace))
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.headline)
        Text(detail).font(.subheadline).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
    .accessibilityValue(isDone ? "Готово" : "Не сделано")
  }

  private func openAppSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url)
  }
}
