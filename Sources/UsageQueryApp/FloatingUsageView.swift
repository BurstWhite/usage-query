import SwiftUI
import UsageQueryCore

/// Compact always-on-top summary: the 5h / 7 days windows for each agent.
struct FloatingUsageView: View {
    static let width: CGFloat = 280

    @ObservedObject var viewModel: UsageViewModel
    let controller: FloatingPanelController
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                    .foregroundStyle(.secondary)
                Text("AI Usage")
                    .font(.caption.weight(.semibold))
                Spacer()
                if isHovering {
                    Button {
                        Task { await viewModel.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(viewModel.isRefreshing)
                    .help("Refresh")

                    Button {
                        controller.hide()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .help("Hide floating window")
                } else if let lastRefresh = viewModel.lastRefresh {
                    Text(UsageFormat.clock(lastRefresh))
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.caption)
            .buttonStyle(.plain)
            .frame(height: 14)

            ForEach(UsageProviderKind.allCases) { provider in
                providerSection(provider)
            }
        }
        .padding(12)
        .frame(width: Self.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.6)))
        .onHover { isHovering = $0 }
    }

    private func providerSection(_ provider: UsageProviderKind) -> some View {
        let limits = viewModel.summary.rateLimits(for: provider)
        let today = viewModel.todayTokens[provider] ?? 0
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(provider.displayName, systemImage: provider.symbolName)
                    .font(.caption.weight(.medium))
                Spacer()
                Text("\(UsageViewModel.shortTokens(today)) today")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ForEach(limits) { limit in
                FloatingLimitRow(limit: limit)
            }
        }
    }
}

private struct FloatingLimitRow: View {
    let limit: CodexLimitSummary

    var body: some View {
        HStack(spacing: 6) {
            Text(limit.shortWindowName)
                .frame(width: 16, alignment: .leading)
                .foregroundStyle(.secondary)
            if let remaining = limit.remainingPercent {
                LimitBar(limit: limit, height: 4)
                Text("\(remaining)% left")
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(limit.isNearLimit ? limit.tint : .primary)
                    .frame(width: 52, alignment: .trailing)
                HStack(spacing: 2) {
                    if let resetAt = limit.resetAt {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 7, weight: .semibold))
                        Text(UsageFormat.countdown(to: resetAt))
                            .monospacedDigit()
                    }
                }
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .trailing)
            } else {
                Text("\(UsageViewModel.shortTokens(limit.usedTokens)) used · limit unknown")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .font(.caption2)
        .help(helpText)
    }

    private var helpText: String {
        var parts = ["\(UsageViewModel.shortTokens(limit.usedTokens)) used in window"]
        if let resetAt = limit.resetAt {
            parts.append("resets \(UsageFormat.reset(resetAt))")
        } else {
            parts.append("no rate snapshot")
        }
        return parts.joined(separator: " · ")
    }
}
