import Foundation

struct CodexAuth: Sendable {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
    var accountID: String?
    var fileURL: URL

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
    }

    static func load() throws -> CodexAuth {
        let url = defaultURL
        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let tokens = obj?["tokens"] as? [String: Any] else {
            throw AppError("No tokens in ~/.codex/auth.json — run `codex login` first.")
        }
        guard let access = tokens["access_token"] as? String, !access.isEmpty else {
            throw AppError("No access_token in ~/.codex/auth.json — run `codex login` first.")
        }
        return CodexAuth(
            accessToken: access,
            refreshToken: tokens["refresh_token"] as? String,
            idToken: tokens["id_token"] as? String,
            accountID: tokens["account_id"] as? String,
            fileURL: url
        )
    }

    func tokenExpiration() -> Date? {
        if let idToken = idToken, !idToken.isEmpty, let exp = Self.expiration(ofJWT: idToken) {
            return exp
        }
        return Self.expiration(ofJWT: accessToken)
    }

    static func expiration(ofJWT jwt: String) -> Date? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
        payload = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = obj["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    @discardableResult
    mutating func refresh(force: Bool = false) async throws -> Bool {
        if !force {
            guard let exp = tokenExpiration() else { return false }
            guard exp <= Date().addingTimeInterval(120) else { return false }
        }
        guard let currentRefresh = refreshToken, !currentRefresh.isEmpty else {
            throw AppError("Codex token expired and no refresh token available — run `codex login`.")
        }

        var request = URLRequest(url: URL(string: "https://auth.openai.com/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: currentRefresh),
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "scope", value: "openid profile email offline_access"),
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        struct TokenResponse: Decodable {
            var access_token: String
            var refresh_token: String?
            var id_token: String?
        }

        let (data, response) = try await HTTPClient.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppError("Codex token refresh failed.") }
        guard http.statusCode == 200 else {
            throw AppError("Codex token refresh failed (HTTP \(http.statusCode)) — run `codex login`.")
        }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)

        accessToken = decoded.access_token
        if let newRefresh = decoded.refresh_token, !newRefresh.isEmpty { refreshToken = newRefresh }
        if let newID = decoded.id_token, !newID.isEmpty { idToken = newID }
        persist()
        return true
    }

    private func persist() {
        guard var obj = try? JSONSerialization.jsonObject(with: Data(contentsOf: fileURL) ) as? [String: Any] else { return }
        var tokens = (obj["tokens"] as? [String: Any]) ?? [:]
        tokens["access_token"] = accessToken
        tokens["refresh_token"] = refreshToken
        tokens["id_token"] = idToken
        obj["tokens"] = tokens
        obj["last_refresh"] = ISO8601DateFormatter().string(from: Date())
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
}

struct FlexibleDate: Decodable, Sendable {
    var date: Date?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let seconds = try? container.decode(Double.self) {
            date = Date(timeIntervalSince1970: seconds)
        } else if let string = try? container.decode(String.self) {
            date = CodexClient.parseDate(string)
        } else {
            date = nil
        }
    }
}

struct CodexUsage: Sendable, Equatable {
    var windows: [RateWindow]
    var extras: [RateWindow]
    var planType: String?
    var email: String?
    var resetCreditCount: Int?
    var creditBalance: String?
}

