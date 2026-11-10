import Foundation

public final class UsageCache: @unchecked Sendable {
    private let database: SQLiteDatabase

    public init(path: String) throws {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.database = try SQLiteDatabase(path: path, readOnly: false)
        try migrate()
    }

    public func replaceEvents(_ events: [UsageEvent]) throws {
        try database.execute("BEGIN TRANSACTION")
        do {
            try database.execute("DELETE FROM usage_events")
            for event in events {
                try insert(event)
            }
            try database.execute("COMMIT")
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }
    }

    public func loadEvents(since: Date? = nil) throws -> [UsageEvent] {
        var sql = """
        SELECT provider, source, timestamp, session_id, request_id, model,
               input_tokens, cache_read_tokens, cache_write_tokens, output_tokens,
               total_tokens, estimated_cost_usd, confidence
        FROM usage_events
        """
        var bindings: [SQLiteBinding] = []
        if let since {
            sql += " WHERE timestamp >= ?"
            bindings.append(.double(since.timeIntervalSince1970))
        }
        sql += " ORDER BY timestamp ASC"

        return try database.query(sql, bindings: bindings).compactMap { row in
            guard let providerRaw = row["provider"]?.stringValue,
                  let provider = UsageProviderKind(rawValue: providerRaw),
                  let sourceRaw = row["source"]?.stringValue,
                  let source = UsageSource(rawValue: sourceRaw),
                  let timestamp = row["timestamp"]?.doubleValue,
                  let confidenceRaw = row["confidence"]?.stringValue,
                  let confidence = UsageConfidence(rawValue: confidenceRaw)
            else {
                return nil
            }
            return UsageEvent(
                provider: provider,
                source: source,
                timestamp: Date(timeIntervalSince1970: timestamp),
                sessionId: row["session_id"]?.stringValue,
                requestId: row["request_id"]?.stringValue,
                model: row["model"]?.stringValue,
                inputTokens: row["input_tokens"]?.intValue ?? 0,
                cacheReadTokens: row["cache_read_tokens"]?.intValue ?? 0,
                cacheWriteTokens: row["cache_write_tokens"]?.intValue ?? 0,
                outputTokens: row["output_tokens"]?.intValue ?? 0,
                totalTokens: row["total_tokens"]?.intValue,
                estimatedCostUsd: row["estimated_cost_usd"]?.doubleValue,
                confidence: confidence
            )
        }
    }

    public func replaceRateLimitSnapshots(_ snapshots: [CodexRateLimitSnapshot]) throws {
        try database.execute("BEGIN TRANSACTION")
        do {
            try database.execute("DELETE FROM codex_rate_limit_snapshots")
            for snapshot in snapshots {
                try database.update(
                    """
                    INSERT OR REPLACE INTO codex_rate_limit_snapshots (
                        snapshot_id, window, observed_at, used_percent, reset_at,
                        reset_after_seconds, allowed, limit_reached, plan_type
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .text(snapshot.id),
                        .text(snapshot.window.rawValue),
                        .double(snapshot.observedAt.timeIntervalSince1970),
                        .int(snapshot.usedPercent),
                        snapshot.resetAt.map { SQLiteBinding.double($0.timeIntervalSince1970) } ?? .null,
                        snapshot.resetAfterSeconds.map(SQLiteBinding.int) ?? .null,
                        .int(snapshot.allowed ? 1 : 0),
                        .int(snapshot.limitReached ? 1 : 0),
                        snapshot.planType.map(SQLiteBinding.text) ?? .null
                    ]
                )
            }
            try database.execute("COMMIT")
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }
    }

    public func loadRateLimitSnapshots() throws -> [CodexRateLimitSnapshot] {
        try database.query(
            """
            SELECT window, observed_at, used_percent, reset_at, reset_after_seconds,
                   allowed, limit_reached, plan_type
            FROM codex_rate_limit_snapshots ORDER BY observed_at ASC
            """
        ).compactMap { row in
            guard let windowRaw = row["window"]?.stringValue,
                  let window = CodexRateLimitWindow(rawValue: windowRaw),
                  let observedAt = row["observed_at"]?.doubleValue
            else {
                return nil
            }
            return CodexRateLimitSnapshot(
                window: window,
                observedAt: Date(timeIntervalSince1970: observedAt),
                usedPercent: row["used_percent"]?.intValue ?? 0,
                resetAt: row["reset_at"]?.doubleValue.map { Date(timeIntervalSince1970: $0) },
                resetAfterSeconds: row["reset_after_seconds"]?.intValue,
                allowed: (row["allowed"]?.intValue ?? 1) != 0,
                limitReached: (row["limit_reached"]?.intValue ?? 0) != 0,
                planType: row["plan_type"]?.stringValue
            )
        }
    }

    private func migrate() throws {
        try database.execute("""
        CREATE TABLE IF NOT EXISTS codex_rate_limit_snapshots (
            snapshot_id TEXT PRIMARY KEY,
            window TEXT NOT NULL,
            observed_at REAL NOT NULL,
            used_percent INTEGER NOT NULL,
            reset_at REAL,
            reset_after_seconds INTEGER,
            allowed INTEGER NOT NULL,
            limit_reached INTEGER NOT NULL,
            plan_type TEXT
        )
        """)
        try database.execute("""
        CREATE TABLE IF NOT EXISTS usage_events (
            dedupe_key TEXT PRIMARY KEY,
            provider TEXT NOT NULL,
            source TEXT NOT NULL,
            timestamp REAL NOT NULL,
            session_id TEXT,
            request_id TEXT,
            model TEXT,
            input_tokens INTEGER NOT NULL,
            cache_read_tokens INTEGER NOT NULL,
            cache_write_tokens INTEGER NOT NULL,
            output_tokens INTEGER NOT NULL,
            total_tokens INTEGER NOT NULL,
            estimated_cost_usd REAL,
            confidence TEXT NOT NULL
        )
        """)
        try database.execute("CREATE INDEX IF NOT EXISTS idx_usage_events_timestamp ON usage_events(timestamp)")
        try database.execute("CREATE INDEX IF NOT EXISTS idx_usage_events_provider ON usage_events(provider)")
    }

    private func insert(_ event: UsageEvent) throws {
        try database.update(
            """
            INSERT OR REPLACE INTO usage_events (
                dedupe_key, provider, source, timestamp, session_id, request_id, model,
                input_tokens, cache_read_tokens, cache_write_tokens, output_tokens,
                total_tokens, estimated_cost_usd, confidence
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(event.dedupeKey),
                .text(event.provider.rawValue),
                .text(event.source.rawValue),
                .double(event.timestamp.timeIntervalSince1970),
                event.sessionId.map(SQLiteBinding.text) ?? .null,
                event.requestId.map(SQLiteBinding.text) ?? .null,
                event.model.map(SQLiteBinding.text) ?? .null,
                .int(event.inputTokens),
                .int(event.cacheReadTokens),
                .int(event.cacheWriteTokens),
                .int(event.outputTokens),
                .int(event.totalTokens),
                event.estimatedCostUsd.map(SQLiteBinding.double) ?? .null,
                .text(event.confidence.rawValue)
            ]
        )
    }
}
