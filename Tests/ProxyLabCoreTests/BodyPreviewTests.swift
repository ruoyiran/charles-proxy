import XCTest
@testable import ProxyLabCore

final class BodyPreviewTests: XCTestCase {
    func testMIMEParametersAndVendorTypesSelectCorrectPreview() {
        let cases: [(String, BodyPreviewKind, String)] = [
            ("Application/Problem+JSON; charset=UTF-8", .json, "json"),
            ("image/png", .image, "png"), ("image/svg+xml", .html, "svg"),
            ("application/pdf", .pdf, "pdf"), ("text/html; charset=utf-8", .html, "html"),
            ("application/xml", .text, "xml"), ("text/csv", .text, "csv"),
            ("application/javascript", .text, "js"),
            ("audio/mpeg", .audio, "mp3"), ("video/mp4", .video, "mp4")
        ]
        for (type, kind, ext) in cases {
            let preview = BodyPreview.detect(data: Data(), contentType: type)
            XCTAssertEqual(preview.kind, kind, type)
            XCTAssertEqual(preview.fileExtension, ext, type)
        }
    }

    func testMissingMIMEUsesFileSignaturesAndTextWithoutRenderingUnknownBinary() {
        let cases: [(Data, BodyPreviewKind, String)] = [
            (Data([0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10]), .image, "png"),
            (Data("%PDF-1.7".utf8), .pdf, "pdf"),
            (Data("{\"ok\":true}".utf8), .json, "json"),
            (Data("<!doctype html><h1>Hello</h1>".utf8), .html, "html"),
            (Data("hello, world".utf8), .text, "txt"),
            (Data([0, 255, 3, 2]), .binary, "bin")
        ]
        for (data, kind, ext) in cases {
            let preview = BodyPreview.detect(data: data, contentType: "application/octet-stream")
            XCTAssertEqual(preview.kind, kind)
            XCTAssertEqual(preview.fileExtension, ext)
        }
    }

    func testUnsupportedFileTypeStaysBinaryAndURLCannotOverrideExplicitMIME() {
        let archive = BodyPreview.detect(data: Data([0x50, 0x4b, 3, 4]), contentType: "application/zip")
        XCTAssertEqual(archive.kind, .binary)
        XCTAssertEqual(archive.fileExtension, "zip")
        XCTAssertEqual(BodyPreview.detect(data: Data("hello".utf8), contentType: "text/plain",
                                          url: "https://example.com/a.png").kind, .text)
        XCTAssertEqual(BodyPreview.detect(data: Data([0, 3]), contentType: nil,
                                          url: "https://example.com/movie.mp4?x=1").kind, .video)
    }
}
