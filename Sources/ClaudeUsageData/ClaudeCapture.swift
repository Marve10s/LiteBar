import Foundation

public struct ClaudeCapture: Codable, Equatable, Sendable {
    public struct Window: Codable, Equatable, Sendable {
        public let usedPercentage: Double
        public let resetsAt: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercentage = "used_percentage"
            case resetsAt = "resets_at"
        }

        var isValid: Bool {
            usedPercentage.isFinite && (0...100).contains(usedPercentage)
                && (resetsAt == nil || (resetsAt!.isFinite && resetsAt! > 0))
        }
    }

    public let capturedAt: Date
    public let fiveHour: Window?
    public let sevenDay: Window?

    public static var fileURL: URL {
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/dev.ibrahime.LiteBar/claude-usage.json")
    }

    public static func fromStatusLine(_ data: Data, now: Date = Date()) throws -> Self? {
        struct Payload: Decodable {
            struct Limits: Decodable {
                var five_hour: Window?
                var seven_day: Window?
            }
            var rate_limits: Limits?
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let limits = payload.rate_limits else { return nil }
        let five = limits.five_hour.flatMap { $0.isValid ? $0 : nil }
        let seven = limits.seven_day.flatMap { $0.isValid ? $0 : nil }
        guard five != nil || seven != nil else { return nil }
        return Self(capturedAt: now, fiveHour: five, sevenDay: seven)
    }

    public static func read(from url: URL = fileURL) throws -> Self {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: 16_385) ?? Data()
        guard data.count <= 16_384 else { throw CocoaError(.fileReadCorruptFile) }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.capturedAt.timeIntervalSince1970.isFinite,
              value.capturedAt <= Date().addingTimeInterval(60),
              value.fiveHour != nil || value.sevenDay != nil,
              value.fiveHour?.isValid != false, value.sevenDay?.isValid != false else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return value
    }

    @discardableResult
    public func save(to url: URL = fileURL) throws -> Bool {
        if let old = try? Self.read(from: url),
           old.fiveHour == fiveHour, old.sevenDay == sevenDay { return false }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                               withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return true
    }

    public var statusText: String {
        var parts = ["Claude"]
        if let fiveHour { parts.append("5h: \(Int(fiveHour.usedPercentage.rounded()))% used") }
        if let sevenDay { parts.append("weekly: \(Int(sevenDay.usedPercentage.rounded()))% used") }
        return parts.joined(separator: " · ")
    }
}
