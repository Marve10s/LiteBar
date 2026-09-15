import Foundation
import SQLite3

enum OpenCodeClient {
    struct Usage: Sendable {
        var windows: [RateWindow]
    }

    static var dataDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode")
    }

    static func apiKey() throws -> String {
        let url = dataDirectory.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: url) else {
            throw AppError("OpenCode is not signed in — no ~/.local/share/opencode/auth.json.")
        }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let entry = object?["opencode-go"] as? [String: Any],
              let key = entry["key"] as? String, !key.isEmpty else {
            throw AppError("No OpenCode Go key in auth.json — run `opencode auth login` and pick OpenCode Go.")
        }
        return key
    }

    static func usage() async throws -> Usage {
        var request = URLRequest(url: URL(string: "https://opencode.ai/zen/go/v1/usage")!)
        request.setValue("Bearer \(try apiKey())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("LiteBar", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await HTTPClient.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: break
        case 401, 403: throw AppError("OpenCode Go key was rejected — sign in again with `opencode auth login`.")
        default: throw AppError("OpenCode Go usage endpoint returned HTTP \(status).")
        }

        struct Window: Decodable {
            var percent: Double?
            var resetsAt: String?
        }
        struct Body: Decodable {
            struct Usage: Decodable {
                var rolling: Window?
                var weekly: Window?
                var monthly: Window?
            }
            var usage: Usage?
        }
        let body = try JSONDecoder().decode(Body.self, from: data)
        let windows: [RateWindow] = [
            (body.usage?.rolling, "Session", 5.0 * 3600),
            (body.usage?.weekly, "Weekly", 7.0 * 86_400),
            (body.usage?.monthly, "Monthly", 30.0 * 86_400),
        ].compactMap { window, title, seconds in
            guard let window, let percent = window.percent else { return nil }
            return RateWindow(
                usedPercent: percent,
                resetsAt: window.resetsAt.flatMap(CodexClient.parseDate),
                windowSeconds: seconds,
                title: title
            )
        }
        guard !windows.isEmpty else { throw AppError("OpenCode Go returned no usage windows.") }
        return Usage(windows: windows)
    }

    struct ModelGroup: Sendable, Equatable, Identifiable {
        var id: String
        var title: String
        var models: [Model]
    }

    struct Model: Sendable, Equatable, Identifiable {
        var id: String
        var name: String
        var priceLine: String
    }

    static func modelCatalog() throws -> [ModelGroup] {
        let catalogURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/opencode/models.json")
        guard let data = try? Data(contentsOf: catalogURL, options: .alwaysMapped) else {
            throw AppError("No model catalog at ~/.cache/opencode/models.json — run OpenCode once to populate it.")
        }
        guard let catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError("Unrecognised OpenCode model catalog.")
        }
        let authURL = dataDirectory.appendingPathComponent("auth.json")
        let connected: [String] = (try? Data(contentsOf: authURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .map { Array($0.keys) } ?? []

        var groups: [ModelGroup] = []
        if connected.contains("opencode-go") {
            groups.append(group("opencode-go", title: "OpenCode Go", in: catalog, filter: { _ in true }))
        }
        groups.append(group("opencode", title: "OpenCode Zen · free", in: catalog, filter: isFree))
        for providerID in connected.sorted() where providerID != "opencode-go" {
            let title = (catalog[providerID] as? [String: Any])?["name"] as? String ?? providerID
            groups.append(group(providerID, title: title, in: catalog, filter: { _ in true }))
        }
        return groups.filter { !$0.models.isEmpty }
    }

    private static func isFree(_ model: [String: Any]) -> Bool {
        guard let cost = model["cost"] as? [String: Any] else { return false }
        let input = (cost["input"] as? NSNumber)?.doubleValue ?? 1
        let output = (cost["output"] as? NSNumber)?.doubleValue ?? 1
        return input == 0 && output == 0
    }

    private static func group(_ providerID: String, title: String, in catalog: [String: Any], filter: ([String: Any]) -> Bool) -> ModelGroup {
        let entries = (catalog[providerID] as? [String: Any])?["models"] as? [String: [String: Any]] ?? [:]
        let models = entries.compactMap { id, model -> Model? in
            guard model["status"] as? String != "deprecated", filter(model) else { return nil }
            let name = model["name"] as? String ?? id
            return Model(id: "\(providerID)/\(id)", name: name, priceLine: priceLine(model))
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return ModelGroup(id: providerID, title: title, models: models)
    }

    private static func priceLine(_ model: [String: Any]) -> String {
        guard let cost = model["cost"] as? [String: Any],
              let input = (cost["input"] as? NSNumber)?.doubleValue,
              let output = (cost["output"] as? NSNumber)?.doubleValue else { return "" }
        if input == 0, output == 0 { return "Free" }
        func format(_ value: Double) -> String {
            value < 1 ? String(format: "$%.2f", value) : String(format: "$%g", value)
        }
        return "\(format(input)) / \(format(output)) per M"
    }

    static func localTotals(now: Date = Date()) throws -> ProviderTotals {
        let url = dataDirectory.appendingPathComponent("opencode.db")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AppError("No OpenCode database at ~/.local/share/opencode/opencode.db.")
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw AppError("Could not open opencode.db: \(message)")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        let sql = """
            SELECT CAST(COALESCE(json_extract(data, '$.time.created'), time_created) AS INTEGER),
                   COALESCE(json_extract(data, '$.tokens.input'), 0)
                   + COALESCE(json_extract(data, '$.tokens.output'), 0)
                   + COALESCE(json_extract(data, '$.tokens.reasoning'), 0)
                   + COALESCE(json_extract(data, '$.tokens.cache.read'), 0)
                   + COALESCE(json_extract(data, '$.tokens.cache.write'), 0)
            FROM message
            WHERE time_created >= ?1 AND json_extract(data, '$.role') = 'assistant'
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw AppError("opencode.db query failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(statement) }
        let dayMs = 86_400_000.0
        let nowMs = now.timeIntervalSince1970 * 1000
        sqlite3_bind_int64(statement, 1, Int64(nowMs - 30 * dayMs))

        var totals = ProviderTotals(computedAt: now)
        while sqlite3_step(statement) == SQLITE_ROW {
            let createdMs = Double(sqlite3_column_int64(statement, 0))
            let tokens = Int(sqlite3_column_int64(statement, 1))
            guard tokens > 0 else { continue }
            totals.lineCount += 1
            totals.tokens30d += tokens
            if nowMs - createdMs <= dayMs { totals.tokens24h += tokens }
        }
        return totals
    }
}
