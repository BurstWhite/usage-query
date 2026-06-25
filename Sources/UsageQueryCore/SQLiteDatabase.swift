import Foundation
import SQLite3

public enum SQLiteDatabaseError: Error, CustomStringConvertible {
    case openFailed(path: String, message: String)
    case prepareFailed(sql: String, message: String)
    case stepFailed(message: String)
    case executeFailed(sql: String, message: String)

    public var description: String {
        switch self {
        case let .openFailed(path, message):
            "Could not open SQLite database at \(path): \(message)"
        case let .prepareFailed(sql, message):
            "Could not prepare SQLite statement \(sql): \(message)"
        case let .stepFailed(message):
            "Could not step SQLite statement: \(message)"
        case let .executeFailed(sql, message):
            "Could not execute SQLite statement \(sql): \(message)"
        }
    }
}

public final class SQLiteDatabase: @unchecked Sendable {
    private var db: OpaquePointer?
    private let readOnly: Bool

    public init(path: String, readOnly: Bool = true) throws {
        self.readOnly = readOnly
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
            : SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX
        let result = sqlite3_open_v2(path, &db, flags, nil)
        guard result == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let db {
                sqlite3_close(db)
            }
            throw SQLiteDatabaseError.openFailed(path: path, message: message)
        }
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    public func execute(_ sql: String) throws {
        guard !readOnly else {
            throw SQLiteDatabaseError.executeFailed(sql: sql, message: "database opened read-only")
        }

        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &error)
        if result != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(error)
            throw SQLiteDatabaseError.executeFailed(sql: sql, message: message)
        }
    }

    public func query(_ sql: String, bindings: [SQLiteBinding] = []) throws -> [[String: SQLiteValue]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteDatabaseError.prepareFailed(sql: sql, message: lastErrorMessage)
        }
        defer { sqlite3_finalize(statement) }

        try bind(bindings, to: statement)

        var rows: [[String: SQLiteValue]] = []
        while true {
            let result = sqlite3_step(statement)
            switch result {
            case SQLITE_ROW:
                rows.append(row(from: statement))
            case SQLITE_DONE:
                return rows
            default:
                throw SQLiteDatabaseError.stepFailed(message: lastErrorMessage)
            }
        }
    }

    public func update(_ sql: String, bindings: [SQLiteBinding] = []) throws {
        guard !readOnly else {
            throw SQLiteDatabaseError.executeFailed(sql: sql, message: "database opened read-only")
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteDatabaseError.prepareFailed(sql: sql, message: lastErrorMessage)
        }
        defer { sqlite3_finalize(statement) }

        try bind(bindings, to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            throw SQLiteDatabaseError.stepFailed(message: lastErrorMessage)
        }
    }

    private func bind(_ bindings: [SQLiteBinding], to statement: OpaquePointer?) throws {
        for (index, binding) in bindings.enumerated() {
            let sqliteIndex = Int32(index + 1)
            let result: Int32
            switch binding {
            case .null:
                result = sqlite3_bind_null(statement, sqliteIndex)
            case let .int(value):
                result = sqlite3_bind_int64(statement, sqliteIndex, sqlite3_int64(value))
            case let .double(value):
                result = sqlite3_bind_double(statement, sqliteIndex, value)
            case let .text(value):
                result = sqlite3_bind_text(statement, sqliteIndex, value, -1, SQLITE_TRANSIENT)
            }
            if result != SQLITE_OK {
                throw SQLiteDatabaseError.stepFailed(message: lastErrorMessage)
            }
        }
    }

    private func row(from statement: OpaquePointer?) -> [String: SQLiteValue] {
        var result: [String: SQLiteValue] = [:]
        let columnCount = sqlite3_column_count(statement)
        for index in 0..<columnCount {
            let name = String(cString: sqlite3_column_name(statement, index))
            switch sqlite3_column_type(statement, index) {
            case SQLITE_INTEGER:
                result[name] = .int(Int(sqlite3_column_int64(statement, index)))
            case SQLITE_FLOAT:
                result[name] = .double(sqlite3_column_double(statement, index))
            case SQLITE_TEXT:
                if let pointer = sqlite3_column_text(statement, index) {
                    result[name] = .text(String(cString: pointer))
                } else {
                    result[name] = .null
                }
            case SQLITE_NULL:
                result[name] = .null
            default:
                result[name] = .null
            }
        }
        return result
    }

    private var lastErrorMessage: String {
        guard let db else {
            return "database closed"
        }
        return String(cString: sqlite3_errmsg(db))
    }
}

public enum SQLiteBinding: Sendable {
    case null
    case int(Int)
    case double(Double)
    case text(String)
}

public enum SQLiteValue: Equatable, Sendable {
    case null
    case int(Int)
    case double(Double)
    case text(String)

    public var intValue: Int? {
        switch self {
        case let .int(value): value
        case let .double(value): Int(value)
        case let .text(value): Int(value)
        case .null: nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case let .double(value): value
        case let .int(value): Double(value)
        case let .text(value): Double(value)
        case .null: nil
        }
    }

    public var stringValue: String? {
        switch self {
        case let .text(value): value
        case let .int(value): String(value)
        case let .double(value): String(value)
        case .null: nil
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
