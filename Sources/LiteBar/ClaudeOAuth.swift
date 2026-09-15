import CryptoKit
import Foundation
import Security
import LocalAuthentication

enum ClaudeUsageMode: String, CaseIterable {
    case live
    case local

    static let key = "claudeUsageMode"
    static var current: Self {
        UserDefaults.standard.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .live
    }
    var label: String { self == .live ? "Live limits" : "Local capture" }
}

enum ClaudeOAuth {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let redirectURI = "https://platform.claude.com/oauth/code/callback"
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!

    struct Credentials: Codable, Sendable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
        var requiresSignIn = false
    }

    struct Authorization: Sendable {
        let verifier: String
        let state: String

        init() throws {
            func random() throws -> String {
                var bytes = [UInt8](repeating: 0, count: 32)
                guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                    throw AppError("Could not start secure sign-in. Try again.")
                }
                return ClaudeOAuth.base64URL(Data(bytes))
            }
            verifier = try random()
            state = try random()
        }

        var url: URL {
            var components = URLComponents(string: "https://claude.com/cai/oauth/authorize")!
            components.queryItems = [
                URLQueryItem(name: "code", value: "true"),
                URLQueryItem(name: "client_id", value: clientID),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "redirect_uri", value: redirectURI),
                URLQueryItem(name: "scope", value: "user:profile"),
                URLQueryItem(name: "code_challenge", value: ClaudeOAuth.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "state", value: state),
            ]
            return components.url!
        }

        func request(code pastedCode: String) throws -> URLRequest {
            let parts = pastedCode.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "#", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, parts[1] == state else {
                throw AppError("Paste the complete code from this sign-in attempt, including the part after #.")
            }
            return try ClaudeOAuth.request([
                "grant_type": "authorization_code", "code": String(parts[0]),
                "state": state, "code_verifier": verifier, "redirect_uri": redirectURI,
            ])
        }
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func request(_ fields: [String: String]) throws -> URLRequest {
        var fields = fields
        fields["client_id"] = clientID
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: fields)
        return request
    }

    static func decode(_ data: Data, previousRefreshToken: String? = nil, now: Date = Date()) throws -> Credentials {
        struct Response: Decodable {
            var access_token: String
            var refresh_token: String?
            var expires_in: Double
            var scope: String?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        let refreshToken = response.refresh_token ?? previousRefreshToken ?? ""
        guard !response.access_token.isEmpty, !refreshToken.isEmpty,
              response.expires_in.isFinite, response.expires_in > 0 else {
            throw AppError("Claude did not return a renewable sign-in. Reconnect in Settings.")
        }
        if let scope = response.scope, !scope.split(separator: " ").contains("user:profile") {
            throw AppError("This sign-in cannot read Claude usage. Connect with profile access.")
        }
        return Credentials(accessToken: response.access_token, refreshToken: refreshToken,
                           expiresAt: now.addingTimeInterval(response.expires_in))
    }

    static func isRevoked(_ data: Data, status: Int) -> Bool {
        struct Failure: Decodable { var error: String? }
        return (status == 400 || status == 401)
            && (try? JSONDecoder().decode(Failure.self, from: data).error) == "invalid_grant"
    }

    static let session = Session()

    actor Session {
        typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
        private let load: @Sendable () throws -> Credentials?
        private let save: @Sendable (Credentials) throws -> Void
        private let transport: Transport
        private var cached: Credentials?
        private var loaded = false
        private var renewal: Task<Credentials, Error>?
        private var generation = 0
        private var needsSave = false

        init(load: @escaping @Sendable () throws -> Credentials? = Keychain.load,
             save: @escaping @Sendable (Credentials) throws -> Void = Keychain.save,
             transport: @escaping Transport = { try await HTTPClient.session.data(for: $0) }) {
            self.load = load
            self.save = save
            self.transport = transport
        }

        func connect(_ authorization: Authorization, code: String) async throws {
            let request = try authorization.request(code: code)
            generation += 1
            let version = generation
            renewal?.cancel()
            renewal = nil
            let (data, response) = try await transport(request)
            guard version == generation else { throw CancellationError() }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw AppError("Claude sign-in was not accepted (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)). Start a new sign-in.")
            }
            let credentials = try ClaudeOAuth.decode(data)
            cached = credentials
            loaded = true
            needsSave = true
            try persist()
        }

        func accessToken(rejectedToken: String? = nil) async throws -> String {
            if !loaded {
                cached = try load()
                loaded = true
            }
            try persist()
            guard let credentials = cached, !credentials.requiresSignIn else {
                throw AppError("Connect Claude once in Settings for automatically renewed live limits, or choose Local capture.")
            }
            if credentials.expiresAt > Date(), credentials.accessToken != rejectedToken {
                return credentials.accessToken
            }
            if let renewal { return try await renewal.value.accessToken }
            let version = generation
            let task = Task { try await self.renew(credentials, version: version) }
            renewal = task
            defer { if generation == version { renewal = nil } }
            return try await task.value.accessToken
        }

        private func renew(_ credentials: Credentials, version: Int) async throws -> Credentials {
            do {
                let request = try ClaudeOAuth.request(["grant_type": "refresh_token", "refresh_token": credentials.refreshToken])
                let (data, response) = try await transport(request)
                try Task.checkCancellation()
                guard generation == version else { throw CancellationError() }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if ClaudeOAuth.isRevoked(data, status: status) { throw SignInRevoked() }
                guard status == 200 else { throw AppError("Claude renewal failed (HTTP \(status)). Try refreshing again.") }
                let fresh = try ClaudeOAuth.decode(data, previousRefreshToken: credentials.refreshToken)
                cached = fresh
                needsSave = true
                try persist()
                return fresh
            } catch {
                guard generation == version else { throw CancellationError() }
                if error is SignInRevoked {
                    cached?.requiresSignIn = true
                    needsSave = true
                    try persist()
                    throw AppError("Claude revoked this sign-in. Reconnect Claude in Settings.")
                }
                throw error
            }
        }

        private func persist() throws {
            guard needsSave, let cached else { return }
            try save(cached)
            needsSave = false
        }

        func reject(_ token: String) throws {
            guard cached?.accessToken == token else { return }
            cached?.requiresSignIn = true
            needsSave = true
            try persist()
        }
    }

    private struct SignInRevoked: Error {}

    enum Keychain {
        private static var query: [String: Any] { [
            kSecClass as String: kSecClassGenericPassword as String,
            kSecAttrService as String: "dev.ibrahime.LiteBar.claude",
            kSecAttrAccount as String: "usage",
        ] }

        static func load() throws -> Credentials? {
            var query = query
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne as String
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = result as? Data else {
                throw AppError("LiteBar's Claude sign-in is unavailable in Keychain (\(status)). Unlock your Mac and retry.")
            }
            return try JSONDecoder().decode(Credentials.self, from: data)
        }

        static func save(_ credentials: Credentials) throws {
            let data = try JSONEncoder().encode(credentials)
            var status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
            if status == errSecItemNotFound {
                var item = query
                item[kSecValueData as String] = data
                item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
                status = SecItemAdd(item as CFDictionary, nil)
            }
            guard status == errSecSuccess else {
                throw AppError("Could not save LiteBar's Claude sign-in in Keychain (\(status)). Unlock your Mac and retry.")
            }
        }
    }
}
