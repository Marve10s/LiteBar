import Foundation
import LocalAuthentication
import Security

enum MuseClient {
    struct Usage: Sendable {
        var plan: String?
        var windows: [RateWindow]
        var notice: String?
        var fetchedAt: Date
    }

    static let session = Session()

    actor Session {
        private var cached: Usage?
        private var cachedToken: String?

        func usage() async throws -> Usage {
            let token = try MuseClient.accessToken()
            if let cached, cachedToken == token, Date().timeIntervalSince(cached.fetchedAt) < 300 { return cached }
            let usage = try await MuseClient.fetchUsage(token: token)
            cached = usage
            cachedToken = token
            return usage
        }
    }

    static func accessToken(authURL: URL = authURL) throws -> String {
        struct Auth: Decodable {
            struct Credential: Decodable {
                var mechanism: String?
                var storage: String?
                var access_token: String?
            }
            var providers: [String: Credential]
        }
        guard let data = try? Data(contentsOf: authURL) else {
            throw AppError("Muse Code is not signed in. Run muse login, then refresh LiteBar.")
        }
        guard let auth = try? JSONDecoder().decode(Auth.self, from: data),
              let credential = auth.providers["meta"] else {
            throw AppError("Could not read the Muse Code login. Run muse login again.")
        }
        guard credential.mechanism == "oauth" else {
            throw AppError("Muse subscription limits need an account login. Run muse login; API keys do not report plan limits.")
        }
        if let token = credential.access_token, !token.isEmpty { return token }
        guard credential.storage == "keychain" else {
            throw AppError("Muse Code has no saved account token. Run muse login again.")
        }
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ai.meta.dev.credentials",
            kSecAttrAccount as String: "meta",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw AppError("Muse Code's Keychain login is unavailable (\(status)). Unlock your Mac and allow LiteBar to read it in Keychain Access.")
        }
        struct Secret: Decodable { var access_token: String? }
        guard let secret = try? JSONDecoder().decode(Secret.self, from: data),
              let token = secret.access_token, !token.isEmpty else {
            throw AppError("Muse Code's saved login has no account token. Run muse login again.")
        }
        return token
    }

    static var authURL: URL {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["MUSE_AUTH_PATH"], !path.isEmpty { return URL(fileURLWithPath: path) }
        let config = environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return config.appendingPathComponent("muse/auth.json")
    }

    static func fetchUsage(token: String, session: URLSession = HTTPClient.session) async throws -> Usage {
        var request = URLRequest(url: URL(string: "https://api.meta.ai/muse-code/key")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("1.0.0", forHTTPHeaderField: "X-Api-Version")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("litebar/0.4", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppError("No Muse response") }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw AppError("Muse rejected the saved login (HTTP \(http.statusCode)). Run muse login again.")
        }
        if http.statusCode == 429 {
            throw AppError("Muse usage is temporarily rate limited. Wait five minutes before refreshing.")
        }
        guard (200..<300).contains(http.statusCode) else { throw AppError("Muse API HTTP \(http.statusCode)") }
        return try decodeUsage(data)
    }

    static func decodeUsage(_ data: Data, now: Date = Date()) throws -> Usage {
        struct Window: Decodable {
            var used_percent: Double
            var resets_at: Double?
            var window_duration_mins: Double?
        }
        struct Subscription: Decodable {
            var window: Window?
            var weekly: Window?
        }
        struct Body: Decodable {
            var is_subs_active: Bool
            var require_payment: Bool?
            var subs_tier_name: String?
            var subs_usage: Subscription?
        }
        let body = try JSON.decode(Body.self, from: data)
        var usage = Usage(plan: body.subs_tier_name?.replacingOccurrences(of: "Muse Code ", with: ""),
                          windows: [], fetchedAt: now)
        if body.require_payment == true {
            usage.notice = "Complete Muse Code billing to view subscription limits."
            return usage
        }
        if body.is_subs_active == false {
            usage.notice = "No active Muse Code subscription reported."
            return usage
        }
        for (window, title, duration) in [(body.subs_usage?.window, "Session", 18_000.0),
                                           (body.subs_usage?.weekly, "Weekly", 604_800.0)] {
            guard let window else { continue }
            guard window.used_percent.isFinite, window.used_percent >= 0,
                  window.resets_at.map({ $0.isFinite && $0 > 0 }) != false,
                  window.window_duration_mins.map({ $0.isFinite && $0 > 0 }) != false else {
                throw AppError("Muse reported an invalid usage window.")
            }
            usage.windows.append(RateWindow(usedPercent: window.used_percent,
                                            resetsAt: window.resets_at.map { Date(timeIntervalSince1970: $0) },
                                            windowSeconds: title == "Session" ? (window.window_duration_mins.map { $0 * 60 } ?? duration) : duration,
                                            title: title))
        }
        if usage.windows.isEmpty {
            usage.notice = "Meta has not reported quota figures yet. Use Muse Code, then refresh; reads are cached for five minutes."
        }
        return usage
    }
}
