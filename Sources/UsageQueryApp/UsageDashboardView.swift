import AppKit
import SwiftUI
import UsageQueryCore

struct UsageDashboardView: View {
    @ObservedObject var viewModel: UsageViewModel
    @ObservedObject var floatingPanel: FloatingPanelController
    @State private var selectedTab: String

    init(viewModel: UsageViewModel, floatingPanel: FloatingPanelController, initialTab: String = "overview") {
        self.viewModel = viewModel
        self.floatingPanel = floatingPanel
        _selectedTab = State(initialValue: initialTab)
    }

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
            .labelsHidden()
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
                    Text(viewModel.lastRefresh.map { "Updated \(UsageFormat.clock($0))" } ?? "Not refreshed yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 8) {
                    Button {
                        floatingPanel.toggle()
                    } label: {
                        Image(systemName: floatingPanel.isVisible ? "pip.exit" : "pip.enter")
                    }
                    .buttonStyle(.bordered)
                    .help(floatingPanel.isVisible ? "Hide floating window" : "Show floating window")

                    Button {
                        Task { await viewModel.refresh() }
                    } label: {
                        Image(systemName: viewModel.isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .help("Refresh local usage")
                    .disabled(viewModel.isRefreshing)

                    Button {
                        NSApplication.shared.terminate(nil)
                    } label: {
                        Image(systemName: "power")
                    }
                    .buttonStyle(.bordered)
                    .help("Quit UsageQuery")
                }
            }
        }
        .padding(14)
    }

    private var overview: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(UsageProviderKind.allCases) { provider in
                    LimitsCard(provider: provider, limits: viewModel.summary.rateLimits(for: provider))
                }

                tokensCard

                if !viewModel.health.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Data Sources")
                            .font(.headline)
                        ForEach(viewModel.health, id: \.provider) { health in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: health.isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(health.isAvailable ? .green : .orange)
                                Text(health.provider.displayName)
                                    .font(.subheadline.weight(.medium))
                                Text(health.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .card()
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

    /// The period only changes token totals, so its picker lives with them.
    private var periodPicker: some View {
        Picker("Period", selection: $viewModel.selectedPeriod) {
            ForEach(UsagePeriod.allCases) { period in
                Text(period.displayName).tag(period)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
    }

    private var tokensCard: some View {
        let total = viewModel.summary.totalTokens
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Tokens")
                    .font(.headline)
                Spacer()
                periodPicker
            }

            ForEach(viewModel.summary.providers) { provider in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Label(provider.provider.displayName, systemImage: provider.provider.symbolName)
                            .font(.subheadline)
                        Text(provider.confidenceText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(UsageViewModel.shortTokens(provider.totalTokens))
                            .font(.subheadline.weight(.medium))
                            .monospacedDigit()
                    }
                    ShareBar(fraction: total > 0 ? Double(provider.totalTokens) / Double(total) : 0)
                }
            }

            Divider()

            HStack(alignment: .firstTextBaseline) {
                Text("Total")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(UsageViewModel.shortTokens(total))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .card()
    }

    private func providerDetail(_ provider: UsageProviderKind) -> some View {
        let summary = viewModel.summary.providers.first { $0.provider == provider }
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let summary {
                    rateLimitCard(provider)
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
            HStack {
                Text("Tokens")
                    .font(.headline)
                Spacer()
                periodPicker
            }
            MetricRow(label: "Total", value: UsageViewModel.shortTokens(summary.totalTokens), icon: "sum", emphasized: true)
            Divider()
            MetricRow(label: "Input", value: UsageViewModel.shortTokens(summary.inputTokens), icon: "arrow.down.left")
            MetricRow(label: "Output", value: UsageViewModel.shortTokens(summary.outputTokens), icon: "arrow.up.right")
            MetricRow(label: "Cache read", value: UsageViewModel.shortTokens(summary.cacheReadTokens), icon: "tray.and.arrow.down")
            MetricRow(label: "Cache write", value: UsageViewModel.shortTokens(summary.cacheWriteTokens), icon: "tray.and.arrow.up")
            MetricRow(label: "Authoritative events", value: "\(summary.authoritativeEvents)", icon: "checkmark.seal")
            MetricRow(label: "Estimated events", value: "\(summary.estimatedEvents)", icon: "questionmark.circle")
        }
        .card()
    }

    private func rateLimitCard(_ provider: UsageProviderKind) -> some View {
        let limits = viewModel.summary.rateLimits(for: provider)
        let observedAt = limits.compactMap(\.observedAt).max()
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("\(provider.displayName) rate limits", systemImage: "hourglass")
                    .font(.headline)
                Spacer()
                Text(observedAt.map { "snapshot \(UsageFormat.age($0))" } ?? "no rate snapshot")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(limits) { limit in
                LimitRow(limit: limit)
            }

            if provider == .claude, observedAt == nil {
                Text(viewModel.claudeBridgeObservedAt == nil
                    ? "Claude Code only reports its limits to a status line command. Add the bridge from Settings to see percentages and reset times; until then these are local token counts for the rolling window."
                    : "The last snapshot has expired. New limits arrive the next time Claude Code updates its status line; until then these are local token counts for the rolling window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card()
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
                let models = summary.modelBreakdown.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                ForEach(models, id: \.key) { model in
                    MetricRow(label: model.key, value: UsageViewModel.shortTokens(model.value), icon: "cpu")
                }
            }
        }
        .card()
    }

    private var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Floating Window")
                    .font(.headline)

                Toggle("Keep a compact usage window on top of other apps", isOn: Binding(
                    get: { floatingPanel.isVisible },
                    set: { $0 ? floatingPanel.show() : floatingPanel.hide() }
                ))
                .font(.subheadline)

                Text("Drag it anywhere; it stays visible on every Space and remembers its position.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                claudeBridgeSettings

                Divider()

                Text("Data & Privacy")
                    .font(.headline)

                Text("Local conversation text is read in memory for fallback token estimation and is not stored in the cache.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
        }
    }
}

private extension UsageDashboardView {
    var claudeBridgeSettings: some View {
        let observedAt = viewModel.claudeBridgeObservedAt
        let snippet = UsageViewModel.claudeBridgeSettingsSnippet
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Claude 5h / 7 days Limits")
                    .font(.headline)
                Spacer()
                Label(
                    observedAt.map { "active · \(UsageFormat.age($0))" } ?? "not set up",
                    systemImage: observedAt == nil ? "circle.dashed" : "checkmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(observedAt == nil ? Color.secondary : Color.green)
            }

            Text("Claude Code passes its subscription limits only to a status line command. Add this to ~/.claude/settings.json and UsageQuery records the two percentages and reset times each time Claude Code updates its status line. Nothing else from the status line is stored.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(snippet)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snippet, forType: .string)
                }
                Text("Already have a status line? Append  -- <your command>  to keep it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private extension View {
    func card() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}

private extension ProviderUsageSummary {
    var confidenceText: String {
        if authoritativeEvents > 0 && estimatedEvents > 0 {
            return "\(authoritativeEvents) authoritative · \(estimatedEvents) estimated"
        }
        if authoritativeEvents > 0 {
            return "authoritative"
        }
        return estimatedEvents > 0 ? "estimated" : "no usage"
    }
}

/// Share of the period total, in a neutral colour so it does not read as a limit.
private struct ShareBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                if fraction > 0 {
                    Capsule()
                        .fill(Color.accentColor.opacity(0.7))
                        .frame(width: max(3, proxy.size.width * min(1, fraction)))
                }
            }
        }
        .frame(height: 3)
    }
}

