import Foundation
import SQLite3

/// A connection belongs to one operation/thread. SQLite serializes writers;
/// callers never hold a transaction open while waiting on a model or network.
public final class ContextDatabase {
    public enum Table: String, CaseIterable {
        case metadata, sources, receipts, summaries, entities, aliases, observations
        case transitions, overrides, search, jobs, usage
    }
    public enum Value {
        case text(String), blob(Data), integer(Int64), real(Double), null
    }
    public struct Failure: LocalizedError {
        public let message: String
        public var errorDescription: String? { "Memory database: " + message }
    }
    private var db: OpaquePointer?
    private let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return e
    }()
    public let url: URL

    public init(root: URL) throws {
        let folder = root.appendingPathComponent("context", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        url = folder.appendingPathComponent("memory.sqlite")
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open storage."
            sqlite3_close(db); db = nil; throw Failure(message: message)
        }
        do {
            sqlite3_busy_timeout(db, 5_000)
            try execute("PRAGMA foreign_keys=ON")
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA secure_delete=ON")
            let version = try rows("PRAGMA user_version").first?.first.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
            guard version <= 1 else { throw Failure(message: "This library requires a newer Listen version.") }
            if version == 0 {
                try transaction {
                    for table in Table.allCases {
                        try execute("CREATE TABLE IF NOT EXISTS \(table.rawValue) (id TEXT PRIMARY KEY, payload BLOB NOT NULL) WITHOUT ROWID")
                    }
                    try execute("CREATE TABLE IF NOT EXISTS vectors (id TEXT PRIMARY KEY, namespace TEXT NOT NULL, dimensions INTEGER NOT NULL, value BLOB NOT NULL) WITHOUT ROWID")
                    try execute("CREATE VIRTUAL TABLE IF NOT EXISTS context_fts USING fts5(id UNINDEXED, text, tokenize='unicode61 remove_diacritics 2')")
                    try execute("PRAGMA user_version=1")
                }
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }

    private func prepared(_ sql: String, _ values: [Value]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Failure(message: String(cString: sqlite3_errmsg(db)))
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let text): result = sqlite3_bind_text(statement, index, text, -1, transient)
            case .blob(let data): result = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), transient) }
            case .integer(let number): result = sqlite3_bind_int64(statement, index, number)
            case .real(let number): result = sqlite3_bind_double(statement, index, number)
            case .null: result = sqlite3_bind_null(statement, index)
            }
            if result != SQLITE_OK { sqlite3_finalize(statement); throw Failure(message: "Could not bind a stored value.") }
        }
        return statement
    }

    public func execute(_ sql: String, _ values: [Value] = []) throws {
        let statement = try prepared(sql, values); defer { sqlite3_finalize(statement) }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW { result = sqlite3_step(statement) }
        guard result == SQLITE_DONE else { throw Failure(message: String(cString: sqlite3_errmsg(db))) }
    }

    public func rows(_ sql: String, _ values: [Value] = []) throws -> [[Data]] {
        let statement = try prepared(sql, values); defer { sqlite3_finalize(statement) }
        var result: [[Data]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw Failure(message: String(cString: sqlite3_errmsg(db))) }
            result.append((0..<sqlite3_column_count(statement)).map { index in
                guard let pointer = sqlite3_column_blob(statement, index) else { return Data() }
                return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, index)))
            })
        }
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let value = try body(); try execute("COMMIT"); return value }
        catch { try? execute("ROLLBACK"); throw error }
    }

    public func get<T: Decodable>(_ type: T.Type, in table: Table, id: String) throws -> T? {
        guard let data = try rows("SELECT payload FROM \(table.rawValue) WHERE id=?", [.text(id)]).first?.first else { return nil }
        return try JSONDecoder().decode(type, from: data)
    }
    public func all<T: Decodable>(_ type: T.Type, in table: Table) throws -> [String: T] {
        try Dictionary(uniqueKeysWithValues: rows("SELECT id,payload FROM \(table.rawValue) ORDER BY id").map {
            (String(decoding: $0[0], as: UTF8.self), try JSONDecoder().decode(type, from: $0[1]))
        })
    }
    public func put<T: Encodable>(_ value: T, in table: Table, id: String) throws {
        try execute("INSERT INTO \(table.rawValue)(id,payload) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload WHERE payload != excluded.payload",
                    [.text(id), .blob(try encoder.encode(value))])
    }
    public func remove(_ table: Table, id: String) throws {
        try execute("DELETE FROM \(table.rawValue) WHERE id=?", [.text(id)])
    }
    /// Call inside a transaction when replacing related collections.
    public func replace<T: Codable>(_ values: [String: T], in table: Table) throws {
        let old = try rows("SELECT id FROM \(table.rawValue)").map { String(decoding: $0[0], as: UTF8.self) }
        for id in old where values[id] == nil { try remove(table, id: id) }
        for (id, value) in values { try put(value, in: table, id: id) }
    }

    public func index(id: String, text: String, namespace: String?, vector: [Float]?) throws {
        try execute("DELETE FROM context_fts WHERE id=?", [.text(id)])
        try execute("INSERT INTO context_fts(id,text) VALUES(?,?)", [.text(id), .text(text)])
        if let namespace, let vector, !vector.isEmpty, vector.allSatisfy(\.isFinite) {
            let bytes = vector.flatMap { value -> [UInt8] in
                var bits = value.bitPattern.littleEndian
                return withUnsafeBytes(of: &bits) { Array($0) }
            }
            try execute("INSERT OR REPLACE INTO vectors VALUES(?,?,?,?)", [.text(id), .text(namespace), .integer(Int64(vector.count)), .blob(Data(bytes))])
        } else { try execute("DELETE FROM vectors WHERE id=?", [.text(id)]) }
    }
    public func lexical(_ words: [String], limit: Int = 500) throws -> [String] {
        guard !words.isEmpty else { return [] }
        let query = words.prefix(32).map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " OR ")
        return try rows("SELECT id FROM context_fts WHERE context_fts MATCH ? ORDER BY bm25(context_fts),id LIMIT ?",
                        [.text(query), .integer(Int64(max(1, min(limit, 10_000))))]).map { String(decoding: $0[0], as: UTF8.self) }
    }
}