enum CodexClient {
    static func usage() async throws -> CodexUsage {
        var auth = try CodexAuth.load()
        try await auth.refresh()
        let data = try await authorizedGet("https://chatgpt.com/backend-api/wham/usage", auth: &auth)

        struct Window: Decodable {
            var used_percent: Double?
            var reset_at: FlexibleDate?
            var reset_after_seconds: Double?
            var limit_window_seconds: Double?
        }
        struct Limits: Decodable {
            var primary_window: Window?
            var secondary_window: Window?
        }
        struct AdditionalLimit: Decodable {
            var limit_name: String?
            var rate_limit: Limits?
        }
        struct Body: Decodable {
            var rate_limit: Limits?
            var rate_limits: Limits?
            var plan_type: String?
            var email: String?
            var credits: Credit?
            var additional_rate_limits: [AdditionalLimit]?
            var code_review_rate_limit: AdditionalLimit?
            var rate_limit_reset_credits: ResetCreditsCount?
        }
        struct ResetCreditsCount: Decodable {
            var available_count: Int?
            var applicable_available_count: Int?
        }
        struct Credit: Decodable {
            var balance: String?
            var has_credits: Bool?
        }

        let body = try JSON.decode(Body.self, from: data)
        let limits = body.rate_limit ?? body.rate_limits
        func map(_ window: Window?) -> RateWindow? {
            guard let window = window, let used = window.used_percent else { return nil }
            var reset = window.reset_at?.date
            if reset == nil, let secs = window.reset_after_seconds, secs > 0 {
                reset = Date().addingTimeInterval(secs)
            }
            return RateWindow(
                usedPercent: used,
                resetsAt: reset,
                windowSeconds: window.limit_window_seconds,
                title: nil
            )
        }
        let windows = [map(limits?.primary_window), map(limits?.secondary_window)].compactMap(\.self)

        var extras: [RateWindow] = []
        var extraSources: [(name: String?, limit: AdditionalLimit?)] = []
        extraSources.append((nil, body.code_review_rate_limit))
        for additional in body.additional_rate_limits ?? [] {
            extraSources.append((additional.limit_name, additional))
        }
        for (explicitName, source) in extraSources {
            guard let source = source else { continue }
            let name = explicitName.flatMap(Self.shortLimitName) ?? "Code review"
            if var window = map(source.rate_limit?.primary_window) {
                window.title = "\(name) · 5h"
                extras.append(window)
            }
            if var window = map(source.rate_limit?.secondary_window) {
                window.title = "\(name) · weekly"
                extras.append(window)
            }
        }

        return CodexUsage(
            windows: windows,
            extras: extras,
            planType: body.plan_type,
            email: body.email,
            resetCreditCount: body.rate_limit_reset_credits?.available_count,
            creditBalance: body.credits?.balance
        )
    }

    static func shortLimitName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: "-")
        if let last = parts.last {
            let suffix = String(last)
            if suffix.count <= 10 && suffix.lowercased() != "codex" {
                return suffix
            }
        }
        return trimmed
    }

    static func resetCredits() async throws -> [ResetCredit] {
        var auth = try CodexAuth.load()
        try await auth.refresh()
        let data = try await authorizedGet("https://chatgpt.com/backend-api/wham/rate-limit-reset-credits", auth: &auth)

        struct RawCredit: Decodable {
            var status: String?
            var granted_at: String?
            var expires_at: String?
        }
        struct Body: Decodable {
            var available_count: Int?
            var availableCount: Int?
            var credits: [RawCredit]?
        }

        let body = try JSON.decode(Body.self, from: data)
        let raw = body.credits ?? []
        let available = raw.filter { $0.status == nil || $0.status?.lowercased() == "available" }
        let credits = available.enumerated().map { index, c in
            ResetCredit(
                id: "\(index)-\(c.expires_at ?? String(index))",
                grantedAt: c.granted_at.flatMap(Self.parseDate),
                expiresAt: c.expires_at.flatMap(Self.parseDate)
            )
        }
        if !credits.isEmpty { return credits }
        if let count = body.available_count ?? body.availableCount, count > 0 {
            return (0..<count).map { ResetCredit(id: "count-\($0)", grantedAt: nil, expiresAt: nil) }
        }
        return []
    }

    private static func authorizedGet(_ urlString: String, auth: inout CodexAuth) async throws -> Data {
        do {
            return try await get(urlString, auth: auth)
        } catch let error as AppError where error.message.contains("HTTP 401") {
            try await auth.refresh(force: true)
            return try await get(urlString, auth: auth)
        }
    }

    private static func get(_ urlString: String, auth: CodexAuth) async throws -> Data {
        guard let url = URL(string: urlString) else { throw AppError("Bad URL") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        request.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue("litebar/0.1", forHTTPHeaderField: "User-Agent")
        if let accountID = auth.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
        }
        let (data, response) = try await HTTPClient.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppError("No response") }
        guard (200..<300).contains(http.statusCode) else {
            throw AppError("Codex API HTTP \(http.statusCode) from \(urlString)")
        }
        return data
    }

    static func parseDate(_ s: String) -> Date? {
        for formatter in [Self.isoFractional, Self.iso] {
            if let date = formatter.date(from: s) { return date }
        }
        return nil
    }

    private nonisolated(unsafe) static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private nonisolated(unsafe) static let iso = ISO8601DateFormatter()
}