/// 5h / 7 days meters for one agent on the overview.
private struct LimitsCard: View {
    let provider: UsageProviderKind
    let limits: [CodexLimitSummary]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(provider.displayName, systemImage: provider.symbolName)
                    .font(.headline)
                Spacer()
                Text(limits.compactMap(\.observedAt).max().map { "snapshot \(UsageFormat.age($0))" } ?? "no rate snapshot")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(limits) { limit in
                LimitRemainingRow(limit: limit)
            }
        }
        .card()
    }
}

/// One limit meter for the overview cards.
private struct LimitRemainingRow: View {
    let limit: CodexLimitSummary

    var body: some View {
        if let remaining = limit.remainingPercent {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(limit.window.displayName)
                        .font(.subheadline)
                    Spacer()
                    if let resetAt = limit.resetAt {
                        Text("resets \(UsageFormat.reset(resetAt))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("\(remaining)% left")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(limit.isNearLimit ? limit.tint : .primary)
                        .frame(minWidth: 70, alignment: .trailing)
                }
                LimitBar(limit: limit)
            }
        } else {
            // No bar without a limit: an empty track would read as "nothing used".
            HStack(alignment: .firstTextBaseline) {
                Text(limit.window.displayName)
                    .font(.subheadline)
                Spacer()
                Text("\(UsageViewModel.shortTokens(limit.usedTokens)) used · limit unknown")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Detailed limit meter for the provider tabs.
private struct LimitRow: View {
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
                    .foregroundStyle(limit.isNearLimit ? limit.tint : .secondary)
            }

            if limit.progress != nil {
                LimitBar(limit: limit, height: 6)
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
        if let remainingPercent = limit.remainingPercent {
            if let remaining = limit.remainingTokens {
                return "\(remainingPercent)% left · ~\(UsageViewModel.shortTokens(remaining))"
            }
            return "\(remainingPercent)% left"
        }
        return "remaining unknown"
    }

    private var detailText: String {
        let used = UsageViewModel.shortTokens(limit.usedTokens)
        if let inferredLimit = limit.inferredLimitTokens, let usedPercent = limit.usedPercent {
            return "\(usedPercent)% reported · \(used) / ~\(UsageViewModel.shortTokens(inferredLimit)) inferred"
        }
        if let usedPercent = limit.usedPercent {
            return "\(usedPercent)% reported · \(used) used locally"
        }
        return "\(used) used locally"
    }

    private var resetText: String {
        guard let resetAt = limit.resetAt else {
            return "rolling \(limit.shortWindowName) window"
        }
        return "resets \(UsageFormat.reset(resetAt))"
    }
}

private struct MetricRow: View {
    let label: String
    let value: String
    let icon: String
    var emphasized = false

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
                .foregroundStyle(emphasized ? .primary : .secondary)
        }
        .font(emphasized ? .subheadline.weight(.semibold) : .subheadline)
    }
}
