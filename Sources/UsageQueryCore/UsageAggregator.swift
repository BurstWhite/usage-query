import Foundation

public struct ProviderUsageSummary: Equatable, Identifiable, Sendable {
    public var id: UsageProviderKind { provider }

    public let provider: UsageProviderKind
    public let totalTokens: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int
    public let authoritativeEvents: Int
    public let estimatedEvents: Int
    public let modelBreakdown: [String: Int]

    public var hasUsage: Bool { totalTokens > 0 }
}

public struct UsageDashboardSummary: Equatable, Sendable {
    public let period: UsagePeriod
    public let generatedAt: Date
    public let providers: [ProviderUsageSummary]
    public let codexRateLimits: [CodexLimitSummary]

    public var totalTokens: Int {
        providers.reduce(0) { $0 + $1.totalTokens }
    }
}

public struct CodexLimitSummary: Equatable, Identifiable, Sendable {
    public var id: String { "\(provider.rawValue)|\(window.rawValue)" }

    public let provider: UsageProviderKind
    public let window: CodexRateLimitWindow
    public let windowStart: Date
    public let windowEnd: Date
    public let usedTokens: Int
    public let inferredLimitTokens: Int?
    public let remainingTokens: Int?
    public let usedPercent: Int?
    public let observedAt: Date?
    public let resetAt: Date?
    public let limitReached: Bool

    public var progress: Double? {
        if let inferredLimitTokens, inferredLimitTokens > 0 {
            return min(1.0, Double(usedTokens) / Double(inferredLimitTokens))
        }
        guard let usedPercent else {
            return nil
        }
        return min(1.0, Double(max(0, usedPercent)) / 100.0)
    }

    public var isNearLimit: Bool {
        if limitReached {
            return true
        }
        return (progress ?? 0) >= 0.8
    }
}

public enum UsageAggregator {
    public static func summarize(
        events: [UsageEvent],
        codexRateLimitSnapshots: [CodexRateLimitSnapshot] = [],
        period: UsagePeriod,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> UsageDashboardSummary {
        let start = period.startDate(now: now, calendar: calendar)
        let periodEvents = events.filter { $0.timestamp >= start && $0.timestamp <= now }
        let providers = UsageProviderKind.allCases.map { provider in
            summary(for: provider, events: periodEvents.filter { $0.provider == provider })
        }
        let codexRateLimits = codexLimitSummaries(events: events, snapshots: codexRateLimitSnapshots, now: now)
        return UsageDashboardSummary(period: period, generatedAt: now, providers: providers, codexRateLimits: codexRateLimits)
    }

    public static func codexLimitSummaries(
        events: [UsageEvent],
        snapshots: [CodexRateLimitSnapshot] = [],
        now: Date = Date()
    ) -> [CodexLimitSummary] {
        CodexRateLimitWindow.allCases.map { window in
            let latestSnapshot = snapshots
                .filter { snapshot in
                    snapshot.window == window
                        && snapshot.observedAt <= now
                        && (snapshot.resetAt.map { $0 > now } ?? true)
                }
                .max { $0.observedAt < $1.observedAt }
            let currentWindowStart = now.addingTimeInterval(-window.duration)
            let currentUsed = events
                .filter { $0.provider == .codex && $0.timestamp >= currentWindowStart && $0.timestamp <= now }
                .reduce(0) { $0 + codexRateLimitTokens(for: $1) }

            let inferredLimit = latestSnapshot.flatMap { snapshot -> Int? in
                guard snapshot.usedPercent > 0 else {
                    return nil
                }
                let observedWindowStart = snapshot.observedAt.addingTimeInterval(-window.duration)
                let observedUsed = events
                    .filter { $0.provider == .codex && $0.timestamp >= observedWindowStart && $0.timestamp <= snapshot.observedAt }
                    .reduce(0) { $0 + codexRateLimitTokens(for: $1) }
                guard observedUsed > 0 else {
                    return nil
                }
                return max(observedUsed, Int((Double(observedUsed) * 100.0 / Double(snapshot.usedPercent)).rounded()))
            }

            return CodexLimitSummary(
                provider: .codex,
                window: window,
                windowStart: currentWindowStart,
                windowEnd: now,
                usedTokens: currentUsed,
                inferredLimitTokens: inferredLimit,
                remainingTokens: inferredLimit.map { max(0, $0 - currentUsed) },
                usedPercent: latestSnapshot?.usedPercent,
                observedAt: latestSnapshot?.observedAt,
                resetAt: latestSnapshot?.resetAt,
                limitReached: latestSnapshot?.limitReached ?? false
            )
        }
    }

    private static func codexRateLimitTokens(for event: UsageEvent) -> Int {
        let uncachedInput = max(0, event.inputTokens - event.cacheReadTokens)
        let meteredTokens = uncachedInput + event.cacheWriteTokens + event.outputTokens
        return meteredTokens > 0 ? meteredTokens : event.totalTokens
    }

    private static func summary(
        for provider: UsageProviderKind,
        events: [UsageEvent]
    ) -> ProviderUsageSummary {
        let total = events.reduce(0) { $0 + $1.totalTokens }
        let input = events.reduce(0) { $0 + $1.inputTokens }
        let output = events.reduce(0) { $0 + $1.outputTokens }
        let cacheRead = events.reduce(0) { $0 + $1.cacheReadTokens }
        let cacheWrite = events.reduce(0) { $0 + $1.cacheWriteTokens }
        let authoritative = events.filter { $0.confidence == .authoritative }.count
        let estimated = events.filter { $0.confidence == .estimated }.count
        let modelBreakdown = Dictionary(grouping: events, by: { $0.model ?? "unknown" })
            .mapValues { grouped in grouped.reduce(0) { $0 + $1.totalTokens } }
            .sorted { lhs, rhs in lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value }
            .reduce(into: [String: Int]()) { partial, item in partial[item.key] = item.value }

        return ProviderUsageSummary(
            provider: provider,
            totalTokens: total,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
            authoritativeEvents: authoritative,
            estimatedEvents: estimated,
            modelBreakdown: modelBreakdown
        )
    }
}
