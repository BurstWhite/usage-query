import SwiftUI
import UsageQueryCore

struct UsageDashboardView: View {
    @ObservedObject var viewModel: UsageViewModel
    @State private var selectedTab = "overview"

    var body: some View {
        VStack(spacing: 0) {
            header

            Picker("", selection: $selectedTab) {
                Text("Overview").tag("overview")
                Text("Codex").tag("codex")
                Text("Claude").tag("claude")
                Text("Settings").tag("settings")
            }
            .pickerStyle(.segmented)
            .padding([.horizontal, .bottom], 14)

            Divider()

            Group {
                switch selectedTab {
                case "codex":
                    providerDetail(.codex)
                case "claude":
                    providerDetail(.claude)
                case "settings":
                    settings
                default:
                    overview
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI Usage")
                        .font(.title3.weight(.semibold))
                    Text(viewModel.lastRefresh.map { "Updated \($0.formatted(date: .omitted, time: .shortened))" } ?? "Not refreshed yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Image(systemName: viewModel.isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .help("Refresh local usage")
                .disabled(viewModel.isRefreshing)
            }

            Picker("Period", selection: $viewModel.selectedPeriod) {
                ForEach(UsagePeriod.allCases) { period in
                    Text(period.displayName).tag(period)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(14)
    }

    private var overview: some View {
        ScrollView {
            VStack(spacing: 12) {
                totalCard

                codexRateLimitCard

                ForEach(viewModel.summary.providers) { provider in
                    ProviderCard(summary: provider)
                }

                if !viewModel.health.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Data Sources")
                            .font(.headline)
                        ForEach(viewModel.health, id: \.provider) { health in
                            HStack(spacing: 8) {
                                Image(systemName: health.isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(health.isAvailable ? .green : .orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(health.provider.displayName)
                                        .font(.subheadline.weight(.medium))
                                    Text(health.message)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                            }
                        }
                    }
                    .padding(12)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                }

                if let error = viewModel.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
        }
    }

    private var totalCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Total")
                .font(.headline)
            Text(UsageViewModel.shortTokens(viewModel.summary.totalTokens))
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(viewModel.summary.period.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private func providerDetail(_ provider: UsageProviderKind) -> some View {
        let summary = viewModel.summary.providers.first { $0.provider == provider }
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let summary {
                    ProviderCard(summary: summary)
                    if provider == .codex {
                        codexRateLimitCard
                    }
                    tokenBreakdown(summary)
                    modelBreakdown(summary)
                } else {
                    ContentUnavailableView(provider.displayName, systemImage: "chart.bar", description: Text("No local usage found."))
                }
            }
            .padding(14)
        }
    }

    private func tokenBreakdown(_ summary: ProviderUsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Breakdown")
                .font(.headline)
            MetricRow(label: "Input", value: UsageViewModel.shortTokens(summary.inputTokens), icon: "arrow.down.left")
            MetricRow(label: "Output", value: UsageViewModel.shortTokens(summary.outputTokens), icon: "arrow.up.right")
            MetricRow(label: "Cache read", value: UsageViewModel.shortTokens(summary.cacheReadTokens), icon: "tray.and.arrow.down")
            MetricRow(label: "Cache write", value: UsageViewModel.shortTokens(summary.cacheWriteTokens), icon: "tray.and.arrow.up")
            MetricRow(label: "Authoritative events", value: "\(summary.authoritativeEvents)", icon: "checkmark.seal")
            MetricRow(label: "Estimated events", value: "\(summary.estimatedEvents)", icon: "sum")
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private var codexRateLimitCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Codex rate limits", systemImage: "hourglass")
                    .font(.headline)
                Spacer()
                Text("inferred")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(viewModel.summary.codexRateLimits) { limit in
                CodexLimitRow(limit: limit)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private func modelBreakdown(_ summary: ProviderUsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Models")
                .font(.headline)
            if summary.modelBreakdown.isEmpty {
                Text("No model data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(summary.modelBreakdown.keys), id: \.self) { model in
                    MetricRow(label: model, value: UsageViewModel.shortTokens(summary.modelBreakdown[model] ?? 0), icon: "cpu")
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Manual Token Budgets")
                    .font(.headline)

                BudgetField(title: "Codex daily", value: binding(.codexDaily))
                BudgetField(title: "Codex weekly", value: binding(.codexWeekly))
                BudgetField(title: "Claude daily", value: binding(.claudeDaily))
                BudgetField(title: "Claude weekly", value: binding(.claudeWeekly))

                Text("Codex 5h and 7 days limits are inferred from local session token_count rate limits. Manual budgets only affect the older daily/weekly estimate cards. Local conversation text is read in memory for token estimation and is not stored in the cache.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
        }
    }

    private func binding(_ key: BudgetKey) -> Binding<String> {
        Binding {
            viewModel.budgetValue(for: key)
        } set: { newValue in
            viewModel.updateBudget(newValue, for: key)
        }
    }
}

private struct ProviderCard: View {
    let summary: ProviderUsageSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(summary.provider.displayName, systemImage: summary.provider == .codex ? "terminal" : "sparkles")
                    .font(.headline)
                Spacer()
                Text(UsageViewModel.shortTokens(summary.totalTokens))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
            }

            if let quota = summary.quota, let limit = quota.limitTokens {
                ProgressView(value: Double(min(summary.totalTokens, limit)), total: Double(max(limit, 1)))
                HStack {
                    Text("Remaining")
                    Spacer()
                    Text(UsageViewModel.shortTokens(quota.remainingTokens ?? 0))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text(summary.hasUsage ? "Remaining unknown" : "No local usage found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct CodexLimitRow: View {
    let limit: CodexLimitSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(limit.window.displayName)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(statusText)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(limit.isNearLimit ? .orange : .secondary)
            }

            if let progress = limit.progress {
                ProgressView(value: progress)
                    .tint(limit.isNearLimit ? .orange : .accentColor)
            }

            HStack {
                Text(detailText)
                Spacer()
                Text(resetText)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        if let remaining = limit.remainingTokens {
            return "\(UsageViewModel.shortTokens(remaining)) left"
        }
        if let usedPercent = limit.usedPercent {
            return "\(usedPercent)% used"
        }
        return UsageViewModel.shortTokens(limit.usedTokens)
    }

    private var detailText: String {
        if let inferredLimit = limit.inferredLimitTokens, let usedPercent = limit.usedPercent {
            return "\(UsageViewModel.shortTokens(limit.usedTokens)) / ~\(UsageViewModel.shortTokens(inferredLimit)) from \(usedPercent)%"
        }
        if let usedPercent = limit.usedPercent {
            return "\(UsageViewModel.shortTokens(limit.usedTokens)) used; \(usedPercent)% from Codex"
        }
        return "\(UsageViewModel.shortTokens(limit.usedTokens)) used; no rate snapshot"
    }

    private var resetText: String {
        guard let resetAt = limit.resetAt else {
            return limit.window == .fiveHours ? "5h window" : "7d window"
        }
        return "resets \(resetAt.formatted(date: .omitted, time: .shortened))"
    }
}

private struct MetricRow: View {
    let label: String
    let value: String
    let icon: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text(label)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }
}

private struct BudgetField: View {
    let title: String
    @Binding var value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField("tokens", text: $value)
                .textFieldStyle(.roundedBorder)
                .frame(width: 130)
                .multilineTextAlignment(.trailing)
        }
    }
}
