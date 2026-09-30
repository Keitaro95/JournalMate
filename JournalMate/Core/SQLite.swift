import Foundation
import SQLite3

/// libsqlite3 の薄いラッパ。外部依存を持たないための最小実装。
/// 値の詰め替えと `sqlite3_step` の面倒だけを引き受け、SQL は生のまま書く。
final class SQLiteDatabase {

    enum Error: Swift.Error, LocalizedError {
        case open(String)
        case prepare(String, sql: String)
        case step(String, sql: String)

        var errorDescription: String? {
            switch self {
            case .open(let m): return String(localized: "Could not open the database: \(m)")
            case .prepare(let m, let sql): return String(localized: "Failed to prepare SQL: \(m)\n\(sql)")
            case .step(let m, let sql): return String(localized: "Failed to run SQL: \(m)\n\(sql)")
            }
        }
    }

    /// バインド可能な値。SQLite の 5 つのストレージクラスに対応する。
    enum Value {
        case int(Int64)
        case double(Double)
        case text(String)
        case blob(Data)
        case null
    }

    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "app.journalmate.sqlite")

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, handle != nil else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close_v2(handle)
            throw Error.open(message)
        }
        // WAL は読み書きの並行性を上げる。foreign_keys は既定で OFF なので明示的に入れる。
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA synchronous = NORMAL")
    }

    deinit { sqlite3_close_v2(handle) }

    // MARK: - 実行

    /// 結果行を読まない文（DDL / INSERT / UPDATE / DELETE）。
    func execute(_ sql: String, _ params: [Value] = []) throws {
        try queue.sync {
            let statement = try prepare(sql, params)
            defer { sqlite3_finalize(statement) }
            let code = sqlite3_step(statement)
            guard code == SQLITE_DONE || code == SQLITE_ROW else {
                throw Error.step(lastErrorMessage, sql: sql)
            }
        }
    }

    /// 結果行を 1 行ずつ `decode` に渡して配列で返す。
    func query<T>(_ sql: String, _ params: [Value] = [], decode: (Row) -> T) throws -> [T] {
        try queue.sync {
            let statement = try prepare(sql, params)
            defer { sqlite3_finalize(statement) }
            var results: [T] = []
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_ROW {
                    results.append(decode(Row(statement: statement)))
                } else if code == SQLITE_DONE {
                    break
                } else {
                    throw Error.step(lastErrorMessage, sql: sql)
                }
            }
            return results
        }
    }

    /// 複数の書き込みをまとめる。`body` が throw したら丸ごと巻き戻す。
    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    // MARK: - 内部

    private var lastErrorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
    }

    private func prepare(_ sql: String, _ params: [Value]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Error.prepare(lastErrorMessage, sql: sql)
        }
        for (offset, value) in params.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .int(let v):
                sqlite3_bind_int64(statement, index, v)
            case .double(let v):
                sqlite3_bind_double(statement, index, v)
            case .text(let v):
                // SQLITE_TRANSIENT: SQLite 側に文字列をコピーさせる。
                // Swift の String バッファは step までの生存が保証されないため必須。
                sqlite3_bind_text(statement, index, v, -1, SQLiteDatabase.transient)
            case .blob(let v):
                if v.isEmpty {
                    sqlite3_bind_zeroblob(statement, index, 0)
                } else {
                    _ = v.withUnsafeBytes {
                        sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(v.count), SQLiteDatabase.transient)
                    }
                }
            case .null:
                sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // MARK: - 行

    struct Row {
        let statement: OpaquePointer?

        func int(_ index: Int32) -> Int64 { sqlite3_column_int64(statement, index) }

        func intOrNil(_ index: Int32) -> Int64? {
            sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : int(index)
        }

        func string(_ index: Int32) -> String {
            guard let pointer = sqlite3_column_text(statement, index) else { return "" }
            return String(cString: pointer)
        }

        func stringOrNil(_ index: Int32) -> String? {
            sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : string(index)
        }
    }
}

// MARK: - 値の糖衣

extension SQLiteDatabase.Value {
    static func date(_ value: Date) -> Self { .int(Int64(value.timeIntervalSince1970)) }
    static func text(optional value: String?) -> Self { value.map { .text($0) } ?? .null }
    static func date(optional value: Date?) -> Self { value.map { .date($0) } ?? .null }
}
