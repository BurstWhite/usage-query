import Foundation

public struct UsageScanResult: Sendable {
    public let events: [UsageEvent]
    public let rateLimitSnapshots: [CodexRateLimitSnapshot]
    public let health: [ProviderHealth]
    /// Providers whose scan threw; their previous data should be kept rather than wiped.
    public let failedProviders: Set<UsageProviderKind>

    public init(
        events: [UsageEvent],
        rateLimitSnapshots: [CodexRateLimitSnapshot],
        health: [ProviderHealth],
        failedProviders: Set<UsageProviderKind> = []
    ) {
        self.failedProviders = failedProviders
        self.events = events
        self.rateLimitSnapshots = rateLimitSnapshots
        self.health = health
    }
}

public struct UsageScanner: Sendable {
    private let providers: [any UsageProvider]

    public init(providers: [any UsageProvider] = [CodexUsageProvider(), ClaudeUsageProvider()]) {
        self.providers = providers
    }

    public func scanLocal(since: Date?) -> UsageScanResult {
        var events: [UsageEvent] = []
        var rateLimitSnapshots: [CodexRateLimitSnapshot] = []
        var health: [ProviderHealth] = []
        var failedProviders = Set<UsageProviderKind>()

        for provider in providers {
            do {
                let providerEvents = try provider.scanLocal(since: since)
                let providerRateLimits = try provider.scanRateLimitSnapshots(since: since)
                events.append(contentsOf: providerEvents)
                rateLimitSnapshots.append(contentsOf: providerRateLimits)
                let baseHealth = provider.healthCheck()
                health.append(
                    ProviderHealth(
                        provider: baseHealth.provider,
                        isAvailable: baseHealth.isAvailable,
                        message: "\(baseHealth.message); \(providerEvents.count) usage event\(providerEvents.count == 1 ? "" : "s"); \(providerRateLimits.count) limit snapshot\(providerRateLimits.count == 1 ? "" : "s")"
                    )
                )
            } catch {
                failedProviders.insert(provider.kind)
                health.append(ProviderHealth(provider: provider.kind, isAvailable: false, message: String(describing: error)))
            }
        }

        return UsageScanResult(
            events: events.sorted { $0.timestamp < $1.timestamp },
            rateLimitSnapshots: rateLimitSnapshots.sorted { $0.observedAt < $1.observedAt },
            health: health,
            failedProviders: failedProviders
        )
    }
}
