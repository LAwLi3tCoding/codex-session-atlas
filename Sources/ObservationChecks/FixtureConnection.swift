import Foundation
import SQLite3

enum StoreError: Error, CustomStringConvertible {
    case unavailable(String)
    var description: String {
        switch self { case .unavailable(let message): message }
    }
}

final class FixtureConnection {
    private var handle: OpaquePointer?
    init(_ path: String, readOnly: Bool = true) throws {
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            sqlite3_close(handle); handle = nil
            throw StoreError.unavailable("数据库暂不可读")
        }
        sqlite3_busy_timeout(handle, 250)
        if readOnly { try execute("PRAGMA query_only=ON") }
    }
    deinit { sqlite3_close(handle) }
    func rows(_ sql: String, _ bindings: [String] = []) throws -> [[String: String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.unavailable("数据库字段不兼容或读取繁忙")
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in bindings.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
        }
        var result: [[String: String]] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else { throw StoreError.unavailable("数据库读取中断，保留上次快照") }
            var row: [String: String] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                if let name = sqlite3_column_name(statement, index), let value = sqlite3_column_text(statement, index) {
                    row[String(cString: name)] = String(cString: value)
                }
            }
            result.append(row)
        }
    }
    func execute(_ sql: String, _ bindings: [String] = []) throws { _ = try rows(sql, bindings) }
    func columns(_ table: String) throws -> Set<String> { Set(try rows("PRAGMA table_info(\(table))").compactMap { $0["name"] }) }
}
