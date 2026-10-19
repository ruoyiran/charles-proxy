import Foundation
import Security
import XCTest
@testable import ProxyLabCore

final class CertificateAuthorityTests: XCTestCase {
    func testIssuedLeafIsTrustedForOnlyItsRequestedHostname() async throws {
        let authority = try CertificateAuthority(persistentDirectory: nil)
        let root = try XCTUnwrap(SecCertificateCreateWithData(nil, authority.rootCertificateDER as CFData))
        let leafDER = try await authority.certificateDER(for: "example.com")
        let leaf = try XCTUnwrap(SecCertificateCreateWithData(nil, leafDER as CFData))
        _ = try await authority.serverContext(for: "example.com")

        func evaluate(_ hostname: String) throws -> Bool {
            var trust: SecTrust?
            XCTAssertEqual(SecTrustCreateWithCertificates([leaf] as CFArray,
                                                          SecPolicyCreateSSL(true, hostname as CFString), &trust), errSecSuccess)
            let value = try XCTUnwrap(trust)
            XCTAssertEqual(SecTrustSetAnchorCertificates(value, [root] as CFArray), errSecSuccess)
            return SecTrustEvaluateWithError(value, nil)
        }

        XCTAssertTrue(try evaluate("example.com"))
        XCTAssertFalse(try evaluate("other.example.com"))
    }
}
