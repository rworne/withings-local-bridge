import Foundation
import SQLite3

final class Database {
    private var handle: OpaquePointer?
    let name: String
    init(url: URL, name: String) throws {
        self.name = name
        // Normal read-only SQLite access honors WAL and locking. immutable=1 would
        // silently ignore a live WAL and is deliberately not used.
        let result = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, handle != nil else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open database"
            if let handle { sqlite3_close(handle) }; handle = nil
            throw BridgeError.message("Cannot read \(name): \(message). Choose the Withings database folder in the Mac app.")
        }
        sqlite3_busy_timeout(handle, 5000)
        try execute("PRAGMA query_only=ON")
    }
    deinit { if let handle { sqlite3_exec(handle, "ROLLBACK", nil, nil, nil); sqlite3_close(handle) } }
    func beginSnapshot() throws { try execute("BEGIN DEFERRED TRANSACTION") }
    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    func failure() -> BridgeError { .message("\(name): \(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite error")") }
    func rows(_ sql: String, _ consume: ([String: Cell]) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return }
            guard result == SQLITE_ROW else { throw failure() }
            var row: [String: Cell] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let key = String(cString: sqlite3_column_name(statement, index))
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: row[key] = .integer(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT: row[key] = .real(sqlite3_column_double(statement, index))
                case SQLITE_TEXT:
                    if let text = sqlite3_column_text(statement, index) { row[key] = .text(String(cString: text)) }
                default: break // Never export opaque metadata, tokens, notes or arbitrary blobs.
                }
            }
            try consume(row)
        }
    }
    func columns(_ table: String) throws -> Set<String> {
        var result = Set<String>()
        try rows("PRAGMA table_info(\(quoted(table)))") { if let name = $0["name"]?.string { result.insert(name) } }
        return result
    }
    func require(_ table: String, _ columns: [String]) throws {
        let found = try self.columns(table)
        guard Set(columns).isSubset(of: found) else {
            throw BridgeError.message("Unsupported schema in \(name), table \(table). No batch was published.")
        }
    }
    func description() throws -> SourceDescription {
        var schema: [String] = []
        try rows("SELECT name,sql FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name") {
            schema.append(($0["name"]?.string ?? "") + ":" + ($0["sql"]?.string ?? ""))
        }
        var uuid: String?
        try require("Z_METADATA", ["Z_UUID"])
        try rows("SELECT Z_UUID FROM Z_METADATA LIMIT 1") { uuid = $0["Z_UUID"]?.string }
        guard let uuid, !uuid.isEmpty else { throw BridgeError.message("Missing database identity in \(name).") }
        return SourceDescription(database: name, identity: uuid, schemaFingerprint: digest(Data(schema.joined(separator: "\n").utf8)))
    }
}
enum Cell {
    case integer(Int64), real(Double), text(String)
    var integer: Int64? { switch self { case .integer(let n): return n; default: return nil } }
    var number: Double? { switch self { case .integer(let n): return Double(n); case .real(let n): return n.isFinite ? n : nil; default: return nil } }
    var string: String? { switch self { case .integer(let n): return String(n); case .real(let n): return n.isFinite ? String(n) : nil; case .text(let s): return s } }
}
func quoted(_ name: String) -> String { "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
extension Dictionary where Key == String, Value == Cell {
    func integer(_ key: String) -> Int64? { self[key]?.integer }
    func number(_ key: String) -> Double? { self[key]?.number }
    func text(_ key: String) -> String? { self[key]?.string }
    func unix(_ key: String) -> Double? { number(key).map { $0 + 978307200 } }
}
