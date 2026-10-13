import ClaudeUsageData
import Foundation
import Testing
@testable import LiteBar

struct UsageTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func museDecodesBothQuotaWindows() throws {
        let data = Data(#"{"is_subs_active":true,"subs_tier_name":"Muse Code Power Usage","subs_usage":{"window":{"used_percent":28,"window_duration_mins":300,"resets_at":1800018000},"weekly":{"used_percent":65,"resets_at":1800604800}}}"#.utf8)
        let usage = try MuseClient.decodeUsage(data, now: now)
        #expect(usage.plan == "Power Usage")
        #expect(usage.windows.map(\.leftPercent) == [72, 35])
        #expect(usage.windows.map(\.windowSeconds) == [18_000, 604_800])
        #expect(usage.windows.map(\.resetsAt) == [now.addingTimeInterval(18_000), now.addingTimeInterval(604_800)])
        #expect(usage.notice == nil)
    }

    @Test func museDoesNotInventIdleQuota() throws {
        let usage = try MuseClient.decodeUsage(Data(#"{"is_subs_active":true,"subs_tier_name":"Muse Code Power Usage"}"#.utf8), now: now)
        #expect(usage.windows.isEmpty)
        #expect(usage.plan == "Power Usage")
        #expect(usage.notice != nil)
    }

    @Test func museKeepsOverQuotaAndRejectsNegativePercent() throws {
        let usage = try MuseClient.decodeUsage(Data(#"{"is_subs_active":true,"subs_usage":{"window":{"used_percent":125,"window_duration_mins":300}}}"#.utf8), now: now)
        #expect(usage.windows.first?.usedPercent == 125)
        #expect(usage.windows.first?.leftPercent == 0)
        #expect(throws: AppError.self) {
            try MuseClient.decodeUsage(Data(#"{"is_subs_active":true,"subs_usage":{"weekly":{"used_percent":-1}}}"#.utf8))
        }
    }

    @Test func museDoesNotShowLimitsForInactiveBilling() throws {
        for state in [#""is_subs_active":false"#, #""is_subs_active":true,"require_payment":true"#] {
            let usage = try MuseClient.decodeUsage(Data("{\(state),\"subs_usage\":{\"weekly\":{\"used_percent\":12}}}".utf8))
            #expect(usage.windows.isEmpty)
            #expect(usage.notice != nil)
        }
    }

    @Test func claudeIncludesLegacyModelLimits() throws {
        let usage = try ClaudeClient.decodeUsage(Data(#"{"five_hour":{"utilization":10},"seven_day":{"utilization":20},"seven_day_opus":{"utilization":30},"seven_day_sonnet":{"utilization":40}}"#.utf8))
        #expect(usage.windows.map(\.displayTitle) == ["Session", "Weekly", "Opus", "Sonnet"])
        #expect(usage.windows.map(\.leftPercent) == [90, 80, 70, 60])
    }

    @Test func claudeCacheKeepsScopedLimitsAndObservationTime() throws {
        let data = Data(#"{"cachedUsageUtilization":{"fetchedAtMs":1800000000000,"utilization":{"limits":[{"kind":"session","percent":11},{"kind":"weekly_all","percent":22},{"kind":"weekly_scoped","percent":33,"scope":{"model":{"display_name":"Fable"}}}]}}}"#.utf8)
        let usage = try ClaudeClient.decodeCodeCache(data, now: now)
        #expect(usage.windows.map(\.displayTitle) == ["Session", "Weekly", "Fable"])
        #expect(usage.windows.map(\.leftPercent) == [89, 78, 67])
        #expect(usage.capturedAt == now)
    }

    @Test func claudeRejectsMissingAndFutureCache() {
        for json in [#"{}"#, #"{"cachedUsageUtilization":{"fetchedAtMs":1800000061000,"utilization":{"five_hour":{"utilization":20}}}}"#] {
            #expect(throws: AppError.self) { try ClaudeClient.decodeCodeCache(Data(json.utf8), now: now) }
        }
    }

    @Test func claudeUsesNewestLocalObservation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheURL = directory.appendingPathComponent("claude.json")
        let captureURL = directory.appendingPathComponent("capture.json")
        let recent = Date().addingTimeInterval(-60)
        let capture = try #require(try ClaudeCapture.fromStatusLine(Data(#"{"rate_limits":{"five_hour":{"used_percentage":46}}}"#.utf8), now: recent))
        try capture.save(to: captureURL)
        func writeCache(at date: Date) throws {
            try Data("{\"cachedUsageUtilization\":{\"fetchedAtMs\":\(date.timeIntervalSince1970 * 1000),\"utilization\":{\"five_hour\":{\"utilization\":12}}}}".utf8).write(to: cacheURL)
        }
        try writeCache(at: recent.addingTimeInterval(-30))
        #expect(try ClaudeClient.codeUsage(cacheURL: cacheURL, captureURL: captureURL).windows.first?.usedPercent == 46)
        try writeCache(at: recent.addingTimeInterval(30))
        #expect(try ClaudeClient.codeUsage(cacheURL: cacheURL, captureURL: captureURL).windows.first?.usedPercent == 12)
    }

    @Test func providerUpgradeHidesOpenCodeAndAddsMuse() throws {
        let name = "LiteBarTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["codex", "opencode"], forKey: ProviderPreferences.key)
        #expect(ProviderPreferences.enabled(in: defaults) == [.codex, .muse])
        defaults.set(Provider.allCases.map(\.rawValue), forKey: ProviderPreferences.catalogKey)
        #expect(ProviderPreferences.enabled(in: defaults) == [.codex])
    }
}
