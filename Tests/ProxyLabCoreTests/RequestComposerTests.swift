import XCTest
@testable import ProxyLabCore

final class RequestComposerTests: XCTestCase {
    func testEditedURLAndBodyRegenerateHostAndLengthWithoutProxyCredentials() throws {
        let request = ProxyRequest(method: "post", url: "https://new.example:9443/api?x=1", headers: [
            .init(name: "Host", value: "old.example"), .init(name: "Content-Length", value: "999"),
            .init(name: "Connection", value: "keep-alive, X-Private"), .init(name: "X-Private", value: "hidden"),
            .init(name: "Connection", value: "X-Second"), .init(name: "X-Second", value: "hidden2"),
            .init(name: "Proxy-Authorization", value: "secret"), .init(name: "Content-Type", value: "application/octet-stream")
        ], body: Data([0, 255, 3]))
        let edited = try RequestComposer.normalized(request)
        XCTAssertEqual(edited.method, "POST")
        XCTAssertEqual(edited.header("Host"), "new.example:9443")
        XCTAssertEqual(edited.header("Content-Length"), "3")
        XCTAssertNil(edited.header("Proxy-Authorization"))
        XCTAssertNil(edited.header("X-Private"))
        XCTAssertNil(edited.header("X-Second"))
        XCTAssertEqual(edited.body, Data([0,255,3]))
    }

    func testInvalidInputsCannotBeSent() {
        for request in [ProxyRequest(method: "GET", url: "file:///etc/hosts"),
                        ProxyRequest(method: "GET", url: "https://user:pass@example.com/"),
                        ProxyRequest(method: "GET\r\nBad", url: "https://example.com/"),
                        ProxyRequest(method: "GET", url: "https://example.com/", headers: [.init(name: "X-Test", value: "a\r\nb")]),
                        ProxyRequest(method: "CONNECT", url: "https://example.com:443") ] {
            XCTAssertThrowsError(try RequestComposer.normalized(request), "\(request.method) \(request.url)")
        }
    }
}
