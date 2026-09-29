import Foundation
import SQLite3

/// Just enough SQLite for the browser's own stores: open, run, query, bind.
/// Not thread-safe; each store owns one connection and uses it from one actor.
public final class SQLiteDatabase {
    public enum Error: Swift.Error, CustomStringConvertible {
        case open(String)
        case sql(String, String)
        public var description: String {
            switch self {
            case .open(let message): return "could not open the database: \(message)"
            case .sql(let message, let sql): return "\(message) in: \(sql)"
            }
        }
    }

    public enum Value: Equatable {
        case int(Int64)
        case double(Double)
        case text(String)
        case blob(Data)
        case null
    }

    private var handle: OpaquePointer?
    /// SQLite copies bound text and blobs immediately with this.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// `nil` path: an in-memory database, for tests and private windows.
    public init(path: String?) throws {
        let target = path ?? ":memory:"
        guard sqlite3_open_v2(target, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw Error.open(message)
        }
        // WAL: a crash mid-write leaves the last committed state, and reads
        // do not wait for writes.
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA foreign_keys = ON")
    }

    /// Runs once the connection is closed: for a copy made to be read and thrown away.
    public var onClose: (() -> Void)?

    deinit {
        sqlite3_close(handle)
        onClose?()
    }

    public func execute(_ sql: String, _ arguments: [Value] = []) throws {
        _ = try query(sql, arguments)
    }

    /// Rows as column-name dictionaries.
    @discardableResult
    public func query(_ sql: String, _ arguments: [Value] = []) throws -> [[String: Value]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw failure(sql) }
        defer { sqlite3_finalize(statement) }
        for (index, argument) in arguments.enumerated() {
            let position = Int32(index + 1)
            switch argument {
            case .int(let value): sqlite3_bind_int64(statement, position, value)
            case .double(let value): sqlite3_bind_double(statement, position, value)
            case .text(let value): sqlite3_bind_text(statement, position, value, -1, Self.transient)
            case .blob(let value): _ = value.withUnsafeBytes { sqlite3_bind_blob(statement, position, $0.baseAddress, Int32(value.count), Self.transient) }
            case .null: sqlite3_bind_null(statement, position)
            }
        }
        var rows: [[String: Value]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw failure(sql) }
            var row: [String: Value] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, column))
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: row[name] = .double(sqlite3_column_double(statement, column))
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(statement, column)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    row[name] = .blob(count == 0 ? Data() : Data(bytes: sqlite3_column_blob(statement, column), count: count))
                default: row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }

    public var lastInsertID: Int64 { sqlite3_last_insert_rowid(handle) }
    public var changes: Int { Int(sqlite3_changes(handle)) }

    public func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func failure(_ sql: String) -> Error {
        .sql(String(cString: sqlite3_errmsg(handle)), sql)
    }
}

public extension Dictionary where Key == String, Value == SQLiteDatabase.Value {
    func text(_ key: String) -> String? { if case .text(let v) = self[key] { return v } else { return nil } }
    func int(_ key: String) -> Int64? {
        switch self[key] {
        case .int(let v): return v
        case .double(let v): return Int64(v)
        default: return nil
        }
    }
    func double(_ key: String) -> Double? {
        switch self[key] {
        case .double(let v): return v
        case .int(let v): return Double(v)
        default: return nil
        }
    }
}
