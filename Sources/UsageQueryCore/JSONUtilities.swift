import Foundation

enum JSONUtilities {
    private nonisolated(unsafe) static let fractionalISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated(unsafe) static let plainISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func object(from line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func intValue(_ value: Any?) -> Int {
        switch value {
        case let int as Int:
            return int
        case let int64 as Int64:
            return Int(int64)
        case let double as Double:
            guard double.isFinite else {
                return 0
            }
            if double >= Double(Int.max) { return Int.max }
            if double <= Double(Int.min) { return Int.min }
            return Int(double)
        case let string as String:
            return Int(string) ?? 0
        default:
            return 0
        }
    }

    static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string.isEmpty ? nil : string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func array(_ value: Any?) -> [Any]? {
        value as? [Any]
    }

    static func isoDate(_ value: Any?) -> Date? {
        guard let string = stringValue(value) else {
            return nil
        }
        if let date = fractionalISOFormatter.date(from: string) {
            return date
        }
        return plainISOFormatter.date(from: string)
    }

    static func jsonString(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else {
            return String(describing: value)
        }
        return string
    }

}

/// Streams a file line by line without loading it wholesale. Invalid UTF-8 is
/// repaired instead of ending iteration, so one bad line cannot truncate a file.
final class LineReader: Sequence, IteratorProtocol {
    private let handle: FileHandle
    private var buffer = Data()
    private var scanOffset = 0
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
            if let index = buffer[scanOffset...].firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[scanOffset..<index], as: UTF8.self)
                scanOffset = index + 1
                compactIfNeeded()
                return line
            }

            if isAtEOF {
                if scanOffset >= buffer.count {
                    return nil
                }
                let line = String(decoding: buffer[scanOffset...], as: UTF8.self)
                buffer.removeAll()
                scanOffset = 0
                return line
            }

            if let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                buffer.append(chunk)
            } else {
                isAtEOF = true
            }
        }
    }

    private func compactIfNeeded() {
        if scanOffset >= 256 * 1024 {
            buffer.removeSubrange(0..<scanOffset)
            scanOffset = 0
        }
    }
}
