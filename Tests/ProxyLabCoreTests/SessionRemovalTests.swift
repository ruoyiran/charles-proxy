import XCTest
@testable import ProxyLabCore

final class SessionRemovalTests: XCTestCase {
    func testRemovingRequestPreservesOtherRecordsAndSurvivesReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("sessions.sqlite").path
        let store = try SessionStore(path: path)
        let removed = CapturedTransaction(request: ProxyRequest(method: "GET", url: "http://example.com/a"))
        let retained = CapturedTransaction(request: ProxyRequest(method: "POST", url: "http://example.com/b"))
        try await store.save(removed)
        try await store.save(retained)
        try await store.remove(id: removed.id)
        let reopened = try SessionStore(path: path)
        let records = try await reopened.list()
        XCTAssertEqual(records.map(\.id), [retained.id])
        let missing = try await reopened.load(id: removed.id)
        XCTAssertNil(missing)
    }
}
