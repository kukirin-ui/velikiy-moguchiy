import Foundation

/// A DashScope key works only in the region where it was created.
enum DashScopeRegion: String, CaseIterable, Identifiable, Sendable {
  /// Alibaba Cloud accounts registered outside mainland China (Singapore).
  case international = "intl"
  /// aliyun.com accounts (Beijing).
  case china = "cn"

  static let defaultsKey = "configuration.dashscope-region"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .international: return "Международный"
    case .china: return "Китай"
    }
  }

  var host: String {
    switch self {
    case .international: return "dashscope-intl.aliyuncs.com"
    case .china: return "dashscope.aliyuncs.com"
    }
  }

  var realtimeBaseURL: String { "wss://\(host)" }

  var other: DashScopeRegion {
    self == .international ? .china : .international
  }

  /// Where a key for this region is created.
  var apiKeyConsoleURL: URL {
    switch self {
    case .international:
      return URL(string: "https://modelstudio.console.alibabacloud.com/?tab=playground#/api-key")!
    case .china:
      return URL(string: "https://bailian.console.aliyun.com/?tab=model#/api-key")!
    }
  }

  /// Installs that already had a key were set up when the app only knew the
  /// Beijing endpoint; they keep it. Everyone else starts international.
  static func resolve(stored: String?, hasExistingKey: Bool) -> DashScopeRegion {
    if let stored, let region = DashScopeRegion(rawValue: stored) { return region }
    return hasExistingKey ? .china : .international
  }
}
