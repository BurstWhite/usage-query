import Foundation

public enum UsageProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex
    case claude

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        }
    }
}

public enum UsageSource: String, Codable, Sendable {
    case localUsageLog
    case localConversationEstimate
    case remoteAPI
    case manualBudget

    public var displayName: String {
        switch self {
        case .localUsageLog: "Local usage log"
        case .localConversationEstimate: "Local estimate"
        case .remoteAPI: "Remote API"
        case .manualBudget: "Manual budget"
        }
    }
}

public enum UsageConfidence: String, Codable, Sendable {
    case authoritative
    case estimated

    public var displayName: String {
        switch self {
        case .authoritative: "Authoritative"
        case .estimated: "Estimated"
        }
    }
}

public enum UsagePeriod: String, Codable, CaseIterable, Identifiable, Sendable {
    case today
    case sevenDays
    case thirtyDays

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .today: "Today"
        case .sevenDays: "7 days"
        case .thirtyDays: "30 days"
        }
    }

    public func startDate(now: Date = Date(), calendar: Calendar = .current) -> Date {
        switch self {
        case .today:
            return calendar.startOfDay(for: now)
        case .sevenDays:
            return calendar.date(byAdding: .day, value: -7, to: now) ?? now
        case .thirtyDays:
            return calendar.date(byAdding: .day, value: -30, to: now) ?? now
        }
    }
}

public struct UsageEvent: Codable, Equatable, Identifiable, Sendable {
    public var id: String { dedupeKey }

    public let provider: UsageProviderKind
    public let source: UsageSource
    public let timestamp: Date
    public let sessionId: String?
    public let requestId: String?
    public let model: String?
    public let inputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int
    public let outputTokens: Int
    public let totalTokens: Int
    public let estimatedCostUsd: Double?
    public let confidence: UsageConfidence

    public init(
        provider: UsageProviderKind,
        source: UsageSource,
        timestamp: Date,
        sessionId: String?,
        requestId: String?,
        model: String?,
        inputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        outputTokens: Int,
        totalTokens: Int? = nil,
        estimatedCostUsd: Double? = nil,
        confidence: UsageConfidence
    ) {
        self.provider = provider
        self.source = source
        self.timestamp = timestamp
        self.sessionId = sessionId
        self.requestId = requestId
        self.model = model
        self.inputTokens = max(0, inputTokens)
        self.cacheReadTokens = max(0, cacheReadTokens)
        self.cacheWriteTokens = max(0, cacheWriteTokens)
        self.outputTokens = max(0, outputTokens)
        self.totalTokens = max(0, totalTokens ?? (inputTokens + cacheReadTokens + cacheWriteTokens + outputTokens))
        self.estimatedCostUsd = estimatedCostUsd
        self.confidence = confidence
    }

    public var dedupeKey: String {
        let explicitId = requestId ?? sessionId ?? "\(Int(timestamp.timeIntervalSince1970))"
        return [
            provider.rawValue,
            source.rawValue,
            explicitId,
            model ?? "unknown",
            "\(inputTokens)",
            "\(outputTokens)",
            "\(totalTokens)"
        ].joined(separator: "|")
    }
}

public struct ConversationRecord: Sendable {
    public let provider: UsageProviderKind
    public let timestamp: Date
    public let sessionId: String?
    public let messageId: String?
    public let model: String?
    public let role: String?
    public let contentText: String

    public init(
        provider: UsageProviderKind,
        timestamp: Date,
        sessionId: String?,
        messageId: String?,
        model: String?,
        role: String?,
        contentText: String
    ) {
        self.provider = provider
        self.timestamp = timestamp
        self.sessionId = sessionId
        self.messageId = messageId
        self.model = model
        self.role = role
        self.contentText = contentText
    }
}

public enum QuotaPeriod: String, Codable, Sendable {
    case day
    case week
    case month
    case unknown
}

public struct QuotaSnapshot: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(provider.rawValue)|\(period.rawValue)|\(source.rawValue)" }

    public let provider: UsageProviderKind
    public let period: QuotaPeriod
    public let usedTokens: Int
    public let limitTokens: Int?
    public let remainingTokens: Int?
    public let resetAt: Date?
    public let source: UsageSource
    public let freshness: Date
    public let isAuthoritative: Bool

    public init(
        provider: UsageProviderKind,
        period: QuotaPeriod,
        usedTokens: Int,
        limitTokens: Int?,
        remainingTokens: Int?,
        resetAt: Date?,
        source: UsageSource,
        freshness: Date,
        isAuthoritative: Bool
    ) {
        self.provider = provider
        self.period = period
        self.usedTokens = usedTokens
        self.limitTokens = limitTokens
        self.remainingTokens = remainingTokens
        self.resetAt = resetAt
        self.source = source
        self.freshness = freshness
        self.isAuthoritative = isAuthoritative
    }
}

public enum CodexRateLimitWindow: String, Codable, CaseIterable, Identifiable, Sendable {
    case fiveHours
    case sevenDays

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fiveHours: "5h"
        case .sevenDays: "7 days"
        }
    }

    public var duration: TimeInterval {
        switch self {
        case .fiveHours: 5 * 60 * 60
        case .sevenDays: 7 * 24 * 60 * 60
        }
    }

    public static func from(windowMinutes: Int) -> CodexRateLimitWindow? {
        switch windowMinutes {
        case 300:
            return .fiveHours
        case 10_080:
            return .sevenDays
        default:
            return nil
        }
    }
}

public struct CodexRateLimitSnapshot: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(window.rawValue)|\(Int(observedAt.timeIntervalSince1970))|\(usedPercent)" }

    public let window: CodexRateLimitWindow
    public let observedAt: Date
    public let usedPercent: Int
    public let resetAt: Date?
    public let resetAfterSeconds: Int?
    public let allowed: Bool
    public let limitReached: Bool
    public let planType: String?

    public init(
        window: CodexRateLimitWindow,
        observedAt: Date,
        usedPercent: Int,
        resetAt: Date?,
        resetAfterSeconds: Int?,
        allowed: Bool,
        limitReached: Bool,
        planType: String?
    ) {
        self.window = window
        self.observedAt = observedAt
        self.usedPercent = usedPercent
        self.resetAt = resetAt
        self.resetAfterSeconds = resetAfterSeconds
        self.allowed = allowed
        self.limitReached = limitReached
        self.planType = planType
    }
}

public struct ProviderHealth: Equatable, Sendable {
    public let provider: UsageProviderKind
    public let isAvailable: Bool
    public let message: String

    public init(provider: UsageProviderKind, isAvailable: Bool, message: String) {
        self.provider = provider
        self.isAvailable = isAvailable
        self.message = message
    }
}

public protocol UsageProvider: Sendable {
    var kind: UsageProviderKind { get }
    func scanLocal(since: Date?) throws -> [UsageEvent]
    func scanRateLimitSnapshots(since: Date?) throws -> [CodexRateLimitSnapshot]
    func estimateFromConversation(_ record: ConversationRecord) -> UsageEvent?
    func fetchRemote(range: DateInterval) async throws -> [QuotaSnapshot]
    func healthCheck() -> ProviderHealth
}

public extension UsageProvider {
    func scanRateLimitSnapshots(since _: Date?) throws -> [CodexRateLimitSnapshot] { [] }
    func estimateFromConversation(_: ConversationRecord) -> UsageEvent? { nil }
    func fetchRemote(range _: DateInterval) async throws -> [QuotaSnapshot] { [] }
}
