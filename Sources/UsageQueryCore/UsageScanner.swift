import Foundation

public struct UsageScanResult: Sendable {
    public let events: [UsageEvent]
    public let codexRateLimitSnapshots: [CodexRateLimitSnapshot]
    public let health: [ProviderHealth]

    public init(events: [UsageEvent], codexRateLimitSnapshots: [CodexRateLimitSnapshot], health: [ProviderHealth]) {
        self.events = events
        self.codexRateLimitSnapshots = codexRateLimitSnapshots
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
        var codexRateLimitSnapshots: [CodexRateLimitSnapshot] = []
        var health: [ProviderHealth] = []

        for provider in providers {
            do {
                let providerEvents = try provider.scanLocal(since: since)
                let providerRateLimits = try provider.scanRateLimitSnapshots(since: since)
                events.append(contentsOf: providerEvents)
                codexRateLimitSnapshots.append(contentsOf: providerRateLimits)
                let baseHealth = provider.healthCheck()
                health.append(
                    ProviderHealth(
                        provider: baseHealth.provider,
                        isAvailable: baseHealth.isAvailable,
                        message: "\(baseHealth.message); \(providerEvents.count) usage event\(providerEvents.count == 1 ? "" : "s"); \(providerRateLimits.count) limit snapshot\(providerRateLimits.count == 1 ? "" : "s")"
                    )
                )
            } catch {
                health.append(ProviderHealth(provider: provider.kind, isAvailable: false, message: String(describing: error)))
            }
        }

        return UsageScanResult(
            events: events.sorted { $0.timestamp < $1.timestamp },
            codexRateLimitSnapshots: codexRateLimitSnapshots.sorted { $0.observedAt < $1.observedAt },
            health: health
        )
    }
}
