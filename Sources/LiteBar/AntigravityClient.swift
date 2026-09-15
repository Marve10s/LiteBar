import Foundation

enum AntigravityClient {
    struct Usage: Sendable {
        var pools: [RateWindow]
        var models: [RateWindow]
        var tier: String?
        var email: String?
    }

    static func usage() async throws -> Usage {
        try await session.usage()
    }

    private static let session = Session()

    static var geminiHome: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini")
    }

    actor Session {
        private var cachedToken: (value: String, expiry: Date)?
        private var oauthClient: (id: String, secret: String)?
        private var tier: String?

        func usage() async throws -> Usage {
            let token = try await accessToken()
            if tier == nil {
                tier = try? await AntigravityClient.loadTier(token: token)
            }
            let quotas = try await AntigravityClient.fetchModels(token: token)
            return Usage(
                pools: AntigravityClient.pools(from: quotas),
                models: quotas.map(\.window),
                tier: tier,
                email: AntigravityClient.activeEmail()
            )
        }

        private func accessToken() async throws -> String {
            let now = Date()
            if let cached = cachedToken, cached.expiry > now.addingTimeInterval(60) {
                return cached.value
            }
            let saved = try SavedToken.load()
            if let expiry = saved.expiry, expiry > now.addingTimeInterval(60), !saved.accessToken.isEmpty {
                cachedToken = (saved.accessToken, expiry)
                return saved.accessToken
            }
            guard let refreshToken = saved.refreshToken, !refreshToken.isEmpty else {
                throw AppError("Antigravity token expired and no refresh token saved — sign in with `agy` again.")
            }
            let refreshed = try await refresh(refreshToken: refreshToken)
            cachedToken = refreshed
            return refreshed.value
        }

        private func refresh(refreshToken: String) async throws -> (value: String, expiry: Date) {
            if let client = oauthClient {
                return try await AntigravityClient.refresh(refreshToken: refreshToken, client: client)
            }
            let candidates = AntigravityClient.discoverOAuthClients()
            guard !candidates.isEmpty else {
                throw AppError("Could not find the Antigravity OAuth client — is the `agy` CLI installed?")
            }
            var lastError: Error?
            for client in candidates {
                do {
                    let token = try await AntigravityClient.refresh(refreshToken: refreshToken, client: client)
                    oauthClient = client
                    return token
                } catch {
                    lastError = error
                }
            }
            throw lastError ?? AppError("Antigravity token refresh failed.")
        }
    }

    struct SavedToken {
        var accessToken: String
        var refreshToken: String?
        var expiry: Date?

        static var url: URL {
            geminiHome.appendingPathComponent("antigravity-cli/antigravity-oauth-token")
        }

        static func load() throws -> SavedToken {
            guard let data = try? Data(contentsOf: url) else {
                throw AppError("Antigravity CLI not signed in — run `agy` and log in with Google first.")
            }
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let token = object?["token"] as? [String: Any],
                  let access = token["access_token"] as? String else {
                throw AppError("Unrecognised Antigravity token file at ~/.gemini/antigravity-cli.")
            }
            let expiry = (token["expiry"] as? String).flatMap(parseExpiry)
            return SavedToken(accessToken: access, refreshToken: token["refresh_token"] as? String, expiry: expiry)
        }

        private static func parseExpiry(_ value: String) -> Date? {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            return ISO8601DateFormatter().date(from: value)
        }
    }

    static func activeEmail() -> String? {
        let url = geminiHome.appendingPathComponent("google_accounts.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["active"] as? String
    }

    static func discoverOAuthClients() -> [(id: String, secret: String)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/agy"),
            home.appendingPathComponent(".gemini/antigravity-cli/bin/agy"),
            URL(fileURLWithPath: "/Applications/Antigravity.app/Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm"),
            URL(fileURLWithPath: "/Applications/Antigravity.app/Contents/Resources/app/extensions/antigravity/bin/language_server_macos_x64"),
        ]
        for candidate in candidates {
            let resolved = candidate.resolvingSymlinksInPath()
            guard let data = try? Data(contentsOf: resolved, options: .alwaysMapped) else { continue }
            let ids = clientIDs(in: data)
            let secrets = clientSecrets(in: data)
            guard !ids.isEmpty, !secrets.isEmpty else { continue }
            return ids.flatMap { id in secrets.map { (id: id, secret: $0) } }
        }
        return []
    }

    private static func clientIDs(in data: Data) -> [String] {
        let suffix = Data(".apps.googleusercontent.com".utf8)
        let pattern = try! NSRegularExpression(pattern: "[0-9]{10,14}-[a-z0-9]{20,40}$")
        var found: [String] = []
        for position in occurrences(of: suffix, in: data) {
            let start = max(data.startIndex, position - 80)
            guard let window = String(data: data[start..<position], encoding: .utf8) ?? String(data: data[start..<position], encoding: .isoLatin1),
                  let match = pattern.firstMatch(in: window, range: NSRange(window.startIndex..., in: window)),
                  let range = Range(match.range, in: window) else { continue }
            let id = String(window[range]) + ".apps.googleusercontent.com"
            if !found.contains(id) { found.append(id) }
        }
        return found
    }

    private static func clientSecrets(in data: Data) -> [String] {
        let prefix = Data("GOCSPX-".utf8)
        var found: [String] = []
        for position in occurrences(of: prefix, in: data) {
            let end = position + prefix.count + 28
            guard end <= data.endIndex,
                  let secret = String(data: data[position..<end], encoding: .utf8),
                  secret.dropFirst(prefix.count).allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }),
                  !found.contains(secret) else { continue }
            found.append(secret)
        }
        return found
    }

    private static func occurrences(of needle: Data, in data: Data) -> [Int] {
        data.withUnsafeBytes { hay -> [Int] in
            needle.withUnsafeBytes { ned -> [Int] in
                guard let hayBase = hay.baseAddress, let nedBase = ned.baseAddress, ned.count > 0 else { return [] }
                var results: [Int] = []
                var offset = 0
                while offset + ned.count <= hay.count,
                      let hit = memmem(hayBase + offset, hay.count - offset, nedBase, ned.count) {
                    let index = hayBase.distance(to: hit)
                    results.append(index)
                    offset = index + 1
                }
                return results
            }
        }
    }

    static func refresh(refreshToken: String, client: (id: String, secret: String)) async throws -> (value: String, expiry: Date) {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: client.id),
            URLQueryItem(name: "client_secret", value: client.secret),
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await HTTPClient.session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AppError("Antigravity token refresh failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        struct TokenResponse: Decodable {
            var access_token: String
            var expires_in: Double?
        }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        return (decoded.access_token, Date().addingTimeInterval(decoded.expires_in ?? 3600))
    }

    private static let base = "https://cloudcode-pa.googleapis.com/v1internal:"

    private static func post<Response: Decodable>(_ method: String, token: String, body: [String: Any]) async throws -> Response {
        var request = URLRequest(url: URL(string: base + method)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("antigravity", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await HTTPClient.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: return try JSONDecoder().decode(Response.self, from: data)
        case 401: throw AppError("Antigravity session rejected — sign in with `agy` again.")
        default: throw AppError("Antigravity quota endpoint returned HTTP \(status).")
        }
    }

    static func loadTier(token: String) async throws -> String? {
        struct Tier: Decodable { var id: String?; var name: String? }
        struct Response: Decodable { var currentTier: Tier?; var paidTier: Tier? }
        let body: [String: Any] = ["metadata": ["ideType": "ANTIGRAVITY", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"]]
        let response: Response = try await post("loadCodeAssist", token: token, body: body)
        switch response.paidTier?.id ?? response.currentTier?.id {
        case "free-tier": return "Free"
        case "standard-tier": return "Pro"
        case "legacy-tier": return "Legacy"
        case let other? where other.contains("pro"): return "Pro"
        case let other? where other.contains("ultra"): return "Ultra"
        case let other?: return other.replacingOccurrences(of: "-tier", with: "").capitalized
        case nil: return nil
        }
    }

    private struct ModelsResponse: Decodable {
        var models: [String: Model]?
    }

    private struct Model: Decodable {
        var displayName: String?
        var modelProvider: String?
        var quotaInfo: QuotaInfo?
    }

    private struct QuotaInfo: Decodable {
        var remainingFraction: Double?
        var resetTime: String?
    }

    struct ModelQuota: Sendable {
        var pool: String
        var window: RateWindow
    }

    static func fetchModels(token: String) async throws -> [ModelQuota] {
        let response: ModelsResponse = try await post("fetchAvailableModels", token: token, body: [:])
        var quotas: [ModelQuota] = []
        for model in (response.models ?? [:]).values {
            guard let fraction = model.quotaInfo?.remainingFraction,
                  let name = model.displayName, !name.isEmpty else { continue }
            quotas.append(ModelQuota(pool: poolName(for: model.modelProvider), window: RateWindow(
                usedPercent: (1 - max(0, min(1, fraction))) * 100,
                resetsAt: model.quotaInfo?.resetTime.flatMap(CodexClient.parseDate),
                windowSeconds: nil,
                title: name
            )))
        }
        var byName: [String: ModelQuota] = [:]
        for quota in quotas {
            let name = quota.window.displayTitle
            if let existing = byName[name], existing.window.leftPercent <= quota.window.leftPercent { continue }
            byName[name] = quota
        }
        return byName.values.sorted { ($0.window.leftPercent, $0.window.displayTitle) < ($1.window.leftPercent, $1.window.displayTitle) }
    }

    private static func poolName(for provider: String?) -> String {
        switch provider {
        case "MODEL_PROVIDER_ANTHROPIC": "Claude"
        case "MODEL_PROVIDER_GOOGLE": "Gemini"
        default: "Other"
        }
    }

    static func pools(from quotas: [ModelQuota]) -> [RateWindow] {
        var pools: [String: RateWindow] = [:]
        for quota in quotas {
            let model = quota.window
            if let existing = pools[quota.pool], existing.leftPercent <= model.leftPercent { continue }
            pools[quota.pool] = RateWindow(usedPercent: model.usedPercent, resetsAt: model.resetsAt, windowSeconds: nil, title: quota.pool)
        }
        let order = ["Gemini", "Claude", "Other"]
        return order.compactMap { pools[$0] }
    }
}
