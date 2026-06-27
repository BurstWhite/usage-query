import Foundation
@testable import UsageQueryCore

@main
struct UsageQueryCoreTestRunner {
    static func main() throws {
        let tests = UsageQueryCoreTests()
        try tests.claudeParserUsesAuthoritativeUsageWhenPresent()
        try tests.claudeParserEstimatesMissingUsageWithoutDuplicatingAuthoritativeEvents()
        try tests.codexParserReadsSessionTokenCounts()
        try tests.cacheDoesNotPersistConversationText()
        try tests.aggregationSummarizesProviderUsage()
        try tests.aggregationInfersCodexRollingLimits()
        try tests.aggregationIgnoresExpiredCodexRateLimitSnapshots()
        print("UsageQueryCoreTests passed")
    }
}

struct UsageQueryCoreTests {
    func claudeParserUsesAuthoritativeUsageWhenPresent() throws {
        let home = try temporaryHome()
        let project = home.appendingPathComponent(".claude/projects/test")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("session.jsonl")
        let line = """
        {"type":"assistant","timestamp":"2026-06-25T02:00:00.000Z","sessionId":"s1","uuid":"u1","message":{"id":"m1","role":"assistant","model":"claude-sonnet-4-6","content":[{"type":"text","text":"do not store this"}],"usage":{"input_tokens":100,"output_tokens":25,"cache_read_input_tokens":10,"cache_creation_input_tokens":5}}}
        """
        try line.write(to: file, atomically: true, encoding: .utf8)

        let events = try ClaudeUsageProvider(homeDirectory: home).scanLocal(since: nil)

        try expect(events.count == 1, "expected one Claude event")
        let event = try require(events.first, "missing Claude event")
        try expect(event.confidence == .authoritative, "expected authoritative confidence")
        try expect(event.source == .localUsageLog, "expected local usage source")
        try expect(event.inputTokens == 100, "expected input tokens")
        try expect(event.outputTokens == 25, "expected output tokens")
        try expect(event.cacheReadTokens == 10, "expected cache read tokens")
        try expect(event.cacheWriteTokens == 5, "expected cache write tokens")
        try expect(event.totalTokens == 140, "expected total tokens")
    }

    func claudeParserEstimatesMissingUsageWithoutDuplicatingAuthoritativeEvents() throws {
        let home = try temporaryHome()
        let project = home.appendingPathComponent(".claude/projects/test")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("session.jsonl")
        let lines = [
            #"{"type":"user","timestamp":"2026-06-25T02:00:00.000Z","sessionId":"s1","uuid":"u1","message":{"role":"user","content":[{"type":"text","text":"please summarize the repository"}]}}"#,
            #"{"type":"assistant","timestamp":"2026-06-25T02:01:00.000Z","sessionId":"s1","uuid":"u2","message":{"id":"m2","role":"assistant","model":"claude-sonnet-4-6","content":[{"type":"text","text":"summary"}],"usage":{"input_tokens":30,"output_tokens":7}}}"#
        ].joined(separator: "\n")
        try lines.write(to: file, atomically: true, encoding: .utf8)

        let events = try ClaudeUsageProvider(homeDirectory: home).scanLocal(since: nil)

        try expect(events.count == 2, "expected two Claude events")
        try expect(events.filter { $0.confidence == .estimated }.count == 1, "expected one estimated event")
        try expect(events.filter { $0.confidence == .authoritative }.count == 1, "expected one authoritative event")
        try expect((events.first { $0.confidence == .estimated }?.inputTokens ?? 0) > 0, "expected estimated input tokens")
    }

    func codexParserReadsSessionTokenCounts() throws {
        let home = try temporaryHome()
        let sessionDirectory = home.appendingPathComponent(".codex/sessions/2026/06/25")
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let file = sessionDirectory.appendingPathComponent("rollout-2026-06-25T15-22-23-019eff5e-8ebe-7242-890b-78e2c38a8860.jsonl")
        let lines = [
            #"{"timestamp":"2026-06-25T15:22:20.000Z","type":"event_msg","payload":{"type":"turn_context","model":"gpt-5.5"}}"#,
            #"{"timestamp":"2026-06-25T15:22:23.868Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":202919,"cached_input_tokens":167936,"output_tokens":2268,"reasoning_output_tokens":182,"total_tokens":205187},"last_token_usage":{"input_tokens":35268,"cached_input_tokens":32640,"output_tokens":537,"reasoning_output_tokens":93,"total_tokens":35805},"model_context_window":258400},"rate_limits":{"limit_id":"codex","primary":{"used_percent":57.0,"window_minutes":300,"resets_at":1782417450},"secondary":{"used_percent":25.0,"window_minutes":10080,"resets_at":1782959939},"plan_type":"plus","rate_limit_reached_type":null}}}"#
        ].joined(separator: "\n")
        try lines.write(to: file, atomically: true, encoding: .utf8)

        let provider = CodexUsageProvider(homeDirectory: home)
        let events = try provider.scanLocal(since: nil)
        let snapshots = try provider.scanRateLimitSnapshots(since: nil)

        try expect(events.count == 1, "expected one Codex session token event")
        let event = try require(events.first, "missing Codex session token event")
        try expect(event.sessionId == "019eff5e-8ebe-7242-890b-78e2c38a8860", "expected session id from rollout filename")
        try expect(event.model == "gpt-5.5", "expected session model")
        try expect(event.inputTokens == 35268, "expected session input tokens")
        try expect(event.cacheReadTokens == 32640, "expected session cached tokens")
        try expect(event.outputTokens == 537, "expected session output tokens")
        try expect(event.totalTokens == 35805, "expected session total tokens")

        let fiveHours = try require(snapshots.first { $0.window == .fiveHours }, "missing session 5h snapshot")
        let sevenDays = try require(snapshots.first { $0.window == .sevenDays }, "missing session 7 days snapshot")
        try expect(fiveHours.usedPercent == 57, "expected session 5h used percent")
        try expect(sevenDays.usedPercent == 25, "expected session 7 days used percent")
        try expect(fiveHours.planType == "plus", "expected session plan type")
    }


