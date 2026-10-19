import XCTest
@testable import ProxyLabCore

final class CapturePolicyTests: XCTestCase {
    func testIncludeExcludeAndDeviceRulesChooseSavedTraffic() {
        let include = CaptureRule(match: RuleMatch(host: "*.example.com", path: "/api/*", method: "POST"), clientAddress: "192.168.1.3")
        let exclude = CaptureRule(match: RuleMatch(host: "api.example.com", path: "/api/private/*"))
        let policy = CapturePolicy(include: [include], exclude: [exclude])
        XCTAssertTrue(policy.shouldRecord(request: .init(method: "POST", url: "https://api.example.com/api/items"), clientAddress: "192.168.1.3"))
        XCTAssertFalse(policy.shouldRecord(request: .init(method: "GET", url: "https://api.example.com/api/items"), clientAddress: "192.168.1.3"))
        XCTAssertFalse(policy.shouldRecord(request: .init(method: "POST", url: "https://api.example.com/api/items"), clientAddress: "192.168.1.4"))
        XCTAssertFalse(policy.shouldRecord(request: .init(method: "POST", url: "https://api.example.com/api/private/a"), clientAddress: "192.168.1.3"))
        let disabledInclude = CaptureRule(enabled: false, match: .init(host: "other.com"))
        XCTAssertTrue(CapturePolicy(include: [disabledInclude]).shouldRecord(request: .init(method: "GET", url: "https://example.com/"), clientAddress: nil))
    }

    func testFocusOnlyFiltersDisplayAndCanBeDisabled() {
        let item = TransactionSummary(id: UUID(), startedAt: Date(), host: "example.com", method: "GET", url: "https://example.com/a", status: 200)
        XCTAssertFalse(FocusPolicy(enabled: true, rules: [.init(match: .init(host: "other.com"))]).matches(item))
        XCTAssertTrue(FocusPolicy(enabled: false, rules: []).matches(item))
        XCTAssertTrue(FocusPolicy(enabled: true, rules: [.init(match: .init(host: "example.com"))]).matches(item))
    }
}
