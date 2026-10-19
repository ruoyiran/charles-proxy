import Foundation
import GRDB

/// Messages share the session database, with one durable row per completed message or control frame.
public actor WebSocketMessageStore {
    private let database: DatabaseQueue
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(path: String) throws {
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        database = try DatabaseQueue(path: path, configuration: configuration)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        try database.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS websocket_messages (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                    id TEXT NOT NULL UNIQUE,
                    transaction_id TEXT NOT NULL,
                    document BLOB NOT NULL
                )
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS websocket_messages_transaction ON websocket_messages(transaction_id, sequence)")
        }
    }

    public func save(_ message: WebSocketMessage, transactionID: UUID) throws {
        let document = try encoder.encode(message)
        try database.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO websocket_messages (id, transaction_id, document) VALUES (?, ?, ?)",
                           arguments: [message.id.uuidString, transactionID.uuidString, document])
        }
    }

    /// Streams only a recent page; row decoding never retains more than the page budget plus
    /// one captured message. The complete retained capture remains in the database.
    public func recent(transactionID: UUID, limit: Int = 200, maxPayloadBytes: Int = 2 * 1_024 * 1_024) throws -> WebSocketMessagePage {
        try database.read { db in
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM websocket_messages WHERE transaction_id = ?", arguments: [transactionID.uuidString]) ?? 0
            let countLimit = max(0, min(limit, 200))
            let byteLimit = max(0, min(maxPayloadBytes, 2 * 1_024 * 1_024))
            guard countLimit > 0, total > 0 else { return WebSocketMessagePage(totalCount: total, isLimited: total > 0) }
            let cursor = try Row.fetchCursor(db, sql: "SELECT document FROM websocket_messages WHERE transaction_id = ? ORDER BY sequence DESC LIMIT ?",
                                            arguments: [transactionID.uuidString, countLimit])
            var messages: [WebSocketMessage] = []
            var retained = 0
            var clipped = false
            while let row = try cursor.next() {
                let document: Data = row["document"]
                var message = try decoder.decode(WebSocketMessage.self, from: document)
                let available = byteLimit - retained
                if message.payload.count > available {
                    if !messages.isEmpty { break }
                    message.payload = Data(message.payload.prefix(available))
                    message.isTruncated = true
                    clipped = true
                }
                retained += message.payload.count
                messages.append(message)
                if retained == byteLimit { break }
            }
            return WebSocketMessagePage(messages: messages.reversed(), totalCount: total, isLimited: clipped || messages.count < total)
        }
    }

    public func list(transactionID: UUID, limit: Int = 200) throws -> [WebSocketMessage] {
        try recent(transactionID: transactionID, limit: limit).messages
    }

    public func remove(transactionID: UUID) throws {
        try database.write { db in try db.execute(sql: "DELETE FROM websocket_messages WHERE transaction_id = ?", arguments: [transactionID.uuidString]) }
    }

    public func clear() throws {
        try database.write { db in try db.execute(sql: "DELETE FROM websocket_messages") }
    }
}