    func cacheDoesNotPersistConversationText() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let cacheURL = temp.appendingPathComponent("cache.sqlite")
        let cache = try UsageCache(path: cacheURL.path)
        let secret = "NEVER_STORE_THIS_PROMPT"
        let record = ConversationRecord(
            provider: .claude,
            timestamp: Date(timeIntervalSince1970: 1_782_364_800),
            sessionId: "session",
            messageId: "message",
            model: "claude-sonnet-4-6",
            role: "user",
            contentText: secret
        )
        let event = try require(ClaudeUsageProvider(homeDirectory: temp).estimateFromConversation(record), "missing estimated event")

        try cache.replaceEvents([event])

        let data = try Data(contentsOf: cacheURL)
        let raw = String(data: data, encoding: .utf8) ?? ""
        try expect(!raw.contains(secret), "cache persisted raw conversation text")
        try expect(try cache.loadEvents().count == 1, "expected cached event")
    }

    func aggregationSummarizesProviderUsage() throws {
        let now = Date(timeIntervalSince1970: 1_782_364_800)
        let events = [
            UsageEvent(
                provider: .codex,
                source: .localUsageLog,
                timestamp: now,
                sessionId: "s",
                requestId: "r",
                model: "gpt",
                inputTokens: 40,
                cacheReadTokens: 10,
                cacheWriteTokens: 0,
                outputTokens: 50,
                confidence: .authoritative
            )
        ]

        let summary = UsageAggregator.summarize(
            events: events,
            period: .today,
            now: now,
            calendar: Calendar(identifier: .gregorian)
        )

        let codex = summary.providers.first { $0.provider == .codex }
        try expect(codex?.totalTokens == 100, "expected aggregate total")
        try expect(codex?.authoritativeEvents == 1, "expected authoritative count")
    }

    func aggregationInfersCodexRollingLimits() throws {
        let now = Date(timeIntervalSince1970: 1_782_364_800)
        let events = [
            UsageEvent(
                provider: .codex,
                source: .localUsageLog,
                timestamp: now.addingTimeInterval(-60),
                sessionId: "s",
                requestId: "r",
                model: "gpt",
                inputTokens: 40,
                cacheReadTokens: 10,
                cacheWriteTokens: 0,
                outputTokens: 50,
                confidence: .authoritative
            )
        ]
        let snapshots = [
            CodexRateLimitSnapshot(
                window: .fiveHours,
                observedAt: now,
                usedPercent: 25,
                resetAt: now.addingTimeInterval(300),
                resetAfterSeconds: 300,
                allowed: true,
                limitReached: false,
                planType: "plus"
            )
        ]

        let summary = UsageAggregator.summarize(
            events: events,
            codexRateLimitSnapshots: snapshots,
            period: .today,
            now: now,
            calendar: Calendar(identifier: .gregorian)
        )

        let fiveHours = try require(summary.codexRateLimits.first { $0.window == .fiveHours }, "missing 5h summary")
        try expect(fiveHours.usedTokens == 80, "expected metered 5h used tokens")
        try expect(fiveHours.inferredLimitTokens == 320, "expected inferred 5h token limit")
        try expect(fiveHours.remainingTokens == 240, "expected inferred remaining tokens")
    }

    func aggregationIgnoresExpiredCodexRateLimitSnapshots() throws {
        let now = Date(timeIntervalSince1970: 1_782_364_800)
        let events = [
            UsageEvent(
                provider: .codex,
                source: .localUsageLog,
                timestamp: now.addingTimeInterval(-60),
                sessionId: "s",
                requestId: "r",
                model: "gpt",
                inputTokens: 100,
                cacheReadTokens: 0,
                cacheWriteTokens: 0,
                outputTokens: 0,
                confidence: .authoritative
            )
        ]
        let snapshots = [
            CodexRateLimitSnapshot(
                window: .fiveHours,
                observedAt: now.addingTimeInterval(-10_000),
                usedPercent: 25,
                resetAt: now.addingTimeInterval(-1),
                resetAfterSeconds: 0,
                allowed: true,
                limitReached: false,
                planType: "plus"
            )
        ]

        let summary = UsageAggregator.summarize(
            events: events,
            codexRateLimitSnapshots: snapshots,
            period: .today,
            now: now,
            calendar: Calendar(identifier: .gregorian)
        )

        let fiveHours = try require(summary.codexRateLimits.first { $0.window == .fiveHours }, "missing 5h summary")
        try expect(fiveHours.usedPercent == nil, "expected expired rate percent to be ignored")
        try expect(fiveHours.inferredLimitTokens == nil, "expected no inferred limit from expired snapshot")
        try expect(fiveHours.remainingTokens == nil, "expected no remaining tokens from expired snapshot")
    }


    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

}

private enum TestError: Error {
    case assertion(String)
}

private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else {
        throw TestError.assertion(message)
    }
}

private func require<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else {
        throw TestError.assertion(message)
    }
    return value
}
