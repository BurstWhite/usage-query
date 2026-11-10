import SwiftUI
import UsageQueryCore

enum UsageFormat {
    /// 24-hour clock, independent of locale so it sits cleanly in English labels.
    static func clock(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }

    /// Time until a reset: `in 12m`, `in 2h 14m`, `in 2d 7h`.
    static func reset(_ date: Date, now: Date = Date()) -> String {
        "in \(countdown(to: date, now: now))"
    }

    static func countdown(to date: Date, now: Date = Date()) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds >= 60 else {
            return "<1m"
        }
        if seconds < 60 * 60 {
            return "\(seconds / 60)m"
        }
        if seconds < 24 * 60 * 60 {
            return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
        }
        return "\(seconds / 86_400)d \((seconds % 86_400) / 3600)h"
    }

    static func age(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 {
            return "just now"
        }
        if seconds < 60 * 60 {
            return "\(seconds / 60)m ago"
        }
        if seconds < 24 * 60 * 60 {
            return "\(seconds / 3600)h ago"
        }
        return "\(seconds / 86_400)d ago"
    }
}

extension CodexLimitSummary {
    var tint: Color {
        let used = progress ?? 0
        if limitReached || used >= 0.95 {
            return .red
        }
        return used >= 0.8 ? .orange : .green
    }

    var shortWindowName: String {
        window == .fiveHours ? "5h" : "7d"
    }
}

extension UsageProviderKind {
    var symbolName: String {
        switch self {
        case .codex: "terminal"
        case .claude: "sparkles"
        }
    }
}

/// Thin usage bar: fill grows with the share of the window already used.
struct LimitBar: View {
    let limit: CodexLimitSummary
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                if let progress = limit.progress, progress > 0 {
                    Capsule()
                        .fill(limit.tint)
                        .frame(width: max(height, proxy.size.width * progress))
                }
            }
        }
        .frame(height: height)
    }
}
