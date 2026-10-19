import XCTest
@testable import ProxyLabCore

final class AuthorityTests: XCTestCase {
    func testParsesDomainAndIPv6ConnectTargets() throws {
        XCTAssertEqual(try ProxyAuthority("example.com:443"), ProxyAuthority(host: "example.com", port: 443))
        XCTAssertEqual(try ProxyAuthority("[::1]:8443"), ProxyAuthority(host: "::1", port: 8443))
    }

    func testRejectsMissingOrInvalidPort() {
        XCTAssertThrowsError(try ProxyAuthority("example.com"))
        XCTAssertThrowsError(try ProxyAuthority("example.com:0"))
        XCTAssertThrowsError(try ProxyAuthority("example.com:65536"))
        XCTAssertThrowsError(try ProxyAuthority("::1:443"))
    }
}
