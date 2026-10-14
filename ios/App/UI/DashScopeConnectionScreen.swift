import SwiftUI

/// Key, region and where to get a key, with a check that opens a real session.
struct DashScopeConnectionScreen: View {
  @ObservedObject var configuration: AppConfiguration

  @State private var isChecking = false
  @State private var checkTask: Task<Void, Never>?
  @State private var checkGeneration = 0
  @State private var outcome: DashScopeKeyCheck.Outcome?
  /// Region and key the outcome belongs to; a stale outcome is not shown.
  @State private var outcomeSubject = ""

  private var currentSubject: String {
    "\(configuration.dashScopeRegion.rawValue)|\(configuration.apiKey)"
  }

  private var visibleOutcome: DashScopeKeyCheck.Outcome? {
    outcomeSubject == currentSubject ? outcome : nil
  }

  var body: some View {
    Form { Group {
      Section {
        statusRow
        SecureField("Ключ API (sk-…)", text: $configuration.apiKeyOverride)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .submitLabel(.done)
          .onSubmit(check)
          .accessibilityIdentifier("api-key-field")
        PasteButton(payloadType: String.self) { strings in
          guard let pasted = strings.first?.trimmingCharacters(in: .whitespacesAndNewlines),
            !pasted.isEmpty
          else { return }
          Task { @MainActor in
            configuration.apiKeyOverride = pasted
            check()
          }
        }
        .accessibilityIdentifier("api-key-paste-button")
        Button(action: check) {
          Label("Проверить ключ", systemImage: "checkmark.shield")
        }
        .disabled(!configuration.hasUsableAPIKey || isChecking)
        .accessibilityIdentifier("api-key-check-button")
        if !configuration.apiKeyOverride.isEmpty {
          Button("Удалить ключ", role: .destructive) { configuration.clearAPIKeyOverride() }
        }
      } header: {
        OldRusHeader("Ключ API")
      } footer: {
        Text("Ключ хранится в Keychain этого iPhone и не передаётся клавиатурам: сетью занимается только приложение.")
      }
      if let warning = configuration.credentialPersistenceWarning {
        Section { Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(OldRus.ochre) }
      }

      Section {
        Picker("Регион", selection: $configuration.dashScopeRegion) {
          ForEach(DashScopeRegion.allCases) { region in
            Text(region.title).tag(region)
          }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("dashscope-region-picker")
      } header: {
        OldRusHeader("Регион")
      } footer: {
        Text("Ключ работает только в регионе, где его создали. «Международный» — аккаунт на alibabacloud.com (сервер в Сингапуре), «Китай» — аккаунт на aliyun.com (сервер в Пекине). Проверка ключа сама переключит регион, если ключ из другого.")
      }

      Section {
        VStack(alignment: .leading, spacing: 10) {
          Text("1. Зарегистрируйтесь в Alibaba Cloud и откройте Model Studio.")
          Text("2. В разделе API Key нажмите «Create API Key» и скопируйте ключ: он начинается с «sk-».")
          Text("3. Вставьте ключ сюда и нажмите «Проверить ключ».")
        }
        .font(.subheadline)
        .padding(.vertical, 4)
        Link(destination: configuration.dashScopeRegion.apiKeyConsoleURL) {
          Label("Открыть консоль Model Studio", systemImage: "arrow.up.right.square")
        }
        .accessibilityIdentifier("api-key-console-link")
      } header: {
        OldRusHeader("Где взять ключ")
      } footer: {
        Text("Распознавание оплачивается в Alibaba Cloud по их тарифам: для работы на счёте нужен баланс или бесплатный лимит нового аккаунта.")
      }
    }.listRowBackground(OldRus.vellum) }
    .oldRusPage()
    .navigationTitle("Ключ DashScope")
    .navigationBarTitleDisplayMode(.inline)
    .scrollDismissesKeyboard(.interactively)
    .onDisappear { checkTask?.cancel() }
  }

  @ViewBuilder private var statusRow: some View {
    if isChecking {
      HStack(spacing: 10) {
        ProgressView()
        Text("Проверяю ключ…")
      }
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("api-key-status")
    } else if let outcome = visibleOutcome {
      switch outcome {
      case .works, .worksInOtherRegion:
        Label(outcome.message, systemImage: "checkmark.circle.fill")
          .foregroundStyle(OldRus.cinnabar)
          .accessibilityIdentifier("api-key-status")
      case .failed:
        Label(outcome.message, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(OldRus.ochre)
          .accessibilityIdentifier("api-key-status")
      }
    } else if !configuration.hasUsableAPIKey {
      Label("Добавьте ключ DashScope", systemImage: "key")
        .accessibilityIdentifier("api-key-status")
    } else if configuration.isKeyVerified {
      Label("Ключ работает.", systemImage: "checkmark.circle.fill")
        .foregroundStyle(OldRus.cinnabar)
        .accessibilityIdentifier("api-key-status")
    } else {
      Label("Ключ сохранён, но ещё не проверен.", systemImage: "questionmark.circle")
        .accessibilityIdentifier("api-key-status")
    }
  }

  private func check() {
    guard configuration.hasUsableAPIKey else { return }
    checkTask?.cancel()
    checkGeneration += 1
    let generation = checkGeneration
    let apiKey = configuration.apiKey
    let region = configuration.dashScopeRegion
    isChecking = true
    checkTask = Task { @MainActor in
      let result = await DashScopeKeyCheck().run(apiKey: apiKey, region: region)
      guard generation == checkGeneration else { return }
      isChecking = false
      guard !Task.isCancelled,
        configuration.apiKey == apiKey,
        configuration.dashScopeRegion == region
      else { return }
      configuration.apply(result)
      outcome = result
      outcomeSubject = currentSubject
    }
  }
}
