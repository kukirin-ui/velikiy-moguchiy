import SwiftUI

extension ContentView {
  var settingsScreen: some View {
    Form { Group {
      Section {
        Button { isGettingStartedPresented = true } label: {
          Label {
            HStack {
              Text("Начало работы").foregroundStyle(.primary)
              Spacer()
              Text(
                setupProgress.isComplete
                  ? "Всё готово" : "\(setupProgress.completedSteps) из \(SetupProgress.stepCount)"
              )
              .foregroundStyle(.secondary)
              .font(.subheadline)
            }
          } icon: { Image(systemName: "checklist").foregroundStyle(OldRus.cinnabar) }
        }
        .accessibilityIdentifier("getting-started-link")
        NavigationLink { connectionScreen } label: {
          Label {
            HStack {
              Text("Ключ DashScope")
              Spacer()
              Text(
                !configuration.hasUsableAPIKey
                  ? "Добавить" : configuration.isKeyVerified ? "Работает" : "Не проверен"
              )
                .foregroundStyle(.secondary)
                .font(.subheadline)
            }
          } icon: { Image(systemName: "key").foregroundStyle(OldRus.cinnabar) }
        }
        .accessibilityIdentifier("dashscope-connection-link")
        NavigationLink { setupScreen } label: {
          settingsLabel("Настройка клавиатур", symbol: "keyboard")
        }
        NavigationLink { KeyboardTryoutView() } label: {
          settingsLabel("Проверить клавиатуру", symbol: "text.cursor")
        }
        NavigationLink { TypingStatsScreen(store: relay.store) } label: {
          settingsLabel("Скорость набора", symbol: "speedometer")
        }
        .accessibilityIdentifier("typing-stats-link")
        Button(action: openSystemSettings) {
          settingsLabel("Микрофон и разрешения", symbol: "mic")
        }
        .foregroundStyle(.primary)
      } header: {
        OldRusHeader("Подключение")
      }

      Section {
        languagePicker
      } header: {
        OldRusHeader("Заметки")
      } footer: {
        Text("Язык голосовых заметок, записанных прямо в приложении. С клавиатуры язык берётся от клавиатуры: Великий & Могучий RU диктует по-русски, Великий & Могучий EN по-английски.")
      }

      Section {
        Toggle("Вибрация при нажатии", isOn: $configuration.keyHapticsEnabled)
          .accessibilityIdentifier("key-haptics-toggle")
        Toggle("Звук клавиш (как в системе)", isOn: $configuration.keyClickSoundEnabled)
          .accessibilityIdentifier("key-click-sound-toggle")
        Toggle("Автоисправление", isOn: $configuration.autocorrectEnabled)
          .accessibilityIdentifier("autocorrect-toggle")
      } header: {
        OldRusHeader("Клавиатура")
      } footer: {
        Text("Вибрация работает только при включённом «Разрешить полный доступ» для клавиатуры. Звук следует системной настройке «Звуки клавиатуры» в iOS. Подсказки слов и текстовые замены работают всегда; «Автоисправление» заменяет слово с опечаткой по пробелу и выключено по умолчанию. Клавиша ⌫ сразу после замены возвращает исходное слово.")
      }

      Section {
        NavigationLink {
          HistoryRetentionSettings(configuration: configuration)
        } label: {
          LabeledContent("Хранить историю", value: "\(configuration.historyRetentionDays) дн.")
        }
        .accessibilityIdentifier("history-retention-link")
      } header: {
        OldRusHeader("История")
      } footer: {
        Text("Готовый текст хранится на этом iPhone столько дней, сколько вы выберете.")
      }

      Section {
        LabeledContent("Связь с клавиатурой", value: relay.store.transportKind.title)
          .accessibilityIdentifier("relay-transport-row")
      } footer: {
        Text(
          relay.store.transportKind == .appGroup
            ? "Приложение и клавиатуры обмениваются данными через общий App Group."
            : "App Group недоступен в этой подписи, поэтому используется резервный канал: именованный буфер обмена и уведомления Darwin. Он работает без App Group, но подпись всех трёх частей должна быть от одной команды."
        )
      }

      Section {
        Picker(
          "Микрофон остаётся включённым после диктовки",
          selection: $configuration.relaySessionLength
        ) {
          ForEach(RelaySessionLength.allCases) { length in
            Text(length.title).tag(length)
          }
        }
        .accessibilityIdentifier("relay-session-length-picker")
        Toggle("Выключать в режиме энергосбережения", isOn: $configuration.stopInLowPowerMode)
          .accessibilityIdentifier("stop-in-low-power-toggle")
      } header: {
        OldRusHeader("Приём голоса")
      } footer: {
        Text("Пока микрофон включён, клавиатура диктует без перехода в приложение, а iOS показывает оранжевый индикатор. Отсчёт идёт, пока клавиатурой не пользуются, и начинается заново при каждом показе клавиатуры, нажатии клавиши и диктовке. «Пока не выключу» расходует примерно 1–3 % заряда в час (оценка, не замер). Ниже 10 % заряда приём выключается всегда, в режиме энергосбережения — если включён переключатель: диктовка при этом срабатывает один раз. Live Activity на экране блокировки показывает остаток и кнопки «Стоп» и «Продлить».")
      }

      Section {
        NavigationLink { modelsScreen } label: {
          settingsLabel("Модель", symbol: "sparkles")
        }
        NavigationLink { privacyScreen } label: {
          settingsLabel("Звук и приватность", symbol: "hand.raised")
        }
        NavigationLink { licensesScreen } label: {
          settingsLabel("Лицензии", symbol: "doc.text")
        }
        .accessibilityIdentifier("licenses-link")
      }
      Section {
        HStack {
          Spacer()
          VStack(spacing: 8) {
            OldRusDivider().frame(maxWidth: 220)
            Image("Logo").resizable().scaledToFit().frame(maxWidth: 260)
              .accessibilityLabel("Великий & Могучий")
            Text("Голос там, где вы печатаете.").font(OldRus.bookHand(16)).foregroundStyle(.secondary)
          }
          .padding(.vertical, 12)
          Spacer()
        }
        .listRowBackground(Color.clear)
      }
    }.listRowBackground(OldRus.vellum) }
    .oldRusPage()
    .navigationTitle("Настройки")
  }

