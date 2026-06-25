import Foundation

public struct CodexUsageProvider: UsageProvider {
    public let kind: UsageProviderKind = .codex
    private let homeDirectory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    public func scanLocal(since: Date?) throws -> [UsageEvent] {
        try scanSessionUsage(since: since)
    }

    public func scanRateLimitSnapshots(since: Date?) throws -> [CodexRateLimitSnapshot] {
        var seen = Set<String>()
        var snapshots: [CodexRateLimitSnapshot] = []

        for snapshot in try scanSessionRateLimitSnapshots(since: since) {
            guard !seen.contains(snapshot.id) else {
                continue
            }
            seen.insert(snapshot.id)
            snapshots.append(snapshot)
        }

        return snapshots
    }

    public func healthCheck() -> ProviderHealth {
        let sessions = sessionFiles()
        if sessions.isEmpty {
            return ProviderHealth(provider: .codex, isAvailable: false, message: "No Codex session files found")
        }
        return ProviderHealth(provider: .codex, isAvailable: true, message: "\(sessions.count) session file\(sessions.count == 1 ? "" : "s")")
    }

    private func sessionRoot() -> URL {
        homeDirectory.appendingPathComponent(".codex/sessions")
    }

    private func scanSessionUsage(since: Date?) throws -> [UsageEvent] {
        var events: [UsageEvent] = []
        var seen = Set<String>()

        for file in sessionFiles() {
            guard let reader = CodexLineReader(url: file) else {
                continue
            }
            let fileSessionId = sessionId(fromFile: file)
            var fileModel: String?
            for line in reader {
                guard line.contains(#""type":"token_count""#) || line.contains(#""model""#),
                      let object = JSONUtilities.object(from: line)
                else {
                    continue
                }
                fileModel = model(from: object) ?? fileModel

                guard line.contains(#""type":"token_count""#),
                      let timestamp = JSONUtilities.isoDate(object["timestamp"]),
                      since.map({ timestamp >= $0 }) ?? true,
                      let event = sessionUsageEvent(from: object, timestamp: timestamp, fileSessionId: fileSessionId, fileModel: fileModel)
                else {
                    continue
                }
                guard !seen.contains(event.dedupeKey) else {
                    continue
                }
                seen.insert(event.dedupeKey)
                events.append(event)
            }
        }

        return events.sorted { $0.timestamp < $1.timestamp }
    }

    private func scanSessionRateLimitSnapshots(since: Date?) throws -> [CodexRateLimitSnapshot] {
        var snapshots: [CodexRateLimitSnapshot] = []

        for file in sessionFiles() {
            guard let reader = CodexLineReader(url: file) else {
                continue
            }
            for line in reader {
                guard line.contains(#""rate_limits""#),
                      let object = JSONUtilities.object(from: line),
                      let timestamp = JSONUtilities.isoDate(object["timestamp"]),
                      since.map({ timestamp >= $0 }) ?? true,
                      JSONUtilities.stringValue(object["type"]) == "event_msg",
                      let payload = JSONUtilities.dictionary(object["payload"]),
                      JSONUtilities.stringValue(payload["type"]) == "token_count",
                      let rateLimits = JSONUtilities.dictionary(payload["rate_limits"])
                else {
                    continue
                }
                snapshots.append(contentsOf: parseSessionRateLimitSnapshots(rateLimits: rateLimits, observedAt: timestamp))
            }
        }

        return snapshots
    }

    private func sessionFiles() -> [URL] {
        let root = sessionRoot()
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return enumerator.compactMap { item -> URL? in
            guard let url = item as? URL,
                  url.pathExtension == "jsonl",
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else {
                return nil
            }
            return url
        }
        .sorted { $0.path < $1.path }
    }

    private func sessionUsageEvent(from object: [String: Any], timestamp: Date, fileSessionId: String?, fileModel: String?) -> UsageEvent? {
        guard JSONUtilities.stringValue(object["type"]) == "event_msg",
              let payload = JSONUtilities.dictionary(object["payload"]),
              JSONUtilities.stringValue(payload["type"]) == "token_count",
              let info = JSONUtilities.dictionary(payload["info"]),
              let usage = JSONUtilities.dictionary(info["last_token_usage"])
        else {
            return nil
        }

        let input = JSONUtilities.intValue(usage["input_tokens"])
        let output = JSONUtilities.intValue(usage["output_tokens"])
        let cacheRead = JSONUtilities.intValue(usage["cached_input_tokens"])
        let cacheWrite = JSONUtilities.intValue(usage["cache_creation_input_tokens"])
        let total = JSONUtilities.intValue(usage["total_tokens"])
        guard input + output + cacheRead + cacheWrite + total > 0 else {
            return nil
        }

        let sessionId = sessionId(from: object) ?? fileSessionId
        let model = model(from: object) ?? fileModel
        return UsageEvent(
            provider: .codex,
            source: .localUsageLog,
            timestamp: timestamp,
            sessionId: sessionId,
            requestId: sessionId.map { "session:\($0):\(Int(timestamp.timeIntervalSince1970 * 1000))" },
            model: model,
            inputTokens: input,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
            outputTokens: output,
            totalTokens: total > 0 ? total : nil,
            confidence: .authoritative
        )
    }

    private func sessionId(from object: [String: Any]) -> String? {
        if let sessionId = JSONUtilities.stringValue(object["session_id"]) {
            return sessionId
        }
        if let payload = JSONUtilities.dictionary(object["payload"]),
           let sessionId = JSONUtilities.stringValue(payload["session_id"]) {
            return sessionId
        }
        return nil
    }

    private func sessionId(fromFile file: URL) -> String? {
        let name = file.deletingPathExtension().lastPathComponent
        guard let range = name.range(of: #"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$"#, options: .regularExpression) else {
            return nil
        }
        return String(name[range])
    }

    private func model(from object: [String: Any]) -> String? {
        guard let payload = JSONUtilities.dictionary(object["payload"]) else {
            return nil
        }
        if let model = JSONUtilities.stringValue(payload["model"]) {
            return model
        }
        if let collaborationMode = JSONUtilities.dictionary(payload["collaboration_mode"]),
           let settings = JSONUtilities.dictionary(collaborationMode["settings"]),
           let model = JSONUtilities.stringValue(settings["model"]) {
            return model
        }
        return nil
    }

    private func parseSessionRateLimitSnapshots(rateLimits: [String: Any], observedAt: Date) -> [CodexRateLimitSnapshot] {
        let planType = JSONUtilities.stringValue(rateLimits["plan_type"])
        let limitReached = JSONUtilities.stringValue(rateLimits["rate_limit_reached_type"]) != nil

        return ["primary", "secondary"].compactMap { key in
            guard let window = JSONUtilities.dictionary(rateLimits[key]) else {
                return nil
            }
            let windowMinutes = JSONUtilities.intValue(window["window_minutes"])
            guard let rateLimitWindow = CodexRateLimitWindow.from(windowMinutes: windowMinutes) else {
                return nil
            }
            let usedPercent = min(100, max(0, JSONUtilities.intValue(window["used_percent"])))
            let resetAtSeconds = JSONUtilities.intValue(window["resets_at"])
            let resetAt = resetAtSeconds > 0 ? Date(timeIntervalSince1970: Double(resetAtSeconds)) : nil

            return CodexRateLimitSnapshot(
                window: rateLimitWindow,
                observedAt: observedAt,
                usedPercent: usedPercent,
                resetAt: resetAt,
                resetAfterSeconds: resetAt.map { max(0, Int($0.timeIntervalSince(observedAt))) },
                allowed: !limitReached,
                limitReached: limitReached,
                planType: planType
            )
        }
    }

}

private final class CodexLineReader: Sequence, IteratorProtocol {
    private let handle: FileHandle
    private let delimiter = Data([0x0A])
    private var buffer = Data()
    private var isAtEOF = false

    init?(url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        self.handle = handle
    }

    deinit {
        try? handle.close()
    }

    func next() -> String? {
        while true {
            if let range = buffer.range(of: delimiter) {
                let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return String(data: line, encoding: .utf8)
            }

            if isAtEOF {
                if buffer.isEmpty {
                    return nil
                }
                let line = buffer
                buffer.removeAll()
                return String(data: line, encoding: .utf8)
            }

            if let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                buffer.append(chunk)
            } else {
                isAtEOF = true
            }
        }
    }
}
