import XCTest
@testable import ProxyLabCore

final class MobileSetupTests: XCTestCase {
    func testSetupCanBeReachedDirectlyAndThroughProxyWithoutFetchingUpstream() throws {
        let certificate = Data([1, 2, 3, 4])
        for url in ["http://192.168.1.2:8888/setup", "http://proxylab.local/setup"] {
            let response = try XCTUnwrap(MobileSetupPage.response(for: url, method: "GET", port: 8888,
                                                                 certificateDER: certificate, localAddresses: ["192.168.1.2"]))
            XCTAssertEqual(response.status, 200)
            let text = String(decoding: response.body, as: UTF8.self)
            XCTAssertTrue(text.contains("iOS"))
            XCTAssertTrue(text.contains("Android"))
            XCTAssertTrue(text.contains("root-ca.cer"))
        }
        let response = try XCTUnwrap(MobileSetupPage.response(for: "http://proxylab.local/root-ca.cer", method: "GET",
                                                             port: 8888, certificateDER: certificate, localAddresses: []))
        XCTAssertEqual(response.body, certificate)
        XCTAssertEqual(response.contentType, "application/x-x509-ca-cert")
        XCTAssertEqual(response.downloadName, "ProxyLab-Root-CA.cer")
    }

    func testOtherServersAndMethodsCannotBecomeCertificateEndpoint() {
        XCTAssertNil(MobileSetupPage.response(for: "http://example.com:8888/root-ca.cer", method: "GET", port: 8888,
                                               certificateDER: Data(), localAddresses: ["192.168.1.2"]))
        XCTAssertNil(MobileSetupPage.response(for: "https://proxylab.local/root-ca.cer", method: "GET", port: 8888,
                                               certificateDER: Data(), localAddresses: []))
        let denied = MobileSetupPage.response(for: "http://proxylab.local/setup", method: "POST", port: 8888,
                                              certificateDER: Data(), localAddresses: [])
        XCTAssertEqual(denied?.status, 405)
    }
}
