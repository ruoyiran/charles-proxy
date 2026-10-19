import XCTest
import ProxyLabCore
@testable import ProxyLabApp

@MainActor
final class SessionActionsTests: XCTestCase {
    func testExplicitSendSelectsSavedResultWithRecordingPausedAndFocusEnabled() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let authority = try CertificateAuthority(persistentDirectory: nil)
        let model = AppModel(supportDirectory: directory, certificateAuthorityLoader: { _ in authority },
                             certificateTrustEvaluator: { _ in "Trusted for SSL" })
        model.proxyPort = 0
        await model.start()
        await model.toggleRecording()
        await model.saveCapturePolicy(.init(exclude: [.init(match: .init(host: "127.0.0.1"))]))
        await model.saveFocusPolicy(.init(enabled: true, rules: [.init(match: .init(host: "other.example"))]))
        model.selectedDeviceAddress = "192.0.2.1"
        let originalID = UUID()
        // An unused local port produces an inspectable failure without submitting user traffic.
        let sent = await model.sendRequest(.init(method: "GET", url: "http://127.0.0.1:1/composer-fixture"), replayOf: originalID)
        XCTAssertTrue(sent)
        XCTAssertEqual(model.summaries.count, 1)
        XCTAssertEqual(model.selectedTransaction?.replayOf, originalID)
        XCTAssertEqual(model.selectedID, model.summaries.first?.id)
        XCTAssertNotNil(model.selectedTransaction?.error)
        XCTAssertFalse(model.focusPolicy.enabled)
        XCTAssertNil(model.selectedDeviceAddress)
        XCTAssertFalse(model.sendingRequest)
        let reopened = AppModel(supportDirectory: directory, certificateAuthorityLoader: { _ in authority })
        XCTAssertEqual(reopened.capturePolicy.exclude.first?.match.host, "127.0.0.1")
        XCTAssertFalse(reopened.focusPolicy.enabled)
        XCTAssertEqual(reopened.focusPolicy.rules.first?.match.host, "other.example")
        await model.stop()
    }

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
