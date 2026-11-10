import Foundation

/// Claude Code only exposes its 5h / 7 days limit state to status line commands
/// (the `rate_limits` field of the JSON piped to them). The bridge keeps the
/// latest numbers from that payload in a small file the provider can read.
///
/// Only percentages and timestamps are written; the rest of the status line
/// payload (paths, session ids, model, cost) is dropped.
public enum ClaudeRateLimitBridge {
    public static func fileURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory.appendingPathComponent("Library/Application Support/UsageQuery/claude-rate-limits.json")
    }

    /// Parses a status line payload. Returns no snapshots when `rate_limits` is
    /// absent, which happens for API-key sessions and before the first response.
    public static func snapshots(fromStatusLineJSON data: Data, observedAt: Date = Date()) -> [CodexRateLimitSnapshot] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rateLimits = JSONUtilities.dictionary(object["rate_limits"])
        else {
            return []
        }
        return snapshots(fromRateLimits: rateLimits, observedAt: observedAt)
    }

    /// Records the payload's limits. Windows the payload omits keep their
    /// previous value, and so do windows where the payload is older than what is
    /// stored: every Claude Code session reports its own last-seen numbers, so an
    /// idle session can re-send an expired block or a lower percentage.
    /// Returns what is now stored.
    @discardableResult
    public static func record(
        statusLineJSON data: Data,
        observedAt: Date = Date(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> [CodexRateLimitSnapshot] {
        let stored = loadSnapshots(homeDirectory: homeDirectory)
        let fresh = snapshots(fromStatusLineJSON: data, observedAt: observedAt).filter { candidate in
            supersedes(candidate, stored.first { $0.window == candidate.window })
        }
        guard !fresh.isEmpty else {
            return stored
        }
        let freshWindows = Set(fresh.map(\.window))
        let merged = fresh + stored.filter { !freshWindows.contains($0.window) }

        var windows: [String: Any] = [:]
        for snapshot in merged {
            var entry: [String: Any] = [
                "used_percentage": snapshot.usedPercent,
                "observed_at": Int(snapshot.observedAt.timeIntervalSince1970)
            ]
            if let resetAt = snapshot.resetAt {
                entry["resets_at"] = Int(resetAt.timeIntervalSince1970)
            }
            windows[key(for: snapshot.window)] = entry
        }

        let url = fileURL(homeDirectory: homeDirectory)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let output = try JSONSerialization.data(withJSONObject: ["rate_limits": windows], options: [.sortedKeys])
        try output.write(to: url, options: .atomic)
        return merged
    }

    public static func loadSnapshots(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> [CodexRateLimitSnapshot] {
        guard let data = try? Data(contentsOf: fileURL(homeDirectory: homeDirectory)),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rateLimits = JSONUtilities.dictionary(object["rate_limits"])
        else {
            return []
        }
        return snapshots(fromRateLimits: rateLimits, observedAt: nil)
    }

    /// Short text for the status line itself, e.g. `5h 42% · 7d 18%`.
    public static func statusLineText(for snapshots: [CodexRateLimitSnapshot]) -> String {
        CodexRateLimitWindow.allCases.compactMap { window in
            snapshots.first { $0.window == window }.map { "\(window == .fiveHours ? "5h" : "7d") \($0.usedPercent)%" }
        }
        .joined(separator: " · ")
    }

    private static func supersedes(_ candidate: CodexRateLimitSnapshot, _ stored: CodexRateLimitSnapshot?) -> Bool {
        if let resetAt = candidate.resetAt, resetAt <= candidate.observedAt {
            return false
        }
        guard let stored, let storedReset = stored.resetAt, storedReset > candidate.observedAt else {
            return true
        }
        guard let candidateReset = candidate.resetAt else {
            return false
        }
        // Reset times for one block can differ by a little between reports.
        let slack: TimeInterval = 120
        if candidateReset < storedReset - slack {
            return false
        }
        if candidateReset > storedReset + slack {
            return true
        }
        // Same block: usage only grows until the reset.
        return candidate.usedPercent >= stored.usedPercent
    }

    private static func key(for window: CodexRateLimitWindow) -> String {
        switch window {
        case .fiveHours: "five_hour"
        case .sevenDays: "seven_day"
        }
    }

    private static func snapshots(fromRateLimits rateLimits: [String: Any], observedAt: Date?) -> [CodexRateLimitSnapshot] {
        CodexRateLimitWindow.allCases.compactMap { window in
            guard let entry = JSONUtilities.dictionary(rateLimits[key(for: window)]),
                  let used = (entry["used_percentage"] as? NSNumber)?.doubleValue, used.isFinite
            else {
                return nil
            }
            let storedObservedAt = (entry["observed_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            guard let observed = observedAt ?? storedObservedAt else {
                return nil
            }
            let usedPercent = min(100, max(0, Int(used.rounded())))
            let resetAt = resetDate(entry["resets_at"])
            return CodexRateLimitSnapshot(
                provider: .claude,
                window: window,
                observedAt: observed,
                usedPercent: usedPercent,
                resetAt: resetAt,
                resetAfterSeconds: resetAt.map { max(0, Int($0.timeIntervalSince(observed))) },
                allowed: usedPercent < 100,
                limitReached: usedPercent >= 100,
                planType: nil
            )
        }
    }

    private static func resetDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber, number.doubleValue > 0 {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        return JSONUtilities.isoDate(value)
    }
}
