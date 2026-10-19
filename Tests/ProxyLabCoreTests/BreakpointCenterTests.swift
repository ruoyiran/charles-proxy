import XCTest
@testable import ProxyLabCore

final class BreakpointCenterTests: XCTestCase {
    func testCancelledClientRemovesItsPausedRequestImmediately() async throws {
        let center = BreakpointCenter()
        await center.setRules([BreakpointRule(match: RuleMatch(host: "example.com"), phase: .request)])
        let request = ProxyRequest(method: "GET", url: "http://example.com/")
        let waiter = Task { await center.intercept(request: request, response: nil, phase: .request) }
        _ = try await waitForPending(center)
        waiter.cancel()
        let result = await waiter.value
        if case .cancel = result {} else { XCTFail("Cancelled client must not execute") }
        let remaining = await center.pending()
        XCTAssertTrue(remaining.isEmpty)
    }
    func testRequestWaitsForExplicitEditedDecision() async throws {
        let center = BreakpointCenter()
        await center.setRules([BreakpointRule(match: RuleMatch(host: "example.com", path: "/*"), phase: .request)])
        let request = ProxyRequest(method: "GET", url: "http://example.com/a")
        let waiter = Task { await center.intercept(request: request, response: nil, phase: .request, timeout: .seconds(5)) }

        let pending = try await waitForPending(center)
        XCTAssertEqual(pending.request.url, request.url)
        var edited = request
        edited.setHeader("X-Debug", value: "yes")
        await center.resolve(id: pending.id, decision: .execute(request: edited, response: nil))
        let decision = await waiter.value
        if case .execute(let actual, _) = decision {
            XCTAssertEqual(actual?.header("X-Debug"), "yes")
        } else {
            XCTFail("Expected edited request to proceed")
        }
        let remaining = await center.pending()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testTimedOutBreakpointCancelsManualEdit() async {
        let center = BreakpointCenter()
        await center.setRules([BreakpointRule(match: RuleMatch(host: "example.com"), phase: .response)])
        let request = ProxyRequest(method: "GET", url: "http://example.com/a")
        let response = ProxyResponse(status: 200)
        let decision = await center.intercept(request: request, response: response, phase: .response, timeout: .milliseconds(20))
        if case .cancel = decision {} else { XCTFail("Expected timeout to continue unmodified") }
        let remaining = await center.pending()
        XCTAssertTrue(remaining.isEmpty)
    }

    private func waitForPending(_ center: BreakpointCenter) async throws -> PendingBreakpoint {
        for _ in 0..<100 {
            if let first = await center.pending().first { return first }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "BreakpointCenterTests", code: 1)
    }
}
