import XCTest
@testable import ProxyLabCore

final class HARCodecTests: XCTestCase {
    func testRoundTripPreservesSeparateBodyTruncationFlags() throws {
        let upload = CapturedTransaction(request: .init(method: "POST", url: "https://example.com/upload", body: Data("prefix".utf8)),
                                         requestBodyTruncated: true)
        let download = CapturedTransaction(request: .init(method: "GET", url: "https://example.com/download"),
                                           response: .init(status: 200, body: Data("prefix".utf8)), responseBodyTruncated: true)
        let imported = try HARCodec.decode(HARCodec.encode([upload, download]))
        XCTAssertTrue(imported[0].requestBodyTruncated)
        XCTAssertFalse(imported[0].responseBodyTruncated)
        XCTAssertFalse(imported[1].requestBodyTruncated)
        XCTAssertTrue(imported[1].responseBodyTruncated)
    }

    func testLegacyProxyLabTruncationCommentMarksBothBodiesIncomplete() throws {
        let data = Data("""
        {"log":{"entries":[{"request":{"method":"POST","url":"https://example.com/upload","headers":[]},
        "comment":"ProxyLab retained only the first 10 MB of one or more bodies"}]}}
        """.utf8)
        let imported = try XCTUnwrap(HARCodec.decode(data).first)
        XCTAssertTrue(imported.requestBodyTruncated)
        XCTAssertTrue(imported.responseBodyTruncated)
    }

    func testExportsBinaryBodyAsBase64() throws {
        let transaction = CapturedTransaction(
            request: ProxyRequest(method: "POST", url: "http://example.com/upload", body: Data([0, 255])),
            response: ProxyResponse(status: 200)
        )

        let data = try HARCodec.encode([transaction])
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let log = try XCTUnwrap(root["log"] as? [String: Any])
        let entry = try XCTUnwrap((log["entries"] as? [[String: Any]])?.first)
        let request = try XCTUnwrap(entry["request"] as? [String: Any])
        let postData = try XCTUnwrap(request["postData"] as? [String: Any])

        XCTAssertEqual(log["version"] as? String, "1.2")
        XCTAssertEqual(postData["encoding"] as? String, "base64")
        XCTAssertEqual(postData["text"] as? String, "AP8=")
    }

    func testImportsHandWrittenHARRecord() throws {
        let fixture = """
        {"log":{"version":"1.2","creator":{"name":"fixture","version":"1"},"entries":[{
          "startedDateTime":"2025-01-01T00:00:00Z","time":12,
          "request":{"method":"GET","url":"http://example.com/a","httpVersion":"HTTP/1.1","headers":[],"queryString":[],"cookies":[],"headersSize":-1,"bodySize":0},
          "response":{"status":200,"statusText":"OK","httpVersion":"HTTP/1.1","headers":[],"cookies":[],"content":{"size":2,"mimeType":"text/plain","text":"ok"},"redirectURL":"","headersSize":-1,"bodySize":2},
          "cache":{},"timings":{"send":0,"wait":12,"receive":0}
        }]}}
        """
        let imported = try HARCodec.decode(Data(fixture.utf8))

        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported.first?.request.url, "http://example.com/a")
        XCTAssertEqual(imported.first?.response?.body, Data("ok".utf8))
    }
}
