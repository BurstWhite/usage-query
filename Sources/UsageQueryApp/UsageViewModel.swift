import Foundation
import SwiftUI
import UsageQueryCore

@MainActor
final class UsageViewModel: ObservableObject {
    @Published var selectedPeriod: UsagePeriod = .today {
        didSet { summarize() }
    }
    @Published private(set) var summary = UsageAggregator.summarize(events: [], period: .today)
    @Published private(set) var health: [ProviderHealth] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var errorMessage: String?

    private var events: [UsageEvent] = []
    private var codexRateLimitSnapshots: [CodexRateLimitSnapshot] = []
    private let scanner = UsageScanner()
    private let cache: UsageCache?

    init() {
        self.cache = try? UsageCache(path: Self.cachePath().path)
        if let cached = try? cache?.loadEvents() {
            self.events = cached
        }
        summarize()
    }

    var menuBarTitle: String {
        let codex = summary.providers.first { $0.provider == .codex }?.totalTokens ?? 0
        let claude = summary.providers.first { $0.provider == .claude }?.totalTokens ?? 0
        if codex == 0 && claude == 0 {
            return "AI Usage"
        }
        return "C \(Self.shortTokens(codex)) · A \(Self.shortTokens(claude))"
    }

    func refresh() async {
        guard !isRefreshing else {
            return
        }
        isRefreshing = true
        errorMessage = nil

        let since = UsagePeriod.thirtyDays.startDate()
        let scanner = self.scanner
        let result = await Task.detached(priority: .userInitiated) {
            scanner.scanLocal(since: since)
        }.value

        events = result.events
        codexRateLimitSnapshots = result.codexRateLimitSnapshots
        health = result.health
        lastRefresh = Date()
        do {
            try cache?.replaceEvents(result.events)
        } catch {
            errorMessage = "Cache write failed: \(error.localizedDescription)"
        }
        summarize()
        isRefreshing = false
    }

    private func summarize() {
        summary = UsageAggregator.summarize(events: events, codexRateLimitSnapshots: codexRateLimitSnapshots, period: selectedPeriod)
    }

    private static func cachePath() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("UsageQuery/usage-cache.sqlite")
    }

    static func shortTokens(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
    }
}
