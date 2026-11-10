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
    @Published private(set) var todayTokens: [UsageProviderKind: Int] = [:]
    /// Last time the status line bridge delivered Claude limits, even if they have since expired.
    @Published private(set) var claudeBridgeObservedAt: Date?
    /// A rescan reads every recent session file, so it only runs often while the floating window needs it.
    var autoRefreshInterval: Duration = UsageViewModel.backgroundRefreshInterval

    static let backgroundRefreshInterval: Duration = .seconds(300)
    static let floatingRefreshInterval: Duration = .seconds(60)

    private var events: [UsageEvent] = []
    private var rateLimitSnapshots: [CodexRateLimitSnapshot] = []
    private let scanner = UsageScanner()
    private let cache: UsageCache?
    private var autoRefreshTask: Task<Void, Never>?

    init() {
        self.cache = try? UsageCache(path: Self.cachePath().path)
        if let cached = try? cache?.loadEvents() {
            self.events = cached
        }
        if let cachedSnapshots = try? cache?.loadRateLimitSnapshots() {
            self.rateLimitSnapshots = cachedSnapshots
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

    /// Keeps the menu bar title and floating window current without opening the popover.
    func startAutoRefresh() {
        guard autoRefreshTask == nil else {
            return
        }
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: self?.autoRefreshInterval ?? UsageViewModel.backgroundRefreshInterval)
            }
        }
    }

    /// Status line command for Claude Code's settings.json that feeds the Claude limit cards.
    static var claudeBridgeSettingsSnippet: String {
        let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let quoted = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let command = "\(quoted) \(StatusLineBridgeCommand.flag)"
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return """
        "statusLine": {
          "type": "command",
          "command": "\(escaped)"
        }
        """
    }

    func refresh() async {
        guard !isRefreshing else {
            return
        }
        isRefreshing = true

        let since = UsagePeriod.thirtyDays.startDate()
        let scanner = self.scanner
        let result = await Task.detached(priority: .userInitiated) {
            scanner.scanLocal(since: since)
        }.value

        // A provider whose scan threw keeps its previous data instead of being wiped.
        let failed = result.failedProviders
        events = result.events + events.filter { failed.contains($0.provider) }
        events.sort { $0.timestamp < $1.timestamp }
        rateLimitSnapshots = result.rateLimitSnapshots
            + rateLimitSnapshots.filter { failed.contains($0.provider) }
        health = result.health
        lastRefresh = Date()
        do {
            try cache?.replaceEvents(events)
            try cache?.replaceRateLimitSnapshots(rateLimitSnapshots)
            errorMessage = nil
        } catch {
            errorMessage = "Cache write failed: \(error.localizedDescription)"
        }
        summarize()
        isRefreshing = false
    }

    private func summarize() {
        summary = UsageAggregator.summarize(events: events, rateLimitSnapshots: rateLimitSnapshots, period: selectedPeriod)
        let today = selectedPeriod == .today
            ? summary
            : UsageAggregator.summarize(events: events, period: .today, now: summary.generatedAt)
        todayTokens = Dictionary(uniqueKeysWithValues: today.providers.map { ($0.provider, $0.totalTokens) })
        claudeBridgeObservedAt = rateLimitSnapshots.filter { $0.provider == .claude }.map(\.observedAt).max()
    }

    private static func cachePath() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("UsageQuery/usage-cache.sqlite")
    }

    nonisolated static func shortTokens(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
    }
}
