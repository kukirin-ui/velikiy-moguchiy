import Foundation

/// Why a dictation produced no text, in words the user can act on.
///
/// `keyboardText` fits the one-line status row of the keyboard; `detail` is the
/// full sentence shown in the app and next to a saved recording. The raw
/// provider message never reaches the user: it goes to the log, and `code`
/// is what the user can quote when reporting a problem.
struct DictationFailure: Equatable {
  enum Kind: Equatable {
    case noSpeech
    case notRecognized
    case missingKey
    case invalidKey
    case account
    case rateLimited
    case offline
    case timedOut
    case connectionLost
    case serviceDown
    case other
  }

  let kind: Kind
  let code: String

  /// A silent recording holds nothing to retry, so it is not kept.
  var keepsRecording: Bool { kind != .noSpeech }

  var keyboardText: String {
    switch kind {
    case .noSpeech: return "Речь не слышна — ничего не вставлено"
    case .notRecognized: return "Речь не распознана — запись сохранена"
    case .missingKey: return "Нет ключа DashScope — добавьте в приложении"
    case .invalidKey: return "Ключ DashScope не подошёл — см. приложение"
    case .account: return "DashScope отказал: проверьте баланс"
    case .rateLimited: return "Лимит запросов DashScope — повторите позже"
    case .offline: return "Нет интернета — запись сохранена"
    case .timedOut: return "DashScope не ответил — запись сохранена"
    case .connectionLost: return "Связь прервалась — запись сохранена"
    case .serviceDown: return "DashScope недоступен — запись сохранена"
    case .other: return "Не удалось распознать (код \(code)) — запись сохранена"
    }
  }

  var detail: String {
    switch kind {
    case .noSpeech:
      return "Речь не слышна. Говорите ближе к микрофону и нажмите его ещё раз, когда закончите."
    case .notRecognized:
      return "DashScope не нашёл в записи слов. Повторите распознавание или удалите запись."
    case .missingKey:
      return "Нет ключа DashScope. Добавьте его: Настройки → Ключ DashScope."
    case .invalidKey:
      return "DashScope не принял ключ. Проверьте ключ и регион: Настройки → Ключ DashScope."
    case .account:
      return "DashScope отказал в доступе: на счёте Alibaba Cloud закончились деньги или бесплатный лимит, либо модель не включена. Проверьте баланс в консоли Model Studio."
    case .rateLimited:
      return "Слишком много запросов к DashScope. Подождите минуту и повторите."
    case .offline:
      return "Нет интернета. Когда связь появится, нажмите «Повторить»."
    case .timedOut:
      return "DashScope не ответил вовремя. Повторите распознавание: обычно со второго раза получается."
    case .connectionLost:
      return "Связь с DashScope прервалась. Повторите распознавание."
    case .serviceDown:
      return "Сервис DashScope сейчас недоступен. Повторите позже."
    case .other:
      return "Не удалось распознать (код \(code)). Повторите; если ошибка не уходит, сообщите этот код разработчикам."
    }
  }

  init(kind: Kind, code: String) {
    self.kind = kind
    self.code = code
  }

  init(_ error: Error) {
    switch error {
    case let speechError as DashScopeSpeechError:
      self = Self.classify(speechError)
    case let captureError as AudioCaptureError:
      self.init(kind: .other, code: "A-\(Self.caseName(captureError))")
    default:
      let nsError = error as NSError
      if nsError.domain == NSURLErrorDomain {
        self = Self.classify(urlErrorCode: nsError.code)
      } else {
        self.init(kind: .other, code: "\(Self.shortDomain(nsError.domain))\(nsError.code)")
      }
    }
  }

  private static func classify(_ error: DashScopeSpeechError) -> DictationFailure {
    switch error {
    case .noSpeech:
      return DictationFailure(kind: .noSpeech, code: "silence")
    case .emptyResult:
      return DictationFailure(kind: .notRecognized, code: "empty")
    case .missingCredential:
      return DictationFailure(kind: .missingKey, code: "nokey")
    case .rejected(let status):
      return classify(httpStatus: status)
    case .provider(let code, let message):
      return classify(providerCode: code, message: message)
    case .connectionClosed:
      return DictationFailure(kind: .connectionLost, code: "closed")
    case .service:
      return DictationFailure(kind: .connectionLost, code: "stream")
    case .invalidEndpoint:
      return DictationFailure(kind: .other, code: "url")
    case .invalidMessage:
      return DictationFailure(kind: .other, code: "json")
    case .alreadyConnected:
      return DictationFailure(kind: .other, code: "busy")
    }
  }

  static func classify(httpStatus: Int) -> DictationFailure {
    let code = "http\(httpStatus)"
    switch httpStatus {
    case 401: return DictationFailure(kind: .invalidKey, code: code)
    case 400, 402, 403: return DictationFailure(kind: .account, code: code)
    case 408, 504: return DictationFailure(kind: .timedOut, code: code)
    case 429: return DictationFailure(kind: .rateLimited, code: code)
    case 500...599: return DictationFailure(kind: .serviceDown, code: code)
    default: return DictationFailure(kind: .other, code: code)
    }
  }

  /// Codes and messages as DashScope documents them (InvalidApiKey,
  /// Arrearage, AllocationQuota.FreeTierOnly, Throttling.RateQuota, ...).
  static func classify(providerCode: String?, message: String) -> DictationFailure {
    let haystack = "\(providerCode ?? "") \(message)".lowercased()
    let code = providerCode.map { String($0.prefix(32)) } ?? "svc"
    func has(_ needles: String...) -> Bool { needles.contains { haystack.contains($0) } }
    if has("invalidapikey", "invalid api-key", "invalid api key", "unauthorized") {
      return DictationFailure(kind: .invalidKey, code: code)
    }
    if has("arrearage", "good standing", "freetieronly", "free tier", "allocationquota",
      "accessdenied", "access denied", "model.accessdenied")
    {
      return DictationFailure(kind: .account, code: code)
    }
    if has("throttl", "ratequota", "rate limit", "too many requests") {
      return DictationFailure(kind: .rateLimited, code: code)
    }
    if has("internalerror", "serviceunavailable", "service unavailable", "internal error") {
      return DictationFailure(kind: .serviceDown, code: code)
    }
    return DictationFailure(kind: .other, code: code)
  }

  static func classify(urlErrorCode: Int) -> DictationFailure {
    let code = "net\(urlErrorCode)"
    switch urlErrorCode {
    case NSURLErrorTimedOut:
      return DictationFailure(kind: .timedOut, code: code)
    case NSURLErrorNotConnectedToInternet,
      NSURLErrorDataNotAllowed,
      NSURLErrorInternationalRoamingOff,
      NSURLErrorCannotFindHost,
      NSURLErrorDNSLookupFailed,
      NSURLErrorCannotConnectToHost:
      return DictationFailure(kind: .offline, code: code)
    case NSURLErrorNetworkConnectionLost:
      return DictationFailure(kind: .connectionLost, code: code)
    case NSURLErrorUserAuthenticationRequired:
      return DictationFailure(kind: .invalidKey, code: code)
    default:
      return DictationFailure(kind: .other, code: code)
    }
  }

  private static func caseName(_ value: Any) -> String {
    String(String(describing: value).prefix { $0 != "(" })
  }

  private static func shortDomain(_ domain: String) -> String {
    String(domain.split(separator: ".").last ?? Substring(domain)).prefix(12).lowercased()
  }
}
