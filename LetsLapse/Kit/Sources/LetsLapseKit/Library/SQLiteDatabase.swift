import Foundation
import SQLite3

/// A thin, throwing wrapper over the system SQLite — just what
/// `LibraryIndex` needs: open, execute, prepared statements with bound
/// values, and typed reads. Not a general ORM; the SQL stays visible.
///
/// One connection, used from one queue at a time by its owner. WAL journal
/// so a reader (the `lapse` CLI, a second process) never blocks the app's
/// writes or sees a half-written page.
final class SQLiteDatabase {

    struct Failure: LocalizedError {
        var message: String
        var code: Int32
        var errorDescription: String? { "SQLite: \(message) (\(code))" }
    }

    enum Value {
        case null
        case int(Int64)
        case real(Double)
        case text(String)
    }

    private var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(url.path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open"
            if let db { sqlite3_close(db) }
            throw Failure(message: message, code: rc)
        }
        handle = db
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        try execute("PRAGMA foreign_keys=ON")
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    /// Runs one or more statements with no bindings.
    func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &message)
        guard rc == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(message)
            throw Failure(message: text, code: rc)
        }
    }

    /// Runs one statement with bound values and no result.
    func run(_ sql: String, _ values: [Value] = []) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        let rc = sqlite3_step(statement)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw failure(rc) }
    }

    /// Runs a query and maps every row.
    func query<Row>(_ sql: String, _ values: [Value] = [], _ map: (Cursor) throws -> Row) throws -> [Row] {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var rows: [Row] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_ROW {
                rows.append(try map(Cursor(statement: statement)))
            } else if rc == SQLITE_DONE {
                return rows
            } else {
                throw failure(rc)
            }
        }
    }

    /// The first column of the first row as an integer, or nil.
    func scalar(_ sql: String, _ values: [Value] = []) throws -> Int64? {
        try query(sql, values) { $0.int(0) }.first ?? nil
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    var userVersion: Int {
        get { Int((try? scalar("PRAGMA user_version")) ?? 0 ?? 0) }
    }

    func setUserVersion(_ version: Int) throws {
        try execute("PRAGMA user_version=\(version)")
    }

    // MARK: - Statements

    private func prepare(_ sql: String, _ values: [Value]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard rc == SQLITE_OK, let statement else { throw failure(rc) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let bound: Int32
            switch value {
            case .null: bound = sqlite3_bind_null(statement, index)
            case .int(let number): bound = sqlite3_bind_int64(statement, index, number)
            case .real(let number): bound = sqlite3_bind_double(statement, index, number)
            case .text(let text): bound = sqlite3_bind_text(statement, index, text, -1, Self.transient)
            }
            guard bound == SQLITE_OK else {
                sqlite3_finalize(statement)
                throw failure(bound)
            }
        }
        return statement
    }

    private func failure(_ rc: Int32) -> Failure {
        Failure(message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "?", code: rc)
    }

    /// One row of a running query.
    struct Cursor {
        let statement: OpaquePointer

        func isNull(_ column: Int) -> Bool {
            sqlite3_column_type(statement, Int32(column)) == SQLITE_NULL
        }

        func int(_ column: Int) -> Int64? {
            isNull(column) ? nil : sqlite3_column_int64(statement, Int32(column))
        }

        func real(_ column: Int) -> Double? {
            isNull(column) ? nil : sqlite3_column_double(statement, Int32(column))
        }

        func text(_ column: Int) -> String? {
            guard !isNull(column), let pointer = sqlite3_column_text(statement, Int32(column)) else { return nil }
            return String(cString: pointer)
        }
    }
}

extension SQLiteDatabase.Value {
    init(_ text: String?) { self = text.map { .text($0) } ?? .null }
    init(_ number: Double?) { self = number.map { .real($0) } ?? .null }
    init(_ number: Int?) { self = number.map { .int(Int64($0)) } ?? .null }
    init(_ number: Int64?) { self = number.map { .int($0) } ?? .null }
    init(_ flag: Bool) { self = .int(flag ? 1 : 0) }
    /// A list as a JSON array text, or null when absent.
    init(list: [String]?) {
        guard let list, let data = try? JSONSerialization.data(withJSONObject: list),
              let text = String(data: data, encoding: .utf8) else { self = .null; return }
        self = .text(text)
    }
}
