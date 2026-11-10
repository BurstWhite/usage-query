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
    public let claudeRateLimits: [CodexLimitSummary]

    public init(
        period: UsagePeriod,
        generatedAt: Date,
        providers: [ProviderUsageSummary],
        codexRateLimits: [CodexLimitSummary],
        claudeRateLimits: [CodexLimitSummary] = []
    ) {
        self.period = period
        self.generatedAt = generatedAt
        self.providers = providers
        self.codexRateLimits = codexRateLimits
        self.claudeRateLimits = claudeRateLimits
    }

    public func rateLimits(for provider: UsageProviderKind) -> [CodexLimitSummary] {
        switch provider {
        case .codex: codexRateLimits
        case .claude: claudeRateLimits
        }
    }

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

    /// Used share of the window. The reported percentage is account-wide and is
    /// the floor; local usage against the inferred limit can only raise it, to
    /// cover tokens spent here since the snapshot.
    public var progress: Double? {
        let reported = usedPercent.map { min(1.0, Double(max(0, $0)) / 100.0) }
        guard let inferredLimitTokens, inferredLimitTokens > 0 else {
            return reported
        }
        let local = min(1.0, Double(usedTokens) / Double(inferredLimitTokens))
        return max(local, reported ?? 0)
    }

    /// Share of the window still available; never more than the provider reported.
    public var remainingPercent: Int? {
        progress.map { max(0, min(100, Int(((1.0 - $0) * 100).rounded()))) }
    }

    public var hasSignal: Bool {
        usedPercent != nil || usedTokens > 0
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
        rateLimitSnapshots: [CodexRateLimitSnapshot] = [],
        period: UsagePeriod,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> UsageDashboardSummary {
        let start = period.startDate(now: now, calendar: calendar)
        let periodEvents = events.filter { $0.timestamp >= start && $0.timestamp <= now }
        let providers = UsageProviderKind.allCases.map { provider in
            summary(for: provider, events: periodEvents.filter { $0.provider == provider })
        }
        return UsageDashboardSummary(
            period: period,
            generatedAt: now,
            providers: providers,
            codexRateLimits: limitSummaries(provider: .codex, events: events, snapshots: rateLimitSnapshots, now: now),
            claudeRateLimits: limitSummaries(provider: .claude, events: events, snapshots: rateLimitSnapshots, now: now)
        )
    }

    public static func codexLimitSummaries(
        events: [UsageEvent],
        snapshots: [CodexRateLimitSnapshot] = [],
        now: Date = Date()
    ) -> [CodexLimitSummary] {
        limitSummaries(provider: .codex, events: events, snapshots: snapshots, now: now)
    }

    public static func limitSummaries(
        provider: UsageProviderKind,
        events: [UsageEvent],
        snapshots: [CodexRateLimitSnapshot] = [],
        now: Date = Date()
    ) -> [CodexLimitSummary] {
        let providerEvents = events.filter { $0.provider == provider }
        func meteredTokens(from start: Date, to end: Date) -> Int {
            providerEvents
                .filter { $0.timestamp >= start && $0.timestamp <= end }
                .reduce(0) { $0 + rateLimitTokens(for: $1) }
        }

        return CodexRateLimitWindow.allCases.map { window in
            let latestSnapshot = snapshots
                .filter { snapshot in
                    snapshot.provider == provider
                        && snapshot.window == window
                        && snapshot.observedAt <= now
                        && (snapshot.resetAt.map { $0 > now } ?? true)
                }
                .max { $0.observedAt < $1.observedAt }

            // Claude windows are fixed blocks ending at the reported reset, so
            // anchor on it when known. Codex stays on the rolling window.
            let anchoredStart: Date? = provider == .claude
                ? latestSnapshot?.resetAt.map { $0.addingTimeInterval(-window.duration) }
                : nil
            let currentWindowStart = anchoredStart ?? now.addingTimeInterval(-window.duration)
            let currentUsed = meteredTokens(from: currentWindowStart, to: now)

            let inferredLimit = latestSnapshot.flatMap { snapshot -> Int? in
                guard snapshot.usedPercent > 0 else {
                    return nil
                }
                let observedWindowStart = anchoredStart ?? snapshot.observedAt.addingTimeInterval(-window.duration)
                let observedUsed = meteredTokens(from: observedWindowStart, to: snapshot.observedAt)
                guard observedUsed > 0 else {
                    return nil
                }
                return max(observedUsed, Int((Double(observedUsed) * 100.0 / Double(snapshot.usedPercent)).rounded()))
            }

            return CodexLimitSummary(
                provider: provider,
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

    /// Tokens that plausibly count against a limit: everything except cache reads.
    /// Codex reports cached input inside `input_tokens`; Claude reports it separately.
    private static func rateLimitTokens(for event: UsageEvent) -> Int {
        let uncachedInput = event.provider == .codex
            ? max(0, event.inputTokens - event.cacheReadTokens)
            : event.inputTokens
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
