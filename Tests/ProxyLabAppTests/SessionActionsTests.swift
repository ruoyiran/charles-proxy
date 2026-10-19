import XCTest
import ProxyLabCore
@testable import ProxyLabApp

@MainActor
final class SessionActionsTests: XCTestCase {
    func testDeleteSelectionAndClearPersistWhileRecordingCanContinue() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(path: directory.appendingPathComponent("sessions.sqlite").path)
        let first = CapturedTransaction(request: ProxyRequest(method: "GET", url: "http://example.com/a"))
        let second = CapturedTransaction(request: ProxyRequest(method: "POST", url: "http://example.com/b"))
        try await store.save(first); try await store.save(second)
        let authority = try CertificateAuthority(persistentDirectory: nil)
        let model = AppModel(supportDirectory: directory, certificateAuthorityLoader: { _ in authority },
                             certificateTrustEvaluator: { _ in "Trusted for SSL" })
        model.proxyPort = 0
        await model.start()
        await model.refresh()
        await model.select(first.id)
        await model.deleteRequest(first.id)
        XCTAssertNil(model.selectedID)
        XCTAssertNil(model.selectedTransaction)
        await model.refresh()
        XCTAssertEqual(model.summaries.map(\.id), [second.id])
        await model.select(second.id)
        await model.clearSession()
        await model.refresh()
        XCTAssertTrue(model.summaries.isEmpty)
        XCTAssertNil(model.selectedID)
        XCTAssertNil(model.selectedTransaction)
        XCTAssertTrue(model.recordingEnabled)
        let newRecord = CapturedTransaction(request: ProxyRequest(method: "GET", url: "http://example.com/new"))
        try await store.save(newRecord)
        await model.refresh()
        XCTAssertEqual(model.summaries.map(\.id), [newRecord.id])
        await model.stop()
    }
}
