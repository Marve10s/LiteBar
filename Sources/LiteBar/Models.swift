import Foundation

enum Provider: String, CaseIterable, Sendable, Identifiable, Codable {
    case codex
    case claude
    case antigravity
    case opencode

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        case .antigravity: "Antigravity"
        case .opencode: "OpenCode"
        }
    }

    var sourceDescription: String {
        switch self {
        case .codex: "~/.codex/auth.json · ChatGPT usage endpoint"
        case .claude: "Keychain · Anthropic OAuth usage endpoint"
        case .antigravity: "~/.gemini/antigravity-cli · Cloud Code quota endpoint"
        case .opencode: "~/.local/share/opencode/auth.json · OpenCode Go usage endpoint"
        }
    }

    var localUsageDescription: String? {
        switch self {
        case .codex: "~/.codex/sessions"
        case .claude: "~/.claude/projects"
        case .opencode: "~/.local/share/opencode/opencode.db"
        case .antigravity: nil
        }
    }
}

struct RateWindow: Sendable, Equatable {
    var usedPercent: Double
    var resetsAt: Date?
    var windowSeconds: Double?
    var title: String?

    var leftPercent: Double { max(0, min(100, 100 - usedPercent)) }

    var displayTitle: String {
        if let title = title, !title.isEmpty { return title }
        switch windowSeconds {
        case .some(..<86_400): return "Session"
        case .some(604_800): return "Weekly"
        case .some(let secs): return "Window (\(Int(secs / 86_400))d)"
        default: return "Window"
        }
    }
}

struct ProviderSnapshot: Identifiable, Sendable, Equatable {
    var id: Provider { provider }
    var provider: Provider
    var accountLine: String?
    var badge: String?
    var windows: [RateWindow]
    var extras: [RateWindow]
    var extrasTitle: String?
    var creditsAvailable: Int?
    var error: String?
    var connectionFailed = false
    var isLocalCapture = false
    var fetchedAt: Date

    static func failed(_ provider: Provider, _ error: Error) -> ProviderSnapshot {
        ProviderSnapshot(provider: provider, windows: [], extras: [],
                         error: error.localizedDescription,
                         connectionFailed: Connectivity.isConnectionError(error), fetchedAt: Date())
    }

    var tightestWindow: RateWindow? {
        windows.min { $0.leftPercent < $1.leftPercent }
    }

    var worstLeftPercent: Double {
        tightestWindow?.leftPercent ?? 100
    }
}

struct ResetCredit: Sendable, Equatable, Identifiable {
    var id: String
    var grantedAt: Date?
    var expiresAt: Date?
}

struct ProviderTotals: Sendable, Equatable {
    var tokens24h: Int = 0
    var tokens30d: Int = 0
    var lineCount: Int = 0
    var computedAt = Date()
}

enum LoadState<Value: Sendable & Equatable>: Sendable, Equatable {
    case idle
    case loading
    case done(Value)
    case failed(String)
}

enum RefreshInterval: Int, CaseIterable, Identifiable {
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case manual = 0

    var id: Int { rawValue }
    var seconds: Int { rawValue }

    var label: String {
        switch self {
        case .oneMinute: "Every minute"
        case .fiveMinutes: "Every 5 minutes"
        case .fifteenMinutes: "Every 15 minutes"
        case .manual: "Manual only"
        }
    }

    static var current: RefreshInterval {
        guard UserDefaults.standard.object(forKey: "refreshInterval") != nil else { return .fiveMinutes }
        return RefreshInterval(rawValue: UserDefaults.standard.integer(forKey: "refreshInterval")) ?? .fiveMinutes
    }
}

enum MenuBarSource: RawRepresentable, Hashable {
    case tightest
    case provider(Provider)

    static let key = "menuBarSource"

    var rawValue: String {
        switch self {
        case .tightest: "tightest"
        case let .provider(provider): provider.rawValue
        }
    }

    init?(rawValue: String) {
        if rawValue == "tightest" { self = .tightest; return }
        guard let provider = Provider(rawValue: rawValue) else { return nil }
        self = .provider(provider)
    }

    var label: String {
        switch self {
        case .tightest: "Tightest window overall"
        case let .provider(provider): provider.displayName
        }
    }

    static var current: MenuBarSource {
        UserDefaults.standard.string(forKey: key).flatMap(MenuBarSource.init(rawValue:)) ?? .tightest
    }
}

enum ProviderPreferences {
    static let key = "enabledProviders"

    static var enabled: [Provider] {
        guard let raw = UserDefaults.standard.stringArray(forKey: key) else { return Provider.allCases }
        return Provider.allCases.filter { raw.contains($0.rawValue) }
    }

    static func setEnabled(_ provider: Provider, _ enabled: Bool) {
        var current = Set(Self.enabled.map(\.rawValue))
        if enabled { current.insert(provider.rawValue) } else { current.remove(provider.rawValue) }
        UserDefaults.standard.set(Provider.allCases.map(\.rawValue).filter(current.contains), forKey: key)
    }
}

struct WindowPreferences: Codable, Equatable {
    static let key = "windowPreferences"
    static let tightest = "tightest"

    var hidden: [String: [String]] = [:]
    var headline: [String: String] = [:]

    static func load() -> WindowPreferences {
        guard let data = UserDefaults.standard.data(forKey: key),
              let prefs = try? JSONDecoder().decode(WindowPreferences.self, from: data) else { return WindowPreferences() }
        return prefs
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }

    func isVisible(_ title: String, for provider: Provider) -> Bool {
        !(hidden[provider.rawValue] ?? []).contains(title)
    }

    mutating func setVisible(_ visible: Bool, _ title: String, for provider: Provider) {
        var titles = hidden[provider.rawValue] ?? []
        titles.removeAll { $0 == title }
        if !visible { titles.append(title) }
        hidden[provider.rawValue] = titles
    }

    func headline(for provider: Provider) -> String {
        headline[provider.rawValue] ?? Self.tightest
    }

    mutating func setHeadline(_ title: String, for provider: Provider) {
        headline[provider.rawValue] = title == Self.tightest ? nil : title
    }

    func visibleWindows(of snapshot: ProviderSnapshot) -> [RateWindow] {
        snapshot.windows.filter { isVisible($0.displayTitle, for: snapshot.provider) }
    }

    func headlineWindow(of snapshot: ProviderSnapshot) -> RateWindow? {
        let visible = visibleWindows(of: snapshot)
        let chosen = headline(for: snapshot.provider)
        if let window = visible.first(where: { $0.displayTitle == chosen }) { return window }
        return visible.min { $0.leftPercent < $1.leftPercent }
    }
}
