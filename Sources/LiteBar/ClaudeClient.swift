import Foundation
import ClaudeUsageData

struct AppError: Error, LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum JSON {
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw AppError("Unexpected response shape: \(error.localizedDescription)")
        }
    }
}

enum ClaudeClient {
    struct Usage: Sendable, Equatable {
        var windows: [RateWindow]
        var accountSummary: String?
        var capturedAt: Date?
    }

    static func usage(mode: ClaudeUsageMode = .current) async throws -> Usage {
        if mode == .local {
            let capture: ClaudeCapture
            do { capture = try ClaudeCapture.read() }
            catch CocoaError.fileReadNoSuchFile {
                throw AppError("No captured limits yet. Use Claude Code after enabling capture in Settings.")
            }
            func window(_ value: ClaudeCapture.Window?, title: String) -> RateWindow? {
                value.map { RateWindow(usedPercent: $0.usedPercentage,
                                       resetsAt: $0.resetsAt.map { Date(timeIntervalSince1970: $0) },
                                       title: title) }
            }
            return Usage(windows: [window(capture.fiveHour, title: "Session"),
                                   window(capture.sevenDay, title: "Weekly")].compactMap { $0 },
                         accountSummary: "Local capture", capturedAt: capture.capturedAt)
        }
        let token = try await ClaudeOAuth.session.accessToken()
        do {
            return try await fetchUsage(token: token)
        } catch is Unauthorized {
            let fresh = try await ClaudeOAuth.session.accessToken(rejectedToken: token)
            do { return try await fetchUsage(token: fresh) }
            catch is Unauthorized {
                try await ClaudeOAuth.session.reject(fresh)
                throw AppError("Claude rejected the renewed sign-in. Reconnect Claude in Settings.")
            }
        }
    }

    private struct Unauthorized: Error {}

    static func fetchUsage(token: String, session: URLSession = HTTPClient.session) async throws -> Usage {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("litebar/0.3", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppError("No response") }
        if http.statusCode == 401 { throw Unauthorized() }
        guard (200..<300).contains(http.statusCode) else {
            throw AppError("Claude API HTTP \(http.statusCode)")
        }
        return try decodeUsage(data)
    }

    static func decodeUsage(_ data: Data) throws -> Usage {
        struct ModelScope: Decodable {
            var display_name: String?
        }
        struct Scope: Decodable {
            var model: ModelScope?
        }
        struct Limit: Decodable {
            var kind: String?
            var percent: Double?
            var resets_at: String?
            var scope: Scope?
        }
        struct Bucket: Decodable {
            var utilization: Double?
            var resets_at: String?
        }
        struct Body: Decodable {
            var five_hour: Bucket?
            var seven_day: Bucket?
            var limits: [Limit]?
        }

        let body = try JSON.decode(Body.self, from: data)

        var windows: [RateWindow] = []
        for limit in body.limits ?? [] {
            guard let percent = limit.percent, let kind = limit.kind else { continue }
            let title: String
            switch kind {
            case "session": title = "Session"
            case "weekly_all": title = "Weekly"
            case "weekly_scoped": title = limit.scope?.model?.display_name ?? "Scoped weekly"
            default: title = kind.capitalized
            }
            windows.append(RateWindow(
                usedPercent: percent,
                resetsAt: limit.resets_at.flatMap(CodexClient.parseDate),
                windowSeconds: nil,
                title: title
            ))
        }

        if windows.isEmpty {
            func map(_ bucket: Bucket?, title: String) -> RateWindow? {
                guard let bucket = bucket, let utilization = bucket.utilization else { return nil }
                return RateWindow(
                    usedPercent: utilization,
                    resetsAt: bucket.resets_at.flatMap(CodexClient.parseDate),
                    windowSeconds: nil,
                    title: title
                )
            }
            windows = [map(body.five_hour, title: "Session"), map(body.seven_day, title: "Weekly")].compactMap(\.self)
        }

        return Usage(windows: windows, accountSummary: nil)
    }
}
