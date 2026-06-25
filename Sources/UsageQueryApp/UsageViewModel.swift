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

    @AppStorage("codexDailyTokens") private var codexDailyTokensString = ""
    @AppStorage("codexWeeklyTokens") private var codexWeeklyTokensString = ""
    @AppStorage("claudeDailyTokens") private var claudeDailyTokensString = ""
    @AppStorage("claudeWeeklyTokens") private var claudeWeeklyTokensString = ""

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

    var budgets: ManualBudgets {
        ManualBudgets(
            codexDailyTokens: Int(codexDailyTokensString),
            codexWeeklyTokens: Int(codexWeeklyTokensString),
            claudeDailyTokens: Int(claudeDailyTokensString),
            claudeWeeklyTokens: Int(claudeWeeklyTokensString)
        )
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

    func updateBudget(_ value: String, for key: BudgetKey) {
        let cleaned = value.filter(\.isNumber)
        switch key {
        case .codexDaily: codexDailyTokensString = cleaned
        case .codexWeekly: codexWeeklyTokensString = cleaned
        case .claudeDaily: claudeDailyTokensString = cleaned
        case .claudeWeekly: claudeWeeklyTokensString = cleaned
        }
        summarize()
    }

    func budgetValue(for key: BudgetKey) -> String {
        switch key {
        case .codexDaily: codexDailyTokensString
        case .codexWeekly: codexWeeklyTokensString
        case .claudeDaily: claudeDailyTokensString
        case .claudeWeekly: claudeWeeklyTokensString
        }
    }

    private func summarize() {
        summary = UsageAggregator.summarize(events: events, codexRateLimitSnapshots: codexRateLimitSnapshots, period: selectedPeriod, budgets: budgets)
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

enum BudgetKey {
    case codexDaily
    case codexWeekly
    case claudeDaily
    case claudeWeekly
}
