import Foundation
import GRDB

public actor SessionStore {
    private let database: DatabaseQueue
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(path: String) throws {
        database = try DatabaseQueue(path: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        try database.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS transactions (
                    id TEXT PRIMARY KEY,
                    started_at REAL NOT NULL,
                    host TEXT NOT NULL,
                    method TEXT NOT NULL,
                    url TEXT NOT NULL,
                    status INTEGER,
                    document BLOB NOT NULL
                )
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS transactions_started ON transactions(started_at DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS transactions_host ON transactions(host)")
        }
    }

    public func save(_ transaction: CapturedTransaction) throws {
        let data = try encoder.encode(transaction)
        let host = URL(string: transaction.request.url)?.host ?? ""
        try database.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO transactions (id, started_at, host, method, url, status, document)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [transaction.id.uuidString, transaction.startedAt.timeIntervalSince1970,
                                 host, transaction.request.method, transaction.request.url,
                                 transaction.response?.status, data])
        }
    }

    public func load(id: UUID) throws -> CapturedTransaction? {
        try database.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT document FROM transactions WHERE id = ?", arguments: [id.uuidString]),
                  let data: Data = row["document"] else { return nil }
            return try decoder.decode(CapturedTransaction.self, from: data)
        }
    }

    public func list(limit: Int = 1_000) throws -> [CapturedTransaction] {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT document FROM transactions ORDER BY started_at DESC LIMIT ?", arguments: [limit])
            return try rows.compactMap { row -> CapturedTransaction? in
                guard let data: Data = row["document"] else { return nil }
                return try decoder.decode(CapturedTransaction.self, from: data)
            }
        }
    }

    public func listSummaries(limit: Int = 1_000) throws -> [TransactionSummary] {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, started_at, host, method, url, status
                FROM transactions ORDER BY started_at DESC LIMIT ?
                """, arguments: [limit])
            return rows.compactMap { row in
                guard let id = UUID(uuidString: row["id"]) else { return nil }
                let started: Double = row["started_at"]
                return TransactionSummary(id: id, startedAt: Date(timeIntervalSince1970: started),
                                          host: row["host"], method: row["method"],
                                          url: row["url"], status: row["status"])
            }
        }
    }

    public func clear() throws {
        try database.write { db in try db.execute(sql: "DELETE FROM transactions") }
    }

    public func remove(id: UUID) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM transactions WHERE id = ?", arguments: [id.uuidString])
        }
    }
}
