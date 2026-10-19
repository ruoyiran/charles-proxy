import Foundation
import XCTest
@testable import ProxyLabApp

@MainActor
final class CertificateTrustFeedbackTests: XCTestCase {
    func testCheckShowsProgressAndCompletionEvenIfResultIsUnchanged() async throws {
        let gate = TrustCheckGate()
        let model = AppModel(certificateTrustEvaluator: { _ in
            await gate.wait()
            return "Trusted for SSL"
        })
        model.rootCertificateStatus = "Trusted for SSL"

        let check = Task { await model.refreshRootCertificateStatus() }
        for _ in 0..<100 {
            if model.isCheckingCertificateTrust { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(model.isCheckingCertificateTrust)
        XCTAssertEqual(model.rootCertificateStatus, "Checking certificate trust…")
        XCTAssertNil(model.certificateTrustCheckedAt)

        await gate.release()
        await check.value

        XCTAssertFalse(model.isCheckingCertificateTrust)
        XCTAssertEqual(model.rootCertificateStatus, "Trusted for SSL")
        XCTAssertNotNil(model.certificateTrustCheckedAt)
    }

    func testRepeatCheckRecordsNewCompletionWhenTrustDoesNotChange() async throws {
        let model = AppModel(certificateTrustEvaluator: { _ in "Trusted for SSL" })
        await model.refreshRootCertificateStatus()
        let firstCompletion = try XCTUnwrap(model.certificateTrustCheckedAt)

        try await Task.sleep(for: .milliseconds(5))
        await model.refreshRootCertificateStatus()

        XCTAssertEqual(model.rootCertificateStatus, "Trusted for SSL")
        XCTAssertGreaterThan(try XCTUnwrap(model.certificateTrustCheckedAt), firstCompletion)
        XCTAssertFalse(model.isCheckingCertificateTrust)
    }
}

private actor TrustCheckGate {
    private var open = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if open { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        open = true
        continuation?.resume()
        continuation = nil
    }
}
