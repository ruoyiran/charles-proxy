import Foundation
import XCTest
import ProxyLabCore
@testable import ProxyLabApp

@MainActor
final class DefaultHTTPSInspectionTests: XCTestCase {
    func testFreshInstallDecryptsHTTPSWithoutHostConfiguration() async throws {
        try await assertDefaultHTTPSInspection(legacyHosts: nil)
    }

    func testLegacyHostListDoesNotRestrictHTTPSInspection() async throws {
        try await assertDefaultHTTPSInspection(legacyHosts: "previously-selected.example")
    }

    func testCertificateLoadFailureCanBeRetriedWithoutChangingPort() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let loader = RetryingAuthorityLoader()
        let model = AppModel(supportDirectory: directory, certificateAuthorityLoader: { _ in try loader.load() },
                             certificateTrustEvaluator: { _ in "Trusted for SSL" })
        model.proxyPort = 0
        await model.start()
        XCTAssertEqual(model.statusText, "Proxy unavailable")
        XCTAssertNotNil(model.errorMessage)

        await model.start()
        XCTAssertTrue(model.statusText.hasPrefix("Listening on 127.0.0.1:"))
        XCTAssertNil(model.errorMessage)
        await model.stop()
    }

    private func assertDefaultHTTPSInspection(legacyHosts: String?) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        if let legacyHosts {
            try legacyHosts.write(to: directory.appendingPathComponent("ssl-hosts.txt"), atomically: true, encoding: .utf8)
        }
        let authority = try CertificateAuthority(persistentDirectory: nil)
        let rootURL = directory.appendingPathComponent("test-root.pem")
        try authority.rootCertificatePEM.write(to: rootURL, atomically: true, encoding: .utf8)
        let model = AppModel(supportDirectory: directory, certificateAuthorityLoader: { _ in authority },
                             certificateTrustEvaluator: { _ in "Trusted for SSL" })
        model.proxyPort = 0
        await model.start()

        // Targeting the proxy itself produces an immediate upstream error after a verified TLS
        // handshake. This verifies capture without accessing the network or a real Keychain.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["--silent", "--show-error", "--noproxy", "", "--max-time", "5",
                             "--proxy", "http://127.0.0.1:\(model.proxyPort)", "--cacert", rootURL.path,
                             "--output", "/dev/null", "-H", "X-Default-Inspection: verified",
                             "https://localhost:\(model.proxyPort)/default-inspection"]
        let errors = Pipe()
        process.standardError = errors
        do { try process.run() }
        catch { await model.stop(); throw error }
        while process.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        await model.stop()
        let store = try SessionStore(path: directory.appendingPathComponent("sessions.sqlite").path)
        let records = try await store.list()
        XCTAssertEqual(process.terminationStatus, 0,
                       String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        let record = try XCTUnwrap(records.first)
        XCTAssertTrue(record.tlsIntercepted)
        XCTAssertEqual(record.request.method, "GET")
        XCTAssertEqual(record.request.header("X-Default-Inspection"), "verified")
        XCTAssertEqual(record.error, "selfLoop")
    }
}

private final class RetryingAuthorityLoader: @unchecked Sendable {
    private let lock = NSLock()
    private var attempted = false

    func load() throws -> CertificateAuthority {
        lock.lock()
        defer { lock.unlock() }
        if !attempted {
            attempted = true
            throw CertificateAuthorityError.keychain(-25308)
        }
        return try CertificateAuthority(persistentDirectory: nil)
    }
}
