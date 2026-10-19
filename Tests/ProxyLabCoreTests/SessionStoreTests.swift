import XCTest
@testable import ProxyLabCore

final class SessionStoreTests: XCTestCase {
    func testTransactionSurvivesStoreReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("sessions.sqlite").path
        let transaction = CapturedTransaction(
            request: ProxyRequest(method: "POST", url: "https://example.com/api", body: Data("payload".utf8)),
            response: ProxyResponse(status: 201, body: Data("saved".utf8)), tlsIntercepted: true
        )

        let first = try SessionStore(path: path)
        try await first.save(transaction)
        let reopened = try SessionStore(path: path)
        let loaded = try await reopened.load(id: transaction.id)

        XCTAssertEqual(loaded?.request.url, "https://example.com/api")
        XCTAssertEqual(loaded?.request.body, Data("payload".utf8))
        XCTAssertEqual(loaded?.response?.status, 201)
        XCTAssertEqual(loaded?.tlsIntercepted, true)
    }

    func testSummaryListKeepsNewestFirstWithoutLoadingBodies() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SessionStore(path: directory.appendingPathComponent("sessions.sqlite").path)
        let first = CapturedTransaction(startedAt: Date(timeIntervalSince1970: 100),
                                        request: ProxyRequest(method: "GET", url: "http://a.example/"))
        let second = CapturedTransaction(startedAt: Date(timeIntervalSince1970: 200),
                                         request: ProxyRequest(method: "POST", url: "http://b.example/", body: Data(repeating: 1, count: 1_000_000)),
                                         response: ProxyResponse(status: 201))
        try await store.save(first)
        try await store.save(second)

        let summaries = try await store.listSummaries(limit: 10)
        XCTAssertEqual(summaries.map(\.id), [second.id, first.id])
        XCTAssertEqual(summaries.first?.host, "b.example")
        XCTAssertEqual(summaries.first?.status, 201)
    }

    func testCapturedSessionDatabaseIsOwnerReadableOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("sessions.sqlite").path
        _ = try SessionStore(path: path)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
