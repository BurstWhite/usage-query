import Foundation
@testable import UsageQueryCore

@main
struct UsageQueryCoreTestRunner {
    static func main() throws {
        let tests = UsageQueryCoreTests()
        try tests.claudeParserUsesAuthoritativeUsageWhenPresent()
        try tests.claudeParserEstimatesMissingUsageWithoutDuplicatingAuthoritativeEvents()
        try tests.claudeParserMergesStreamedDuplicatesAndSurvivesInvalidUTF8()
        try tests.cachePersistsRateLimitSnapshots()
        try tests.codexParserReadsSessionTokenCounts()
        try tests.cacheDoesNotPersistConversationText()
        try tests.aggregationSummarizesProviderUsage()
        try tests.aggregationInfersCodexRollingLimits()
        try tests.aggregationIgnoresExpiredCodexRateLimitSnapshots()
        try tests.claudeBridgeRecordsOnlyLimitNumbers()
        try tests.claudeBridgeKeepsWindowsMissingFromLaterPayloads()
        try tests.claudeBridgeIgnoresStalePayloadsFromIdleSessions()
        try tests.aggregationInfersClaudeLimitsFromBridgeSnapshot()
        try tests.aggregationNeverReportsMoreRemainingThanTheProvider()
        try tests.aggregationReportsClaudeWindowUsageWithoutSnapshot()
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

        try expect(events.count == 1, "estimates must not double count files that carry usage")
        try expect(events.first?.confidence == .authoritative, "expected authoritative event only")

        let estimateOnly = try temporaryHome()
        let dir = estimateOnly.appendingPathComponent(".claude/projects/test")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try lines.components(separatedBy: "\n")[0].write(to: dir.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
        let estimated = try ClaudeUsageProvider(homeDirectory: estimateOnly).scanLocal(since: nil)
        try expect(estimated.count == 1 && estimated[0].confidence == .estimated, "expected estimate fallback without usage")
        try expect(estimated[0].inputTokens > 0, "expected estimated input tokens")
    }

    func claudeParserMergesStreamedDuplicatesAndSurvivesInvalidUTF8() throws {
        let home = try temporaryHome()
        let project = home.appendingPathComponent(".claude/projects/test")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        func line(_ output: Int, _ minute: Int) -> String {
            #"{"type":"assistant","timestamp":"2026-06-25T02:0\#(minute):00.000Z","sessionId":"s1","uuid":"u\#(minute)","message":{"id":"m1","role":"assistant","model":"c","content":[],"usage":{"input_tokens":10,"output_tokens":\#(output)}}}"#
        }
        var data = Data((line(2, 0) + "\n").utf8)
        data.append(contentsOf: [0xFF, 0xFE, 0x0A])
        data.append(Data((line(9, 1) + "\n" + #"{"type":"assistant","timestamp":"2026-06-25T02:05:00.000Z","message":{"id":"m2","usage":{"input_tokens":1,"output_tokens":1}}}"#).utf8))
        try data.write(to: project.appendingPathComponent("s.jsonl"))

        let events = try ClaudeUsageProvider(homeDirectory: home).scanLocal(since: nil)
        try expect(events.count == 2, "expected streamed duplicates merged and later lines still read")
        try expect(events.first { $0.requestId == "m1" }?.outputTokens == 9, "expected the most complete duplicate to win")
    }

    func cachePersistsRateLimitSnapshots() throws {
        let home = try temporaryHome()
        let cache = try UsageCache(path: home.appendingPathComponent("c.sqlite").path)
        let snapshot = CodexRateLimitSnapshot(
            window: .fiveHours, observedAt: Date(timeIntervalSince1970: 1_000), usedPercent: 40,
            resetAt: Date(timeIntervalSince1970: 5_000), resetAfterSeconds: 4_000,
            allowed: true, limitReached: false, planType: "plus"
        )
        let claudeSnapshot = CodexRateLimitSnapshot(
            provider: .claude, window: .fiveHours, observedAt: Date(timeIntervalSince1970: 1_000), usedPercent: 40,
            resetAt: Date(timeIntervalSince1970: 5_000), resetAfterSeconds: 4_000,
            allowed: true, limitReached: false, planType: nil
        )
        try cache.replaceRateLimitSnapshots([snapshot, claudeSnapshot])
        let loaded = try cache.loadRateLimitSnapshots()
        try expect(loaded.count == 2 && loaded.contains(snapshot) && loaded.contains(claudeSnapshot), "expected snapshot round trip per provider")
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
            rateLimitSnapshots: snapshots,
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
            rateLimitSnapshots: snapshots,
            period: .today,
            now: now,
            calendar: Calendar(identifier: .gregorian)
        )

        let fiveHours = try require(summary.codexRateLimits.first { $0.window == .fiveHours }, "missing 5h summary")
        try expect(fiveHours.usedPercent == nil, "expected expired rate percent to be ignored")
        try expect(fiveHours.inferredLimitTokens == nil, "expected no inferred limit from expired snapshot")
        try expect(fiveHours.remainingTokens == nil, "expected no remaining tokens from expired snapshot")
    }

    func claudeBridgeRecordsOnlyLimitNumbers() throws {
        let home = try temporaryHome()
        let observedAt = Date(timeIntervalSince1970: 1_782_364_800)
        let payload = """
        {"session_id":"SECRET_SESSION","transcript_path":"/Users/someone/SECRET_PATH/t.jsonl","cwd":"/Users/someone/SECRET_PATH","model":{"id":"claude-fable-5-2","display_name":"SECRET_MODEL"},"rate_limits":{"five_hour":{"used_percentage":41.6,"resets_at":1782372000},"seven_day":{"used_percentage":18,"resets_at":1782800000}}}
        """
        try ClaudeRateLimitBridge.record(statusLineJSON: Data(payload.utf8), observedAt: observedAt, homeDirectory: home)

        let stored = try String(contentsOf: ClaudeRateLimitBridge.fileURL(homeDirectory: home), encoding: .utf8)
        try expect(!stored.contains("SECRET"), "bridge persisted status line fields beyond limit numbers")

        let snapshots = try ClaudeUsageProvider(homeDirectory: home).scanRateLimitSnapshots(since: nil)
        let fiveHours = try require(snapshots.first { $0.window == .fiveHours }, "missing Claude 5h snapshot")
        let sevenDays = try require(snapshots.first { $0.window == .sevenDays }, "missing Claude 7 days snapshot")
        try expect(fiveHours.provider == .claude && sevenDays.provider == .claude, "expected Claude snapshots")
        try expect(fiveHours.usedPercent == 42, "expected rounded 5h used percent")
        try expect(fiveHours.resetAt == Date(timeIntervalSince1970: 1_782_372_000), "expected 5h reset from epoch seconds")
        try expect(fiveHours.observedAt == observedAt, "expected observation time")
        try expect(sevenDays.usedPercent == 18, "expected 7 days used percent")
        try expect(ClaudeRateLimitBridge.statusLineText(for: snapshots) == "5h 42% · 7d 18%", "expected status line text")

        let empty = try temporaryHome()
        try expect(try ClaudeUsageProvider(homeDirectory: empty).scanRateLimitSnapshots(since: nil).isEmpty, "expected no snapshots without bridge file")
    }

    func claudeBridgeKeepsWindowsMissingFromLaterPayloads() throws {
        let home = try temporaryHome()
        let first = Date(timeIntervalSince1970: 1_782_364_800)
        let full = #"{"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":1782372000},"seven_day":{"used_percentage":18,"resets_at":1782800000}}}"#
        let partial = #"{"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":1782372000}}}"#
        try ClaudeRateLimitBridge.record(statusLineJSON: Data(full.utf8), observedAt: first, homeDirectory: home)
        try ClaudeRateLimitBridge.record(statusLineJSON: Data(partial.utf8), observedAt: first.addingTimeInterval(60), homeDirectory: home)
        // API-key sessions carry no rate_limits and must not wipe the file.
        try ClaudeRateLimitBridge.record(statusLineJSON: Data(#"{"cwd":"/tmp"}"#.utf8), observedAt: first.addingTimeInterval(120), homeDirectory: home)

        let snapshots = ClaudeRateLimitBridge.loadSnapshots(homeDirectory: home)
        try expect(snapshots.first { $0.window == .fiveHours }?.usedPercent == 12, "expected newer 5h value")
        try expect(snapshots.first { $0.window == .fiveHours }?.observedAt == first.addingTimeInterval(60), "expected newer 5h observation time")
        let sevenDays = try require(snapshots.first { $0.window == .sevenDays }, "7 days window was dropped")
        try expect(sevenDays.usedPercent == 18 && sevenDays.observedAt == first, "expected earlier 7 days value kept")
    }

    func claudeBridgeIgnoresStalePayloadsFromIdleSessions() throws {
        let home = try temporaryHome()
        let now = Date(timeIntervalSince1970: 1_782_364_800)
        func payload(_ percent: Int, resetsIn seconds: Int) -> Data {
            Data(#"{"rate_limits":{"five_hour":{"used_percentage":\#(percent),"resets_at":\#(1_782_364_800 + seconds)}}}"#.utf8)
        }
        func stored() -> CodexRateLimitSnapshot? {
            ClaudeRateLimitBridge.loadSnapshots(homeDirectory: home).first { $0.window == .fiveHours }
        }

        try ClaudeRateLimitBridge.record(statusLineJSON: payload(60, resetsIn: 3_600), observedAt: now, homeDirectory: home)
        // Another session still holding an earlier, lower reading of the same block.
        try ClaudeRateLimitBridge.record(statusLineJSON: payload(20, resetsIn: 3_600), observedAt: now.addingTimeInterval(10), homeDirectory: home)
        try expect(stored()?.usedPercent == 60 && stored()?.observedAt == now, "lower reading of the same block replaced a newer one")
        // A session that last heard from the API before the previous reset.
        try ClaudeRateLimitBridge.record(statusLineJSON: payload(95, resetsIn: -600), observedAt: now.addingTimeInterval(20), homeDirectory: home)
        try expect(stored()?.usedPercent == 60, "expired block replaced the current one")
        // Same block, later reading.
        try ClaudeRateLimitBridge.record(statusLineJSON: payload(61, resetsIn: 3_630), observedAt: now.addingTimeInterval(30), homeDirectory: home)
        try expect(stored()?.usedPercent == 61, "expected newer reading of the same block")
        // After the reset a new block starts low again.
        try ClaudeRateLimitBridge.record(statusLineJSON: payload(3, resetsIn: 3_600 + 18_000), observedAt: now.addingTimeInterval(4_000), homeDirectory: home)
        try expect(stored()?.usedPercent == 3, "expected the next block to replace the finished one")
    }

    func aggregationNeverReportsMoreRemainingThanTheProvider() throws {
        let now = Date(timeIntervalSince1970: 1_782_364_800)
        let event = UsageEvent(
            provider: .claude, source: .localUsageLog, timestamp: now.addingTimeInterval(-1_800),
            sessionId: "s", requestId: "r", model: "claude",
            inputTokens: 100, cacheReadTokens: 0, cacheWriteTokens: 0, outputTokens: 0,
            confidence: .authoritative
        )
        // 70% reported account-wide, but local logs only explain part of it once the limit is inferred
        // from an older, smaller share: remaining must follow the reported number.
        let limit = CodexLimitSummary(
            provider: .claude, window: .fiveHours, windowStart: now.addingTimeInterval(-18_000), windowEnd: now,
            usedTokens: 100, inferredLimitTokens: 250, remainingTokens: 150, usedPercent: 70,
            observedAt: now, resetAt: now.addingTimeInterval(600), limitReached: false
        )
        try expect(limit.remainingPercent == 30, "remaining must not exceed what the provider reported")

        let unknown = UsageAggregator.limitSummaries(
            provider: .claude, events: [event],
            snapshots: [CodexRateLimitSnapshot(
                provider: .claude, window: .fiveHours, observedAt: now, usedPercent: 0,
                resetAt: now.addingTimeInterval(600), resetAfterSeconds: 600, allowed: true, limitReached: false, planType: nil
            )],
            now: now
        ).first { $0.window == .fiveHours }
        try expect(unknown?.remainingPercent == 100 && unknown?.inferredLimitTokens == nil, "expected reported 0% used without an inferred limit")
    }

    func aggregationInfersClaudeLimitsFromBridgeSnapshot() throws {
        let now = Date(timeIntervalSince1970: 1_782_364_800)
        func claudeEvent(_ id: String, offset: TimeInterval, output: Int) -> UsageEvent {
            UsageEvent(
                provider: .claude, source: .localUsageLog, timestamp: now.addingTimeInterval(offset),
                sessionId: "s", requestId: id, model: "claude",
                inputTokens: 100, cacheReadTokens: 5_000, cacheWriteTokens: 50, outputTokens: output,
                confidence: .authoritative
            )
        }
        let resetAt = now.addingTimeInterval(3_600)
        let events = [
            // Inside the rolling 5h but before the fixed block that ends at resetAt.
            claudeEvent("before-block", offset: -4.5 * 3_600, output: 9_000),
            claudeEvent("observed", offset: -1_800, output: 50),
            claudeEvent("after-snapshot", offset: -60, output: 50)
        ]
        let snapshots = [
            CodexRateLimitSnapshot(
                provider: .claude, window: .fiveHours, observedAt: now.addingTimeInterval(-600), usedPercent: 20,
                resetAt: resetAt, resetAfterSeconds: 4_200, allowed: true, limitReached: false, planType: nil
            ),
            CodexRateLimitSnapshot(
                provider: .codex, window: .sevenDays, observedAt: now.addingTimeInterval(-600), usedPercent: 90,
                resetAt: resetAt, resetAfterSeconds: 4_200, allowed: true, limitReached: false, planType: "plus"
            )
        ]

        let summary = UsageAggregator.summarize(
            events: events, rateLimitSnapshots: snapshots, period: .today,
            now: now, calendar: Calendar(identifier: .gregorian)
        )

        let fiveHours = try require(summary.claudeRateLimits.first { $0.window == .fiveHours }, "missing Claude 5h summary")
        try expect(fiveHours.windowStart == resetAt.addingTimeInterval(-5 * 3_600), "expected window anchored on reset")
        try expect(fiveHours.usedTokens == 400, "expected metered tokens without cache reads, inside the block only")
        try expect(fiveHours.inferredLimitTokens == 1_000, "expected limit inferred from usage at observation")
        try expect(fiveHours.remainingTokens == 600, "expected inferred remaining tokens")
        try expect(fiveHours.remainingPercent == 60, "expected remaining percent to include usage after the snapshot")

        let sevenDays = try require(summary.claudeRateLimits.first { $0.window == .sevenDays }, "missing Claude 7 days summary")
        try expect(sevenDays.usedPercent == nil, "Codex snapshots must not feed Claude limits")
        try expect(summary.codexRateLimits.first { $0.window == .fiveHours }?.usedPercent == nil, "Claude snapshots must not feed Codex limits")
    }

    func aggregationReportsClaudeWindowUsageWithoutSnapshot() throws {
        let now = Date(timeIntervalSince1970: 1_782_364_800)
        let events = [-3_600.0, -6 * 3_600.0].enumerated().map { index, offset in
            UsageEvent(
                provider: .claude, source: .localUsageLog, timestamp: now.addingTimeInterval(offset),
                sessionId: "s", requestId: "r\(index)", model: "claude",
                inputTokens: 10, cacheReadTokens: 1_000, cacheWriteTokens: 20, outputTokens: 30,
                confidence: .authoritative
            )
        }
        let limits = UsageAggregator.limitSummaries(provider: .claude, events: events, now: now)
        let fiveHours = try require(limits.first { $0.window == .fiveHours }, "missing Claude 5h summary")
        let sevenDays = try require(limits.first { $0.window == .sevenDays }, "missing Claude 7 days summary")
        try expect(fiveHours.usedTokens == 60 && sevenDays.usedTokens == 120, "expected rolling window usage")
        try expect(fiveHours.remainingPercent == nil && fiveHours.inferredLimitTokens == nil, "expected unknown remaining without snapshot")
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
