import XCTest
@testable import ProxyLabCore

final class BodyContentTests: XCTestCase {
    private let expected = Data("{\"message\":\"captured response\",\"ok\":true}".utf8)

    func testGzipBodyCanBeReadWithoutChangingCapturedBytes() throws {
        let compressed = Data(base64Encoded: "H4sIAAAAAAACE6tWyk0tLk5MT1WyUkpOLCgpLUpNUShKLS7IzytOVdJRys9WsiopKk2tBQAd+Z4BKQAAAA==")!
        let decoded = try BodyContent.decode(compressed, contentEncoding: "gzip")
        XCTAssertEqual(decoded, expected)
        XCTAssertNotEqual(compressed, expected)
    }

    func testDeflateAcceptsZlibAndRawStreams() throws {
        for fixture in ["eJyrVspNLS5OTE9VslJKTiwoKS1KTVEoSi0uyM8rTlXSUcrPVrIqKSpNrQUANm8Oyw==",
                        "q1bKTS0uTkxPVbJSSk4sKCktSk1RKEotLsjPK05V0lHKz1ayKikqTa0FAA=="] {
            XCTAssertEqual(try BodyContent.decode(Data(base64Encoded: fixture)!, contentEncoding: "deflate"), expected)
        }
    }

    func testBrotliBodyIsDecoded() throws {
        let compressed = Data(base64Encoded: "DxSAeyJtZXNzYWdlIjoiY2FwdHVyZWQgcmVzcG9uc2UiLCJvayI6dHJ1ZX0D")!
        XCTAssertEqual(try BodyContent.decode(compressed, contentEncoding: "br"), expected)
    }

    func testDecodeLimitAndCorruptPayloadAreReported() {
        let compressed = Data(base64Encoded: "H4sIAAAAAAACE6tWyk0tLk5MT1WyUkpOLCgpLUpNUShKLS7IzytOVdJRys9WsiopKk2tBQAd+Z4BKQAAAA==")!
        XCTAssertThrowsError(try BodyContent.decode(compressed, contentEncoding: "gzip", limit: 8))
        XCTAssertThrowsError(try BodyContent.decode(Data([1, 2, 3]), contentEncoding: "gzip"))
    }

    func testJSONFormattingPreservesValues() throws {
        let pretty = BodyContent.text(expected, contentType: "application/json; charset=utf-8", pretty: true)
        XCTAssertTrue(pretty.contains("\n"))
        let actual = try JSONSerialization.jsonObject(with: Data(pretty.utf8)) as? [String: Any]
        XCTAssertEqual(actual?["message"] as? String, "captured response")
        XCTAssertEqual(actual?["ok"] as? Bool, true)
    }
}
