import XCTest
@testable import ProxyLabCore

final class RuleEngineTests: XCTestCase {
    func testHostAndPathGlobOnlyRewriteMatchingRequest() throws {
        let rule = RewriteRule(
            name: "debug header",
            match: RuleMatch(host: "*.example.com", path: "/api/*", method: "GET"),
            phase: .request,
            action: .setHeader(name: "X-Debug", value: "yes")
        )
        var matching = ProxyRequest(method: "GET", url: "https://api.example.com/api/users")
        var apex = ProxyRequest(method: "GET", url: "https://example.com/api/users")
        var wrongPath = ProxyRequest(method: "GET", url: "https://api.example.com/home")

        RuleEngine.applyRequest(&matching, rules: [rule])
        RuleEngine.applyRequest(&apex, rules: [rule])
        RuleEngine.applyRequest(&wrongPath, rules: [rule])

        XCTAssertEqual(matching.header("X-Debug"), "yes")
        XCTAssertNil(apex.header("X-Debug"))
        XCTAssertNil(wrongPath.header("X-Debug"))
    }

    func testResponseTextReplacementLeavesBinaryUntouched() {
        let rule = RewriteRule(
            name: "replace greeting",
            match: RuleMatch(host: "example.com", path: "/*", method: nil),
            phase: .response,
            action: .replaceText(find: "hello", replace: "goodbye")
        )
        let request = ProxyRequest(method: "GET", url: "https://example.com/")
        var text = ProxyResponse(status: 200, headers: [HTTPHeader(name: "Content-Type", value: "text/plain; charset=utf-8")], body: Data("hello".utf8))
        var binary = ProxyResponse(status: 200, headers: [HTTPHeader(name: "Content-Type", value: "image/png")], body: Data([0, 1, 2]))

        RuleEngine.applyResponse(&text, for: request, rules: [rule])
        RuleEngine.applyResponse(&binary, for: request, rules: [rule])

        XCTAssertEqual(String(data: text.body, encoding: .utf8), "goodbye")
        XCTAssertEqual(text.header("Content-Length"), "7")
        XCTAssertEqual(binary.body, Data([0, 1, 2]))
    }

    func testURLRewriteUpdatesHostWithNonstandardPort() {
        let rule = RewriteRule(name: "redirect", match: RuleMatch(host: "old.example"),
                               phase: .request, action: .replaceURL("https://new.example:8443/x"))
        var request = ProxyRequest(method: "GET", url: "http://old.example/a",
                                   headers: [HTTPHeader(name: "Host", value: "old.example")])
        RuleEngine.applyRequest(&request, rules: [rule])
        XCTAssertEqual(request.url, "https://new.example:8443/x")
        XCTAssertEqual(request.header("Host"), "new.example:8443")
    }
}
