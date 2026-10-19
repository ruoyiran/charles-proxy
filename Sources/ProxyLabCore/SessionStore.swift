import Foundation
import GRDB

public actor SessionStore {
    public nonisolated let path: String
    private let database: DatabaseQueue
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var deletedIDs: Set<UUID> = []

    public init(path: String) throws {
        self.path = path
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        database = try DatabaseQueue(path: path, configuration: configuration)
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
            if try !db.columns(in: "transactions").contains(where: { $0.name == "client_address" }) {
                try db.execute(sql: "ALTER TABLE transactions ADD COLUMN client_address TEXT")
            }
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS transactions_client ON transactions(client_address)")
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS websocket_messages (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                    id TEXT NOT NULL UNIQUE,
                    transaction_id TEXT NOT NULL,
                    document BLOB NOT NULL
                )
                """)
            for column in ["request_version", "replay_of"] where try !db.columns(in: "transactions").contains(where: { $0.name == column }) {
                try db.execute(sql: "ALTER TABLE transactions ADD COLUMN \(column) TEXT")
            }
        }
    }

    public func save(_ transaction: CapturedTransaction) throws {
        guard !deletedIDs.contains(transaction.id) else { return }
        let data = try encoder.encode(transaction)
        let host = URL(string: transaction.request.url)?.host ?? ""
        try database.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO transactions (id, started_at, host, method, url, status, document, client_address, request_version, replay_of)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [transaction.id.uuidString, transaction.startedAt.timeIntervalSince1970,
                                 host, transaction.request.method, transaction.request.url,
                                 transaction.response?.status, data, transaction.clientAddress, transaction.requestHTTPVersion, transaction.replayOf?.uuidString])
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

    public func listSummaries(limit: Int = 1_000, clientAddress: String? = nil, focus: FocusPolicy = FocusPolicy()) throws -> [TransactionSummary] {
        try database.read { db in
            let cursor = try Row.fetchCursor(db, sql: """
                SELECT id, started_at, host, method, url, status, client_address, request_version, replay_of
                FROM transactions WHERE (? IS NULL OR client_address = ?)
                ORDER BY started_at DESC LIMIT ?
                """, arguments: [clientAddress, clientAddress, focus.enabled ? -1 : limit])
            var results: [TransactionSummary] = []
            while results.count < limit, let row = try cursor.next() {
                guard let id = UUID(uuidString: row["id"]) else { continue }
                let started: Double = row["started_at"]
                let summary = TransactionSummary(id: id, startedAt: Date(timeIntervalSince1970: started),
                                          host: row["host"], method: row["method"],
                                          url: row["url"], status: row["status"], clientAddress: row["client_address"],
                                          requestHTTPVersion: row["request_version"], replayOf: (row["replay_of"] as String?).flatMap(UUID.init(uuidString:)))
                if focus.matches(summary) { results.append(summary) }
            }
            return results
        }
    }

    public func clear() throws {
        try database.write { db in
            let ids = try String.fetchAll(db, sql: "SELECT id FROM transactions")
            deletedIDs.formUnion(ids.compactMap(UUID.init(uuidString:)))
            try db.execute(sql: "DELETE FROM websocket_messages")
            try db.execute(sql: "DELETE FROM transactions")
        }
    }

    public func clientAddresses() throws -> [String] {
        try database.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT client_address FROM transactions WHERE client_address IS NOT NULL ORDER BY client_address")
        }
    }

    public func remove(id: UUID) throws {
        deletedIDs.insert(id)
        try database.write { db in
            try db.execute(sql: "DELETE FROM websocket_messages WHERE transaction_id = ?", arguments: [id.uuidString])
            try db.execute(sql: "DELETE FROM transactions WHERE id = ?", arguments: [id.uuidString])
        }
    }

    public func saveWebSocketMessage(_ message: WebSocketMessage, transactionID: UUID) throws {
        guard !deletedIDs.contains(transactionID) else { return }
        let data = try encoder.encode(message)
        try database.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO websocket_messages (id, transaction_id, document)
                SELECT ?, ?, ? WHERE EXISTS (SELECT 1 FROM transactions WHERE id = ?)
                """, arguments: [message.id.uuidString, transactionID.uuidString, data, transactionID.uuidString])
        }
    }
}
