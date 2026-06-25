import Foundation

public struct ClaudeUsageProvider: UsageProvider {
    public let kind: UsageProviderKind = .claude
    private let homeDirectory: URL
    private let estimator: TokenEstimator

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, estimator: TokenEstimator = TokenEstimator()) {
        self.homeDirectory = homeDirectory
        self.estimator = estimator
    }

    public func scanLocal(since: Date?) throws -> [UsageEvent] {
        let files = jsonlFiles()
        var events: [UsageEvent] = []
        var seen = Set<String>()

        for file in files {
            guard let reader = LineReader(url: file) else {
                continue
            }
            for line in reader {
                guard let object = JSONUtilities.object(from: line),
                      let timestamp = JSONUtilities.isoDate(object["timestamp"]) ?? timestampFromUUIDFallback(object),
                      since.map({ timestamp >= $0 }) ?? true,
                      let event = event(from: object, timestamp: timestamp)
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

        return events
    }

    public func estimateFromConversation(_ record: ConversationRecord) -> UsageEvent? {
        let tokens = estimator.estimateTextTokens(record.contentText, provider: .claude)
        guard tokens > 0 else {
            return nil
        }

        let role = record.role?.lowercased()
        let input = role == "assistant" ? 0 : tokens
        let output = role == "assistant" ? tokens : 0

        return UsageEvent(
            provider: .claude,
            source: .localConversationEstimate,
            timestamp: record.timestamp,
            sessionId: record.sessionId,
            requestId: record.messageId,
            model: record.model,
            inputTokens: input,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            outputTokens: output,
            confidence: .estimated
        )
    }

    public func healthCheck() -> ProviderHealth {
        let files = jsonlFiles()
        if files.isEmpty {
            return ProviderHealth(provider: .claude, isAvailable: false, message: "No Claude project JSONL files found")
        }
        return ProviderHealth(provider: .claude, isAvailable: true, message: "\(files.count) local conversation file\(files.count == 1 ? "" : "s")")
    }

    private func jsonlFiles() -> [URL] {
        let root = homeDirectory.appendingPathComponent(".claude/projects")
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

    private func event(from object: [String: Any], timestamp: Date) -> UsageEvent? {
        guard let message = JSONUtilities.dictionary(object["message"]) else {
            return nil
        }

        let sessionId = JSONUtilities.stringValue(object["sessionId"])
        let messageId = JSONUtilities.stringValue(message["id"]) ?? JSONUtilities.stringValue(object["uuid"])
        let model = JSONUtilities.stringValue(message["model"])
        let role = JSONUtilities.stringValue(message["role"])

        if let usage = JSONUtilities.dictionary(message["usage"]) {
            let input = JSONUtilities.intValue(usage["input_tokens"])
            let output = JSONUtilities.intValue(usage["output_tokens"])
            let cacheRead = JSONUtilities.intValue(usage["cache_read_input_tokens"])
            let cacheWrite = JSONUtilities.intValue(usage["cache_creation_input_tokens"])
            let total = input + output + cacheRead + cacheWrite
            guard total > 0 else {
                return nil
            }
            return UsageEvent(
                provider: .claude,
                source: .localUsageLog,
                timestamp: timestamp,
                sessionId: sessionId,
                requestId: messageId,
                model: model,
                inputTokens: input,
                cacheReadTokens: cacheRead,
                cacheWriteTokens: cacheWrite,
                outputTokens: output,
                totalTokens: total,
                confidence: .authoritative
            )
        }

        guard let content = message["content"] else {
            return nil
        }
        let text = extractText(from: content)
        let record = ConversationRecord(
            provider: .claude,
            timestamp: timestamp,
            sessionId: sessionId,
            messageId: messageId ?? JSONUtilities.stringValue(object["uuid"]),
            model: model,
            role: role,
            contentText: text
        )
        return estimateFromConversation(record)
    }

    private func extractText(from value: Any) -> String {
        if let string = value as? String {
            return string
        }
        if let array = JSONUtilities.array(value) {
            return array.map(extractText).joined(separator: "\n")
        }
        if let dictionary = JSONUtilities.dictionary(value) {
            if let text = JSONUtilities.stringValue(dictionary["text"]) {
                return text
            }
            if let content = dictionary["content"] {
                return extractText(from: content)
            }
            if let input = dictionary["input"] {
                return JSONUtilities.jsonString(input)
            }
            return dictionary.values.map(extractText).joined(separator: "\n")
        }
        return ""
    }

    private func timestampFromUUIDFallback(_ object: [String: Any]) -> Date? {
        guard JSONUtilities.stringValue(object["uuid"]) != nil else {
            return nil
        }
        return nil
    }
}

private final class LineReader: Sequence, IteratorProtocol {
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