  func settingsLabel(_ title: String, symbol: String) -> some View {
    Label { Text(title).foregroundStyle(.primary) } icon: {
      Image(systemName: symbol).foregroundStyle(OldRus.cinnabar)
    }
  }

  var connectionScreen: some View {
    DashScopeConnectionScreen(configuration: configuration)
  }

  var modelsScreen: some View {
    Form { Group {
      Section(header: OldRusHeader("Распознавание речи")) {
        modelRow("Диктовка и заметки", model: configuration.speechModel, identifier: "active-speech-model")
        modelRow("Регион", model: configuration.dashScopeRegion.title)
        modelRow("Адрес", model: configuration.dashScopeRegion.realtimeBaseURL + "/api-ws/v1/realtime")
      }
    }.listRowBackground(OldRus.vellum) }
    .oldRusPage()
    .navigationTitle("Модель")
    .navigationBarTitleDisplayMode(.inline)
  }

  func modelRow(_ title: String, model: String, identifier: String = "") -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
      Text(model).font(.footnote.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityValue(model)
    .accessibilityIdentifier(identifier)
  }

  /// The bundled third-party notices (App/ThirdPartyNotices.txt, generated by
  /// tools/third-party-notices/generate.py).
  var licensesScreen: some View {
    ScrollView {
      Text(Self.thirdPartyNotices)
        .font(.caption.monospaced())
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }
    .background(OldRus.page.ignoresSafeArea())
    .navigationTitle("Лицензии")
    .navigationBarTitleDisplayMode(.inline)
  }

  static let thirdPartyNotices: String = {
    guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
          let text = try? String(contentsOf: url, encoding: .utf8)
    else {
      return "Файл с лицензиями не найден в этой сборке. Список сторонних компонентов: THIRD_PARTY.md в репозитории github.com/zigansh1n/velikiy-moguchiy."
    }
    return text
  }()

  var privacyScreen: some View {
    Form { Group {
      Section(header: OldRusHeader("Пока приём включён")) {
        Text("iOS показывает индикатор микрофона, потому что аудиосессия остаётся готовой для клавиатуры. Включение приёма само по себе диктовку не запускает.")
      }
      Section(header: OldRusHeader("Во время диктовки")) {
        Text("Звук с микрофона передаётся в Alibaba Cloud DashScope (Qwen Omni). Клавиатурная диктовка вставляет результат в поле ввода, голосовые заметки сохраняются здесь. Отмена останавливает передачу и удаляет запись.")
      }
      Section(header: OldRusHeader("На вашем iPhone")) {
        Text("Временная запись нужна на случай сбоя соединения. После успеха она удаляется, а при ошибке остаётся в истории, чтобы её можно было повторить или удалить.")
        Text("Готовый текст хранится в истории \(configuration.historyRetentionDays) дн. или пока вы его не удалите. Ключ API клавиатурам не передаётся.")
      }
    }.listRowBackground(OldRus.vellum) }
    .oldRusPage()
    .navigationTitle("Звук и приватность")
    .navigationBarTitleDisplayMode(.inline)
  }
}
