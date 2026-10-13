import Foundation

enum LogUsage {
    private struct FileJob: Sendable {
        var url: URL
        var provider: Provider
    }

    static func compute(_ provider: Provider, now: Date = Date()) async throws -> ProviderTotals {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let directory: URL
        switch provider {
        case .codex: directory = home.appendingPathComponent(".codex/sessions")
        case .claude: directory = home.appendingPathComponent(".claude/projects")
        case .opencode: return try OpenCodeClient.localTotals(now: now)
        case .antigravity: throw AppError("Antigravity keeps conversations in a binary format LiteBar does not read.")
        case .muse: throw AppError("Muse subscription usage comes from Meta, rather than local token totals.")
        }
        let jobs = collectFiles(directory: directory, provider: provider, now: now)

        var totals = ProviderTotals(computedAt: now)
        await withTaskGroup(of: ProviderTotals.self) { group in
            for job in jobs {
                group.addTask { scanJob(job, now: now) }
            }
            for await part in group {
                totals.tokens24h += part.tokens24h
                totals.tokens30d += part.tokens30d
                totals.lineCount += part.lineCount
            }
        }
        return totals
    }

    private static func scanJob(_ job: FileJob, now: Date) -> ProviderTotals {
        var bucket = Bucket(now: now)
        switch job.provider {
        case .codex: scanCodexFile(job.url, buckets: &bucket)
        case .claude: scanClaudeFile(job.url, buckets: &bucket)
        case .antigravity, .muse, .opencode: break
        }
        return bucket.totals()
    }

    private static func collectFiles(directory: URL, provider: Provider, now: Date) -> [FileJob] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let cutoff = now.addingTimeInterval(-31 * 24 * 3600)
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var jobs: [FileJob] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { continue }
            if let modified = values?.contentModificationDate, modified < cutoff { continue }
            jobs.append(FileJob(url: url, provider: provider))
        }
        return jobs
    }

    private static func withLines(_ url: URL, marker: Data, visit: (Data) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        let chunkSize = 1 << 20
        var carry = Data()

        while let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty {
            let buffer = carry.isEmpty ? chunk : carry + chunk
            let count = buffer.count

            var markers: [Int] = []
            var searchFrom = 0
            while let position = memmemIndex(buffer, needle: marker, from: searchFrom) {
                markers.append(position)
                searchFrom = position + 1
            }

            var segmentStart = 0
            var markerIndex = 0
            while let newline = memchrIndex(buffer, from: segmentStart, byte: 0x0A) {
                defer { segmentStart = newline + 1 }
                while markerIndex < markers.count, markers[markerIndex] < segmentStart {
                    markerIndex += 1
                }
                guard markerIndex < markers.count, markers[markerIndex] < newline, segmentStart < newline else { continue }
                visit(Data(buffer[segmentStart..<newline]))
                while markerIndex < markers.count, markers[markerIndex] < newline {
                    markerIndex += 1
                }
            }
            carry = count > segmentStart ? Data(buffer[segmentStart...]) : Data()
        }
        if !carry.isEmpty, contains(carry, marker) {
            visit(Data(carry))
        }
    }

    private static func memchrIndex(_ data: Data, from offset: Int, byte: UInt8) -> Int? {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int? in
            guard var base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self), offset < raw.count else { return nil }
            base += offset
            guard let hit = memchr(base, Int32(byte), raw.count - offset) else { return nil }
            return offset + base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
        }
    }

    private static func memmemIndex(_ data: Data, needle: Data, from offset: Int) -> Int? {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int? in
            needle.withUnsafeBytes { (ned: UnsafeRawBufferPointer) -> Int? in
                guard var base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let nedBase = ned.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      !ned.isEmpty, offset + ned.count <= raw.count else { return nil }
                base += offset
                guard let hit = memmem(base, raw.count - offset, nedBase, ned.count) else { return nil }
                return offset + base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
            }
        }
    }

    private static func contains(_ data: Data, _ needle: Data) -> Bool {
        data.withUnsafeBytes { hay -> Bool in
            guard let hayBase = hay.baseAddress, hay.count > 0 else { return false }
            return needle.withUnsafeBytes { ned -> Bool in
                guard let nedBase = ned.baseAddress, ned.count > 0, ned.count <= hay.count else { return false }
                return memmem(hayBase, hay.count, nedBase, ned.count) != nil
            }
        }
    }

    private static func scanCodexFile(_ url: URL, buckets: inout Bucket) {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        let marker = Data("token_count".utf8)

        withLines(url, marker: marker) { line in
            guard let object = Self.parseJSON(line) else { return }
            guard Self.typePath(object) == "event_msg.token_count" else { return }
            guard let payload = object["payload"] as? [String: Any],
                  let info = payload["info"] as? [String: Any],
                  let totals = info["total_token_usage"] as? [String: Any],
                  let total = (totals["total_tokens"] as? NSNumber)?.intValue else { return }
            let delta = (info["last_token_usage"] as? [String: Any])
                .flatMap { ($0["total_tokens"] as? NSNumber)?.intValue }
            let timestamp = (object["timestamp"] as? String).flatMap(CodexClient.parseDate) ?? modified
            let tokens = delta ?? total
            buckets.add(tokens, at: timestamp)
        }
    }

    private static func scanClaudeFile(_ url: URL, buckets: inout Bucket) {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        let marker = Data("\"usage\"".utf8)

        withLines(url, marker: marker) { line in
            guard let object = Self.parseJSON(line) else { return }
            guard object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { return }

            func int(_ key: String) -> Int {
                (usage[key] as? NSNumber)?.intValue ?? 0
            }
            let total = int("input_tokens")
                + int("cache_creation_input_tokens")
                + int("cache_read_input_tokens")
                + int("output_tokens")
            let timestamp = (object["timestamp"] as? String).flatMap(CodexClient.parseDate) ?? modified
            buckets.add(total, at: timestamp)
        }
    }

    private static func parseJSON(_ data: Data) -> [String: Any]? {
        guard data.first == UInt8(ascii: "{") else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func typePath(_ object: [String: Any]) -> String {
        let type = object["type"] as? String ?? ""
        let payloadType = (object["payload"] as? [String: Any])?["type"] as? String ?? ""
        return payloadType.isEmpty ? type : "\(type).\(payloadType)"
    }

    private struct Bucket {
        var tokens24h = 0
        var tokens30d = 0
        var lines = 0
        var now: Date

        mutating func add(_ tokens: Int, at date: Date?) {
            guard tokens > 0 else { return }
            lines += 1
            tokens30d += tokens
            if let date = date, now.timeIntervalSince(date) <= 24 * 3600 {
                tokens24h += tokens
            }
        }

        func totals() -> ProviderTotals {
            ProviderTotals(tokens24h: tokens24h, tokens30d: tokens30d, lineCount: lines)
        }
    }
}
