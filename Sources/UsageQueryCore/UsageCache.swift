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

    private func migrate() throws {
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
